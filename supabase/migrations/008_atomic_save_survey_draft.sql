-- Transactional survey draft replacement and immediate start.
-- Apply manually after 007_survey_question_images.sql.

create or replace function public.save_survey_draft_structure(
  p_survey_project_id uuid,
  p_organization_id uuid,
  p_title text,
  p_description text,
  p_survey_type text,
  p_program_id uuid,
  p_template_key text,
  p_questions jsonb,
  p_participant_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_project_id uuid;
  v_question jsonb;
  v_option jsonb;
  v_question_id uuid;
  v_question_order bigint;
  v_option_order bigint;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null or v_organization_id <> p_organization_id then
    raise exception '조사를 저장할 권한이 없습니다.';
  end if;
  if p_survey_type not in ('single', 'pre_post') then raise exception '조사 유형이 올바르지 않습니다.'; end if;
  if nullif(btrim(p_title), '') is null then raise exception '조사 제목을 입력해 주세요.'; end if;
  if coalesce(jsonb_typeof(p_questions), 'null') <> 'array' or jsonb_array_length(p_questions) = 0 then raise exception '질문을 한 개 이상 추가해 주세요.'; end if;
  if coalesce(array_length(p_participant_ids, 1), 0) = 0 then raise exception '참여 이용인을 한 명 이상 선택해 주세요.'; end if;

  if p_survey_project_id is null then
    insert into public.survey_projects (organization_id, program_id, title, description, survey_type, template_key, status, starts_at, ends_at, created_by)
    values (v_organization_id, p_program_id, btrim(p_title), nullif(btrim(p_description), ''), p_survey_type, p_template_key, 'draft', null, null, v_user_id)
    returning id into v_project_id;
  else
    select sp.id into v_project_id
    from public.survey_projects sp
    where sp.id = p_survey_project_id and sp.organization_id = v_organization_id and sp.status = 'draft'
    for update;
    if v_project_id is null then raise exception '수정할 수 있는 초안 조사를 찾지 못했습니다.'; end if;
    update public.survey_projects
    set program_id = p_program_id, title = btrim(p_title), description = nullif(btrim(p_description), ''),
        survey_type = p_survey_type, template_key = p_template_key, starts_at = null, ends_at = null
    where id = v_project_id;
  end if;

  -- Every statement below participates in this function call's transaction.
  -- Any validation, FK, trigger, or insert failure restores the prior structure.
  delete from public.survey_participants where survey_project_id = v_project_id;
  delete from public.survey_questions where survey_project_id = v_project_id;
  delete from public.survey_rounds where survey_project_id = v_project_id;

  if p_survey_type = 'single' then
    insert into public.survey_rounds (survey_project_id, round_type, status) values (v_project_id, 'single', 'pending');
  else
    insert into public.survey_rounds (survey_project_id, round_type, status)
    values (v_project_id, 'pre', 'pending'), (v_project_id, 'post', 'pending');
  end if;

  for v_question, v_question_order in
    select value, ordinality from jsonb_array_elements(p_questions) with ordinality
  loop
    if nullif(v_question->>'image_path', '') is not null
       and (v_question->>'image_path') not like v_organization_id::text || '/' || v_project_id::text || '/%' then
      raise exception '문항 사진 경로가 조사 기관 또는 프로젝트와 일치하지 않습니다.';
    end if;
    insert into public.survey_questions
      (survey_project_id, domain, question_text, response_type, sort_order, is_required, image_path)
    values
      (v_project_id, nullif(btrim(v_question->>'domain'), ''), btrim(v_question->>'question_text'),
       v_question->>'response_type', v_question_order, coalesce((v_question->>'is_required')::boolean, true),
       nullif(v_question->>'image_path', ''))
    returning id into v_question_id;

    for v_option, v_option_order in
      select value, ordinality from jsonb_array_elements(coalesce(v_question->'options', '[]'::jsonb)) with ordinality
    loop
      insert into public.survey_question_options
        (survey_question_id, label, numeric_value, sort_order)
      values
        (v_question_id, btrim(v_option->>'label'), nullif(v_option->>'numeric_value', '')::numeric, v_option_order);
    end loop;
  end loop;

  insert into public.survey_participants (survey_project_id, client_id)
  select v_project_id, participant_id from unnest(p_participant_ids) as participant(participant_id);

  return v_project_id;
end;
$$;

-- A new image-bearing survey needs a project row before Storage policy permits
-- upload. This narrowly-scoped cleanup removes only the caller's empty shell.
create or replace function public.discard_empty_survey_draft(p_survey_project_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  if not exists (
    select 1 from public.profiles p join public.survey_projects sp on sp.organization_id = p.organization_id
    where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff')
      and sp.id = p_survey_project_id and sp.created_by = v_user_id and sp.status = 'draft'
  ) then raise exception '정리할 수 있는 새 초안을 찾지 못했습니다.'; end if;
  if exists (select 1 from public.survey_rounds where survey_project_id = p_survey_project_id)
     or exists (select 1 from public.survey_questions where survey_project_id = p_survey_project_id)
     or exists (select 1 from public.survey_participants where survey_project_id = p_survey_project_id) then
    raise exception '내용이 저장된 초안은 이 함수로 삭제할 수 없습니다.';
  end if;
  delete from public.survey_projects where id = p_survey_project_id and created_by = v_user_id and status = 'draft';
end;
$$;

create or replace function public.start_draft_survey_project(p_survey_project_id uuid)
returns table(result_project_id uuid, result_round_id uuid, started_at timestamptz)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_project public.survey_projects%rowtype;
  v_round_id uuid;
  v_started_at timestamptz := now();
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select p.organization_id into v_organization_id from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '조사를 시작할 권한이 없습니다.'; end if;
  select sp.* into v_project from public.survey_projects sp
  where sp.id = p_survey_project_id and sp.organization_id = v_organization_id and sp.status = 'draft'
  for update;
  if v_project.id is null then raise exception '시작할 수 있는 초안 조사를 찾지 못했습니다.'; end if;
  if not exists (select 1 from public.survey_questions where survey_project_id = v_project.id) then raise exception '질문을 한 개 이상 추가해 주세요.'; end if;
  if not exists (select 1 from public.survey_participants where survey_project_id = v_project.id) then raise exception '참여 이용인을 한 명 이상 선택해 주세요.'; end if;

  update public.survey_projects set status = 'open', starts_at = v_started_at where id = v_project.id;
  update public.survey_rounds set status = 'open', starts_at = v_started_at, ends_at = null
  where survey_project_id = v_project.id
    and round_type = case when v_project.survey_type = 'single' then 'single' else 'pre' end
    and status = 'pending'
  returning id into v_round_id;
  if v_round_id is null then raise exception '시작할 조사 회차를 찾지 못했습니다.'; end if;
  return query select v_project.id, v_round_id, v_started_at;
end;
$$;

revoke all on function public.save_survey_draft_structure(uuid, uuid, text, text, text, uuid, text, jsonb, uuid[]) from public, anon, authenticated;
revoke all on function public.discard_empty_survey_draft(uuid) from public, anon, authenticated;
revoke all on function public.start_draft_survey_project(uuid) from public, anon, authenticated;
grant execute on function public.save_survey_draft_structure(uuid, uuid, text, text, text, uuid, text, jsonb, uuid[]) to authenticated;
grant execute on function public.discard_empty_survey_draft(uuid) to authenticated;
grant execute on function public.start_draft_survey_project(uuid) to authenticated;
