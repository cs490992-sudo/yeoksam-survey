-- Atomic pre-to-post transition and organization-scoped lifecycle audit.
-- Apply manually after 009_fix_survey_question_image_storage_rls.sql.

create table public.survey_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  survey_project_id uuid references public.survey_projects(id) on delete set null,
  survey_round_id uuid references public.survey_rounds(id) on delete set null,
  event_type text not null check (event_type in (
    'project_started', 'project_scheduled', 'scheduled_returned_to_draft',
    'pre_closed', 'post_started', 'pre_to_post_transition', 'round_closed',
    'project_closed', 'project_archived', 'project_restored'
  )),
  from_status text,
  to_status text,
  actor_user_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  metadata jsonb
);

create index survey_lifecycle_events_organization_created_idx
  on public.survey_lifecycle_events (organization_id, created_at desc);
create index survey_lifecycle_events_project_created_idx
  on public.survey_lifecycle_events (survey_project_id, created_at desc);

alter table public.survey_lifecycle_events enable row level security;
create policy survey_lifecycle_events_select on public.survey_lifecycle_events
for select to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = auth.uid()
    and p.is_active = true
    and p.role in ('admin', 'staff')
    and p.organization_id = survey_lifecycle_events.organization_id
));

revoke all on table public.survey_lifecycle_events from public, anon, authenticated;
grant select on table public.survey_lifecycle_events to authenticated;

-- Project-level state changes, including existing direct archive/restore updates,
-- are audited without changing any existing lifecycle RPC contract.
create or replace function public.audit_survey_project_status_change()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_event_type text;
begin
  if new.status is not distinct from old.status then return new; end if;
  v_event_type := case
    when old.status = 'draft' and new.status = 'scheduled' then 'project_scheduled'
    when old.status = 'scheduled' and new.status = 'draft' then 'scheduled_returned_to_draft'
    when old.status in ('draft', 'scheduled') and new.status = 'open' then 'project_started'
    when old.status = 'open' and new.status = 'closed' then 'project_closed'
    when old.status = 'closed' and new.status = 'archived' then 'project_archived'
    when old.status = 'archived' and new.status = 'closed' then 'project_restored'
    else null
  end;
  if v_event_type is not null and auth.uid() is not null then
    insert into public.survey_lifecycle_events (
      organization_id, survey_project_id, event_type, from_status, to_status,
      actor_user_id, metadata
    ) values (
      new.organization_id, new.id, v_event_type, old.status, new.status,
      auth.uid(), jsonb_build_object(
        'source', 'project_status_trigger',
        'survey_project_id', new.id,
        'project_title', new.title
      )
    );
  end if;
  return new;
end;
$$;

revoke all on function public.audit_survey_project_status_change() from public, anon, authenticated;
drop trigger if exists survey_projects_audit_status on public.survey_projects;
create trigger survey_projects_audit_status
after update of status on public.survey_projects
for each row execute function public.audit_survey_project_status_change();

create or replace function public.transition_pre_to_post_survey(p_survey_project_id uuid)
returns table (pre_round_id uuid, post_round_id uuid, transitioned_at timestamptz)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_project public.survey_projects%rowtype;
  v_pre public.survey_rounds%rowtype;
  v_post public.survey_rounds%rowtype;
  v_pre_count integer;
  v_post_count integer;
  v_participant_count integer;
  v_submitted_count integer;
  v_transitioned_at timestamptz;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '사전·사후 단계를 전환할 권한이 없습니다.'; end if;

  select sp.* into v_project from public.survey_projects sp
  where sp.id = p_survey_project_id and sp.organization_id = v_organization_id
  for update;
  if v_project.id is null then raise exception '조사를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;
  if v_project.survey_type <> 'pre_post' or v_project.status <> 'open' then
    raise exception '진행 중인 사전·사후 조사만 전환할 수 있습니다.';
  end if;

  perform 1 from public.survey_rounds r
  where r.survey_project_id = v_project.id order by r.id for update;
  select count(*) filter (where r.round_type = 'pre'),
         count(*) filter (where r.round_type = 'post')
  into v_pre_count, v_post_count
  from public.survey_rounds r where r.survey_project_id = v_project.id;
  if v_pre_count <> 1 or v_post_count <> 1 then raise exception '사전·사후 회차는 각각 정확히 하나여야 합니다.'; end if;

  select r.* into v_pre from public.survey_rounds r
  where r.survey_project_id = v_project.id and r.round_type = 'pre';
  select r.* into v_post from public.survey_rounds r
  where r.survey_project_id = v_project.id and r.round_type = 'post';
  if v_pre.status <> 'open' then raise exception '진행 중인 사전 회차만 전환할 수 있습니다.'; end if;
  if v_post.status <> 'pending' or v_post.starts_at is not null or v_post.ends_at is not null then
    raise exception '사후 회차가 안전한 대기 상태가 아닙니다.';
  end if;
  if exists (
    select 1 from public.survey_rounds r
    where r.survey_project_id = v_project.id and r.status = 'open' and r.id <> v_pre.id
  ) then raise exception '사전 회차 외에 진행 중인 회차가 있습니다.'; end if;
  if exists (select 1 from public.survey_submissions s where s.survey_round_id = v_post.id) then
    raise exception '응답이 있는 사후 회차는 전환할 수 없습니다.';
  end if;

  select count(*) into v_participant_count
  from public.survey_participants participant
  where participant.survey_project_id = v_project.id;
  select count(distinct submission.client_id) into v_submitted_count
  from public.survey_submissions submission
  join public.survey_participants participant
    on participant.survey_project_id = v_project.id
   and participant.client_id = submission.client_id
  where submission.survey_round_id = v_pre.id
    and submission.status = 'submitted';
  if v_participant_count = 0 or v_submitted_count <> v_participant_count then
    raise exception '사전 조사를 모두 완료한 뒤 사후 단계로 전환할 수 있습니다.';
  end if;

  v_transitioned_at := now();
  update public.survey_rounds set status = 'closed', ends_at = v_transitioned_at
  where id = v_pre.id and survey_project_id = v_project.id and status = 'open';
  if not found then raise exception '사전 회차 상태가 변경되어 전환하지 못했습니다.'; end if;
  update public.survey_rounds set status = 'open', starts_at = v_transitioned_at, ends_at = null
  where id = v_post.id and survey_project_id = v_project.id and status = 'pending'
    and starts_at is null and ends_at is null;
  if not found then raise exception '사후 회차 상태가 변경되어 전환하지 못했습니다.'; end if;

  insert into public.survey_lifecycle_events (
    organization_id, survey_project_id, survey_round_id, event_type,
    from_status, to_status, actor_user_id, metadata
  ) values (
    v_organization_id, v_project.id, v_post.id, 'pre_to_post_transition',
    'pre:open/post:pending', 'pre:closed/post:open', v_user_id,
    jsonb_build_object(
      'survey_project_id', v_project.id, 'project_title', v_project.title,
      'pre_round_id', v_pre.id, 'post_round_id', v_post.id,
      'transitioned_at', v_transitioned_at
    )
  );
  return query select v_pre.id, v_post.id, v_transitioned_at;
end;
$$;

create or replace function public.open_post_survey_round(p_survey_project_id uuid)
returns table (survey_round_id uuid, round_status text, project_status text, started_at timestamptz)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid(); v_organization_id uuid;
  v_project public.survey_projects%rowtype; v_pre public.survey_rounds%rowtype;
  v_post public.survey_rounds%rowtype; v_pre_count integer; v_post_count integer;
  v_started_at timestamptz;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select p.organization_id into v_organization_id from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '사후 조사를 시작할 권한이 없습니다.'; end if;
  select sp.* into v_project from public.survey_projects sp
  where sp.id = p_survey_project_id and sp.organization_id = v_organization_id for update;
  if v_project.id is null then raise exception '조사를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;
  if v_project.survey_type <> 'pre_post' or v_project.status <> 'open' then
    raise exception '진행 중인 사전·사후 조사만 사후 회차를 시작할 수 있습니다.';
  end if;
  perform 1 from public.survey_rounds r where r.survey_project_id = v_project.id order by r.id for update;
  select count(*) filter(where round_type='pre'), count(*) filter(where round_type='post')
  into v_pre_count,v_post_count from public.survey_rounds where survey_project_id=v_project.id;
  if v_pre_count<>1 or v_post_count<>1 then raise exception '사전·사후 회차는 각각 정확히 하나여야 합니다.'; end if;
  select * into v_pre from public.survey_rounds where survey_project_id=v_project.id and round_type='pre';
  select * into v_post from public.survey_rounds where survey_project_id=v_project.id and round_type='post';
  if v_pre.status<>'closed' then raise exception '사전 회차가 종료된 뒤 사후 조사를 시작할 수 있습니다.'; end if;
  if v_post.status<>'pending' or v_post.starts_at is not null or v_post.ends_at is not null then raise exception '사후 회차가 안전한 대기 상태가 아닙니다.'; end if;
  if exists(select 1 from public.survey_submissions where survey_round_id=v_post.id) then raise exception '응답이 있는 사후 회차는 시작할 수 없습니다.'; end if;
  if exists(select 1 from public.survey_rounds where survey_project_id=v_project.id and status='open') then raise exception '이미 진행 중인 회차가 있습니다.'; end if;
  v_started_at:=now();
  update public.survey_rounds set status='open',starts_at=v_started_at,ends_at=null
  where id=v_post.id and survey_project_id=v_project.id and status='pending' and starts_at is null and ends_at is null;
  if not found then raise exception '사후 회차 상태가 변경되어 시작하지 못했습니다.'; end if;
  insert into public.survey_lifecycle_events(organization_id,survey_project_id,survey_round_id,event_type,from_status,to_status,actor_user_id,metadata)
  values(v_organization_id,v_project.id,v_post.id,'post_started','pending','open',v_user_id,
    jsonb_build_object('survey_project_id',v_project.id,'project_title',v_project.title,'started_at',v_started_at));
  return query select v_post.id,'open'::text,'open'::text,v_started_at;
end;
$$;

create or replace function public.close_survey_round(p_survey_round_id uuid)
returns table (survey_round_id uuid, round_status text, project_status text, ended_at timestamptz, already_closed boolean)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid(); v_organization_id uuid;
  v_project public.survey_projects%rowtype; v_round public.survey_rounds%rowtype;
  v_project_status text; v_ended_at timestamptz; v_event_type text;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select p.organization_id into v_organization_id from public.profiles p
  where p.id=v_user_id and p.is_active=true and p.role in ('admin','staff');
  if v_organization_id is null then raise exception '조사 회차를 종료할 권한이 없습니다.'; end if;
  select r.* into v_round from public.survey_rounds r join public.survey_projects sp on sp.id=r.survey_project_id
  where r.id=p_survey_round_id and sp.organization_id=v_organization_id for update of r;
  if v_round.id is null then raise exception '조사 회차를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;
  select sp.* into v_project from public.survey_projects sp where sp.id=v_round.survey_project_id for update;
  if v_project.id is null or v_project.organization_id<>v_organization_id then raise exception '조사와 회차의 소속을 확인할 수 없습니다.'; end if;
  if v_round.status='closed' then return query select v_round.id,v_round.status,v_project.status,v_round.ends_at,true; return; end if;
  if v_round.status<>'open' or v_project.status<>'open' then raise exception '진행 중인 조사 회차만 종료할 수 있습니다.'; end if;
  if (v_project.survey_type='single' and v_round.round_type<>'single') or (v_project.survey_type='pre_post' and v_round.round_type not in ('pre','post')) then raise exception '조사 유형과 회차 유형이 일치하지 않습니다.'; end if;
  if exists(select 1 from public.survey_rounds where survey_project_id=v_project.id and id<>v_round.id and status='open') then raise exception '같은 조사에 여러 진행 중 회차가 있어 종료할 수 없습니다.'; end if;
  v_ended_at:=now();
  update public.survey_rounds set status='closed',ends_at=v_ended_at where id=v_round.id and survey_project_id=v_project.id and status='open';
  if not found then raise exception '회차 상태가 변경되어 종료하지 못했습니다.'; end if;
  v_project_status:=case when v_round.round_type='pre' then 'open' else 'closed' end;
  if v_project_status='closed' then
    update public.survey_projects set status='closed',ends_at=v_ended_at where id=v_project.id and organization_id=v_organization_id and status='open';
    if not found then raise exception '조사 상태가 변경되어 종료하지 못했습니다.'; end if;
  end if;
  v_event_type:=case when v_round.round_type='pre' then 'pre_closed' else 'round_closed' end;
  insert into public.survey_lifecycle_events(organization_id,survey_project_id,survey_round_id,event_type,from_status,to_status,actor_user_id,metadata)
  values(v_organization_id,v_project.id,v_round.id,v_event_type,'open','closed',v_user_id,
    jsonb_build_object('survey_project_id',v_project.id,'project_title',v_project.title,'round_type',v_round.round_type,'ended_at',v_ended_at));
  return query select v_round.id,'closed'::text,v_project_status,v_ended_at,false;
end;
$$;

revoke all on function public.transition_pre_to_post_survey(uuid) from public, anon, authenticated;
revoke all on function public.open_post_survey_round(uuid) from public, anon, authenticated;
revoke all on function public.close_survey_round(uuid) from public, anon, authenticated;
grant execute on function public.transition_pre_to_post_survey(uuid) to authenticated;
grant execute on function public.open_post_survey_round(uuid) to authenticated;
grant execute on function public.close_survey_round(uuid) to authenticated;
