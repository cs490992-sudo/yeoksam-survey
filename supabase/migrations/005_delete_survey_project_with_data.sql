-- Atomically delete an explicitly selected survey and its response history.
-- Apply manually after 004_survey_round_lifecycle.sql.

create or replace function public.delete_survey_project_with_data(
  p_survey_project_id uuid
)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_project public.survey_projects%rowtype;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;

  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role = 'admin';
  if v_organization_id is null then
    raise exception '조사를 삭제할 권한이 없습니다.';
  end if;

  select sp.* into v_project
  from public.survey_projects sp
  where sp.id = p_survey_project_id
    and sp.organization_id = v_organization_id
  for update;
  if v_project.id is null then
    raise exception '조사를 찾을 수 없거나 다른 기관의 조사입니다.';
  end if;
  if v_project.status not in ('draft', 'closed', 'archived') then
    raise exception '진행 중인 조사는 삭제할 수 없습니다.';
  end if;

  -- Revision snapshots deliberately restrict submission deletion. Remove only
  -- snapshots belonging to this locked project before invoking existing cascades.
  delete from public.survey_submission_revisions revision
  using public.survey_submissions submission, public.survey_rounds round
  where revision.survey_submission_id = submission.id
    and submission.survey_round_id = round.id
    and round.survey_project_id = v_project.id;

  delete from public.survey_projects sp
  where sp.id = v_project.id
    and sp.organization_id = v_organization_id
    and sp.status in ('draft', 'closed', 'archived');
  if not found then
    raise exception '조사 상태가 변경되어 삭제하지 못했습니다.';
  end if;
end;
$$;

revoke all on function public.delete_survey_project_with_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_survey_project_with_data(uuid) to authenticated;
