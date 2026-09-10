-- Add the manually-started scheduled survey lifecycle.
-- Apply manually after 005_delete_survey_project_with_data.sql.

alter table public.survey_projects
  drop constraint if exists survey_projects_status_check;
alter table public.survey_projects
  add constraint survey_projects_status_check
  check (status in ('draft', 'scheduled', 'open', 'closed', 'archived'));

create or replace function public.survey_protect_project_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  single_count integer;
  pre_count integer;
  post_count integer;
  non_pending_count integer;
begin
  if new.organization_id is distinct from old.organization_id then raise exception '조사의 기관은 변경할 수 없습니다.'; end if;
  if new.created_by is distinct from old.created_by then raise exception '조사 생성자는 변경할 수 없습니다.'; end if;
  if new.status is distinct from old.status and not (
    (old.status = 'draft' and new.status in ('scheduled', 'open')) or
    (old.status = 'scheduled' and new.status in ('draft', 'open')) or
    (old.status = 'open' and new.status = 'closed') or
    (old.status = 'closed' and new.status = 'archived') or
    (old.status = 'archived' and new.status = 'closed')
  ) then raise exception '허용되지 않은 조사 상태 변경입니다.'; end if;

  if old.status <> 'draft' and (
    new.title is distinct from old.title or new.description is distinct from old.description or
    new.survey_type is distinct from old.survey_type or new.template_key is distinct from old.template_key or
    new.program_id is distinct from old.program_id
  ) then raise exception '초안이 아닌 조사의 구조는 변경할 수 없습니다.'; end if;

  if new.status is distinct from old.status and new.status in ('scheduled', 'open') then
    if new.title is distinct from old.title or new.description is distinct from old.description or
       new.survey_type is distinct from old.survey_type or new.template_key is distinct from old.template_key or
       new.program_id is distinct from old.program_id or new.organization_id is distinct from old.organization_id or
       new.created_by is distinct from old.created_by then
      raise exception '상태 변경과 조사 구조 변경은 동시에 할 수 없습니다.';
    end if;
    select count(*) filter (where round_type = 'single'), count(*) filter (where round_type = 'pre'),
      count(*) filter (where round_type = 'post'), count(*) filter (where status <> 'pending')
    into single_count, pre_count, post_count, non_pending_count
    from public.survey_rounds where survey_project_id = old.id;
    if (new.survey_type = 'single' and not (single_count = 1 and pre_count = 0 and post_count = 0)) or
       (new.survey_type = 'pre_post' and not (single_count = 0 and pre_count = 1 and post_count = 1)) then
      raise exception '조사 회차 구성을 확인해 주세요.';
    end if;
    if old.status in ('draft', 'scheduled') and non_pending_count <> 0 then
      raise exception '시작 전에는 모든 조사 회차가 대기 상태여야 합니다.';
    end if;
  end if;
  if new.status = 'scheduled' and new.starts_at is not null then
    raise exception '예정 조사는 시작 일시를 기록할 수 없습니다.';
  end if;
  return new;
end;
$$;

create or replace function public.schedule_survey_project(p_survey_project_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid(); v_organization_id uuid; v_project public.survey_projects%rowtype;
  v_single integer; v_pre integer; v_post integer;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select organization_id into v_organization_id from public.profiles
  where id = v_user_id and is_active = true and role in ('admin', 'staff');
  if v_organization_id is null then raise exception '예정 조사를 등록할 권한이 없습니다.'; end if;
  select * into v_project from public.survey_projects
  where id = p_survey_project_id and organization_id = v_organization_id for update;
  if v_project.id is null then raise exception '조사를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;
  if v_project.status <> 'draft' then raise exception '초안 조사만 예정으로 등록할 수 있습니다.'; end if;
  if v_project.starts_at is not null then raise exception '시작되지 않은 조사만 예정으로 등록할 수 있습니다.'; end if;
  if not exists (select 1 from public.survey_questions where survey_project_id = v_project.id) then raise exception '질문을 한 개 이상 추가해 주세요.'; end if;
  if not exists (select 1 from public.survey_participants where survey_project_id = v_project.id) then raise exception '참여 이용인을 한 명 이상 선택해 주세요.'; end if;
  if exists (
    select 1 from public.survey_questions q where q.survey_project_id = v_project.id
      and q.response_type in ('single_choice', 'multiple_choice')
      and (select count(*) from public.survey_question_options o where o.survey_question_id = q.id) < 2
  ) then raise exception '선택형 질문에는 선택지가 두 개 이상 필요합니다.'; end if;
  select count(*) filter(where round_type='single'), count(*) filter(where round_type='pre'), count(*) filter(where round_type='post')
  into v_single,v_pre,v_post from public.survey_rounds where survey_project_id=v_project.id;
  if (v_project.survey_type='single' and not(v_single=1 and v_pre=0 and v_post=0)) or
     (v_project.survey_type='pre_post' and not(v_single=0 and v_pre=1 and v_post=1)) then raise exception '조사 회차 구성이 올바르지 않습니다.'; end if;
  if exists(select 1 from public.survey_rounds where survey_project_id=v_project.id and (status<>'pending' or starts_at is not null or ends_at is not null)) then raise exception '모든 회차가 시작 전 대기 상태여야 합니다.'; end if;
  if exists(select 1 from public.survey_submissions s join public.survey_rounds r on r.id=s.survey_round_id where r.survey_project_id=v_project.id) then raise exception '응답이 있는 조사는 예정으로 등록할 수 없습니다.'; end if;
  update public.survey_projects set status='scheduled', starts_at=null, ends_at=null where id=v_project.id and status='draft';
  if not found then raise exception '조사 상태가 변경되어 예정으로 등록하지 못했습니다.'; end if;
end;
$$;

create or replace function public.start_scheduled_survey_project(p_survey_project_id uuid)
returns table(result_project_id uuid, result_round_id uuid, started_at timestamptz)
language plpgsql security definer set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid:=auth.uid(); v_organization_id uuid; v_project public.survey_projects%rowtype;
  v_round_id uuid; v_started_at timestamptz; v_single integer; v_pre integer; v_post integer;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select organization_id into v_organization_id from public.profiles where id=v_user_id and is_active=true and role in ('admin','staff');
  if v_organization_id is null then raise exception '예정 조사를 시작할 권한이 없습니다.'; end if;
  select * into v_project from public.survey_projects where id=p_survey_project_id and organization_id=v_organization_id for update;
  if v_project.id is null then raise exception '조사를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;
  if v_project.status<>'scheduled' then raise exception '예정 조사만 시작할 수 있습니다.'; end if;
  select count(*) filter(where round_type='single'),count(*) filter(where round_type='pre'),count(*) filter(where round_type='post')
    into v_single,v_pre,v_post from public.survey_rounds where survey_project_id=v_project.id;
  if (v_project.survey_type='single' and not(v_single=1 and v_pre=0 and v_post=0)) or
     (v_project.survey_type='pre_post' and not(v_single=0 and v_pre=1 and v_post=1)) then raise exception '조사 회차 구성이 올바르지 않습니다.'; end if;
  if exists(select 1 from public.survey_rounds where survey_project_id=v_project.id and (status<>'pending' or starts_at is not null or ends_at is not null)) then raise exception '모든 회차가 시작 전 대기 상태여야 합니다.'; end if;
  if exists(select 1 from public.survey_submissions s join public.survey_rounds r on r.id=s.survey_round_id where r.survey_project_id=v_project.id) then raise exception '응답이 있는 예정 조사는 시작할 수 없습니다.'; end if;
  v_started_at:=now();
  update public.survey_projects set status='open',starts_at=v_started_at,ends_at=null where id=v_project.id and status='scheduled';
  if not found then raise exception '조사 상태가 변경되어 시작하지 못했습니다.'; end if;
  update public.survey_rounds set status='open',starts_at=v_started_at,ends_at=null
    where survey_project_id=v_project.id and round_type=case when v_project.survey_type='single' then 'single' else 'pre' end and status='pending'
    returning id into v_round_id;
  if v_round_id is null then raise exception '시작할 조사 회차를 찾지 못했습니다.'; end if;
  return query select v_project.id,v_round_id,v_started_at;
end;
$$;

create or replace function public.return_scheduled_survey_to_draft(p_survey_project_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare v_user_id uuid:=auth.uid(); v_organization_id uuid; v_project public.survey_projects%rowtype;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select organization_id into v_organization_id from public.profiles where id=v_user_id and is_active=true and role in ('admin','staff');
  if v_organization_id is null then raise exception '예정 조사를 변경할 권한이 없습니다.'; end if;
  select * into v_project from public.survey_projects where id=p_survey_project_id and organization_id=v_organization_id for update;
  if v_project.id is null then raise exception '조사를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;
  if v_project.status<>'scheduled' then raise exception '예정 조사만 초안으로 되돌릴 수 있습니다.'; end if;
  if exists(select 1 from public.survey_rounds where survey_project_id=v_project.id and (status<>'pending' or starts_at is not null or ends_at is not null)) then raise exception '모든 회차가 대기 상태여야 합니다.'; end if;
  if exists(select 1 from public.survey_submissions s join public.survey_rounds r on r.id=s.survey_round_id where r.survey_project_id=v_project.id) then raise exception '응답이 있는 조사는 초안으로 되돌릴 수 없습니다.'; end if;
  update public.survey_projects set status='draft',starts_at=null,ends_at=null where id=v_project.id and status='scheduled';
  if not found then raise exception '조사 상태가 변경되어 초안으로 되돌리지 못했습니다.'; end if;
end;
$$;

create or replace function public.delete_survey_project_with_data(p_survey_project_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog, public
as $$
declare v_user_id uuid:=auth.uid(); v_organization_id uuid; v_project public.survey_projects%rowtype;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select organization_id into v_organization_id from public.profiles where id=v_user_id and is_active=true and role='admin';
  if v_organization_id is null then raise exception '조사를 삭제할 권한이 없습니다.'; end if;
  select * into v_project from public.survey_projects where id=p_survey_project_id and organization_id=v_organization_id for update;
  if v_project.id is null then raise exception '조사를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;
  if v_project.status not in ('draft','scheduled','closed','archived') then raise exception '진행 중인 조사는 삭제할 수 없습니다.'; end if;
  delete from public.survey_submission_revisions revision using public.survey_submissions submission,public.survey_rounds round
    where revision.survey_submission_id=submission.id and submission.survey_round_id=round.id and round.survey_project_id=v_project.id;
  delete from public.survey_projects where id=v_project.id and organization_id=v_organization_id and status in ('draft','scheduled','closed','archived');
  if not found then raise exception '조사 상태가 변경되어 삭제하지 못했습니다.'; end if;
end;
$$;

revoke all on function public.schedule_survey_project(uuid) from public, anon, authenticated;
revoke all on function public.start_scheduled_survey_project(uuid) from public, anon, authenticated;
revoke all on function public.return_scheduled_survey_to_draft(uuid) from public, anon, authenticated;
revoke all on function public.delete_survey_project_with_data(uuid) from public, anon, authenticated;
grant execute on function public.schedule_survey_project(uuid) to authenticated;
grant execute on function public.start_scheduled_survey_project(uuid) to authenticated;
grant execute on function public.return_scheduled_survey_to_draft(uuid) to authenticated;
grant execute on function public.delete_survey_project_with_data(uuid) to authenticated;
