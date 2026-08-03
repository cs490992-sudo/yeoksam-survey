-- Safe, organization-scoped survey round lifecycle transitions.
-- Apply manually after 003_survey_response_revision.sql.

-- This database invariant is the final guard against concurrent requests opening
-- both pre and post rounds for one project.
create unique index survey_rounds_one_open_per_project_idx
  on public.survey_rounds (survey_project_id)
  where status = 'open';

create or replace function public.close_survey_round(p_survey_round_id uuid)
returns table (
  survey_round_id uuid,
  round_status text,
  project_status text,
  ended_at timestamptz,
  already_closed boolean
)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_project public.survey_projects%rowtype;
  v_round public.survey_rounds%rowtype;
  v_project_status text;
  v_ended_at timestamptz;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '조사 회차를 종료할 권한이 없습니다.'; end if;

  select r.* into v_round
  from public.survey_rounds r
  join public.survey_projects sp on sp.id = r.survey_project_id
  where r.id = p_survey_round_id and sp.organization_id = v_organization_id
  for update of r;
  if v_round.id is null then raise exception '조사 회차를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;

  select sp.* into v_project from public.survey_projects sp
  where sp.id = v_round.survey_project_id
  for update;
  if v_project.id is null or v_project.organization_id <> v_organization_id then
    raise exception '조사와 회차의 소속을 확인할 수 없습니다.';
  end if;

  if v_round.status = 'closed' then
    return query select v_round.id, v_round.status, v_project.status,
      v_round.ends_at, true;
    return;
  end if;
  if v_round.status <> 'open' then raise exception '진행 중인 회차만 종료할 수 있습니다.'; end if;
  if v_project.status <> 'open' then raise exception '진행 중인 조사만 종료할 수 있습니다.'; end if;
  if (v_project.survey_type = 'single' and v_round.round_type <> 'single') or
     (v_project.survey_type = 'pre_post' and v_round.round_type not in ('pre', 'post')) then
    raise exception '조사 유형과 회차 유형이 일치하지 않습니다.';
  end if;
  if exists (
    select 1 from public.survey_rounds other
    where other.survey_project_id = v_project.id and other.id <> v_round.id
      and other.status = 'open'
  ) then raise exception '같은 조사에 여러 진행 중 회차가 있어 종료할 수 없습니다.'; end if;

  v_ended_at := now();
  update public.survey_rounds
  set status = 'closed', ends_at = v_ended_at
  where id = v_round.id and survey_project_id = v_project.id and status = 'open';
  if not found then raise exception '회차 상태가 변경되어 종료하지 못했습니다.'; end if;

  v_project_status := case when v_round.round_type = 'pre' then 'open' else 'closed' end;
  if v_project_status = 'closed' then
    update public.survey_projects
    set status = 'closed', ends_at = v_ended_at
    where id = v_project.id and organization_id = v_organization_id and status = 'open';
    if not found then raise exception '조사 상태가 변경되어 종료하지 못했습니다.'; end if;
  end if;

  return query select v_round.id, 'closed'::text, v_project_status,
    v_ended_at, false;
end;
$$;

create or replace function public.open_post_survey_round(p_survey_project_id uuid)
returns table (
  survey_round_id uuid,
  round_status text,
  project_status text,
  started_at timestamptz
)
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
  v_started_at timestamptz;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '사후 조사를 시작할 권한이 없습니다.'; end if;

  select sp.* into v_project from public.survey_projects sp
  where sp.id = p_survey_project_id and sp.organization_id = v_organization_id
  for update;
  if v_project.id is null then raise exception '조사를 찾을 수 없거나 다른 기관의 조사입니다.'; end if;
  if v_project.survey_type <> 'pre_post' then raise exception '사전·사후 조사만 사후 회차를 시작할 수 있습니다.'; end if;
  if v_project.status <> 'open' then raise exception '진행 중인 조사만 사후 회차를 시작할 수 있습니다.'; end if;

  select r.* into v_pre from public.survey_rounds r
  where r.survey_project_id = v_project.id and r.round_type = 'pre'
  for update;
  select r.* into v_post from public.survey_rounds r
  where r.survey_project_id = v_project.id and r.round_type = 'post'
  for update;
  if v_pre.id is null or v_post.id is null then raise exception '사전·사후 회차 구성이 올바르지 않습니다.'; end if;
  if v_pre.status <> 'closed' then raise exception '사전 회차가 종료된 뒤 사후 조사를 시작할 수 있습니다.'; end if;
  if v_post.status <> 'pending' then raise exception '아직 시작하지 않은 사후 회차만 시작할 수 있습니다.'; end if;
  if exists (
    select 1 from public.survey_rounds r
    where r.survey_project_id = v_project.id and r.status = 'open'
  ) then raise exception '이미 진행 중인 회차가 있습니다.'; end if;

  v_started_at := now();
  update public.survey_rounds
  set status = 'open', starts_at = v_started_at, ends_at = null
  where id = v_post.id and survey_project_id = v_project.id and status = 'pending';
  if not found then raise exception '사후 회차 상태가 변경되어 시작하지 못했습니다.'; end if;

  return query select v_post.id, 'open'::text, 'open'::text, v_started_at;
end;
$$;

revoke all on function public.close_survey_round(uuid) from public, anon;
revoke all on function public.open_post_survey_round(uuid) from public, anon;
grant execute on function public.close_survey_round(uuid) to authenticated;
grant execute on function public.open_post_survey_round(uuid) to authenticated;
