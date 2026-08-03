-- Manually apply after 001_survey_core.sql. This migration intentionally keeps
-- response tables SELECT-only and exposes only validated, staff-assisted writes.

create or replace function public.start_or_resume_survey_submission(
  p_survey_round_id uuid,
  p_client_id uuid
)
returns table (submission_id uuid, submission_status text, round_type text, already_completed boolean)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_project_id uuid;
  v_round_type text;
  v_submission public.survey_submissions%rowtype;
begin
  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '조사를 진행할 권한이 없습니다.'; end if;

  select sp.id, r.round_type into v_project_id, v_round_type
  from public.survey_rounds r
  join public.survey_projects sp on sp.id = r.survey_project_id
  where r.id = p_survey_round_id and sp.organization_id = v_organization_id
    and sp.status = 'open' and r.status = 'open';
  if v_project_id is null then raise exception '진행 가능한 조사 회차가 아닙니다.'; end if;
  if not exists (
    select 1 from public.survey_participants participant
    join public.clients c on c.id = participant.client_id
    where participant.survey_project_id = v_project_id and participant.client_id = p_client_id
      and c.organization_id = v_organization_id
  ) then raise exception '등록된 조사 참여자가 아닙니다.'; end if;

  insert into public.survey_submissions (survey_round_id, client_id, status, staff_assisted)
  values (p_survey_round_id, p_client_id, 'draft', true)
  on conflict (survey_round_id, client_id) do update
    set staff_assisted = case when public.survey_submissions.status = 'draft' then true else public.survey_submissions.staff_assisted end
  returning * into v_submission;

  return query select v_submission.id, v_submission.status, v_round_type,
    v_submission.status = 'submitted';
end;
$$;

create or replace function public.save_survey_answer(
  p_submission_id uuid,
  p_question_id uuid,
  p_numeric_value numeric,
  p_text_value text,
  p_option_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_response_type text;
  v_answer_id uuid;
  v_option_ids uuid[] := coalesce(p_option_ids, array[]::uuid[]);
  v_option_count integer;
begin
  select p.organization_id into v_organization_id from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '응답을 저장할 권한이 없습니다.'; end if;

  select q.response_type into v_response_type
  from public.survey_submissions s
  join public.survey_rounds r on r.id = s.survey_round_id
  join public.survey_projects sp on sp.id = r.survey_project_id
  join public.survey_questions q on q.survey_project_id = sp.id and q.id = p_question_id
  where s.id = p_submission_id and s.status = 'draft' and sp.organization_id = v_organization_id
    and sp.status = 'open' and r.status = 'open';
  if v_response_type is null then raise exception '저장 가능한 응답이 아닙니다.'; end if;

  if cardinality(v_option_ids) <> (select count(distinct x) from unnest(v_option_ids) x) then
    raise exception '중복된 선택지는 저장할 수 없습니다.';
  end if;
  select count(*) into v_option_count from public.survey_question_options o
  where o.survey_question_id = p_question_id and o.id = any(v_option_ids);
  if v_option_count <> cardinality(v_option_ids) then raise exception '유효하지 않은 선택지입니다.'; end if;

  if v_response_type in ('face_3', 'scale_3') then
    if p_numeric_value is null or p_numeric_value not in (1,2,3) or p_text_value is not null or cardinality(v_option_ids) <> 0 then raise exception '응답 형식이 올바르지 않습니다.'; end if;
  elsif v_response_type in ('face_5', 'scale_5') then
    if p_numeric_value is null or p_numeric_value not in (1,2,3,4,5) or p_text_value is not null or cardinality(v_option_ids) <> 0 then raise exception '응답 형식이 올바르지 않습니다.'; end if;
  elsif v_response_type in ('yes_no', 'single_choice') then
    if cardinality(v_option_ids) <> 1 or p_numeric_value is not null or p_text_value is not null then raise exception '선택지를 하나 선택해 주세요.'; end if;
  elsif v_response_type = 'multiple_choice' then
    if cardinality(v_option_ids) < 1 or p_numeric_value is not null or p_text_value is not null then raise exception '선택지를 하나 이상 선택해 주세요.'; end if;
  elsif v_response_type = 'staff_note' then
    if p_text_value is null or btrim(p_text_value) = '' or length(p_text_value) > 2000 or p_numeric_value is not null or cardinality(v_option_ids) <> 0 then raise exception '메모 내용을 확인해 주세요.'; end if;
  else raise exception '지원하지 않는 응답 유형입니다.';
  end if;

  insert into public.survey_answers (survey_submission_id, survey_question_id, numeric_value, text_value, staff_note)
  values (p_submission_id, p_question_id, p_numeric_value,
    case when v_response_type = 'staff_note' then null else p_text_value end,
    case when v_response_type = 'staff_note' then p_text_value else null end)
  on conflict (survey_submission_id, survey_question_id) do update
    set numeric_value = excluded.numeric_value, text_value = excluded.text_value,
      staff_note = excluded.staff_note, updated_at = now()
  returning id into v_answer_id;

  delete from public.survey_answer_options ao where ao.survey_answer_id = v_answer_id;
  insert into public.survey_answer_options (survey_answer_id, survey_question_option_id)
  select v_answer_id, x from unnest(v_option_ids) x;
  return v_answer_id;
end;
$$;

create or replace function public.submit_survey_submission(p_submission_id uuid)
returns table (submission_id uuid, submission_status text, submitted_at timestamptz)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_submission public.survey_submissions%rowtype;
  v_project_id uuid;
  v_missing integer;
begin
  select p.organization_id into v_organization_id from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '조사를 제출할 권한이 없습니다.'; end if;

  select s.* into v_submission
  from public.survey_submissions s
  join public.survey_rounds r on r.id = s.survey_round_id
  join public.survey_projects sp on sp.id = r.survey_project_id
  join public.survey_participants participant on participant.survey_project_id = sp.id and participant.client_id = s.client_id
  join public.clients c on c.id = s.client_id and c.organization_id = sp.organization_id
  where s.id = p_submission_id and sp.organization_id = v_organization_id
    and sp.status = 'open' and r.status = 'open'
  for update of s;
  if v_submission.id is null then raise exception '제출 가능한 조사가 아닙니다.'; end if;

  select r.survey_project_id into v_project_id
  from public.survey_rounds r
  where r.id = v_submission.survey_round_id;

  if v_submission.status = 'submitted' then
    return query select v_submission.id, v_submission.status, v_submission.submitted_at; return;
  end if;

  select count(*) into v_missing
  from public.survey_questions q
  left join public.survey_answers a on a.survey_submission_id = p_submission_id and a.survey_question_id = q.id
  where q.survey_project_id = v_project_id and q.is_required and (
    a.id is null or
    (q.response_type in ('face_3','scale_3') and (a.numeric_value is null or a.numeric_value not in (1,2,3))) or
    (q.response_type in ('face_5','scale_5') and (a.numeric_value is null or a.numeric_value not in (1,2,3,4,5))) or
    (q.response_type in ('yes_no','single_choice') and 1 <> (select count(*) from public.survey_answer_options ao where ao.survey_answer_id = a.id)) or
    (q.response_type = 'multiple_choice' and 1 > (select count(*) from public.survey_answer_options ao where ao.survey_answer_id = a.id)) or
    (q.response_type = 'staff_note' and (a.staff_note is null or btrim(a.staff_note) = ''))
  );
  if v_missing > 0 then raise exception '필수 문항의 응답을 확인해 주세요.'; end if;

  update public.survey_submissions set status = 'submitted', submitted_at = now(),
    submitted_by = v_user_id, staff_assisted = true
  where id = p_submission_id and status = 'draft'
  returning * into v_submission;
  return query select v_submission.id, v_submission.status, v_submission.submitted_at;
end;
$$;

revoke all on function public.start_or_resume_survey_submission(uuid, uuid) from public, anon;
revoke all on function public.save_survey_answer(uuid, uuid, numeric, text, uuid[]) from public, anon;
revoke all on function public.submit_survey_submission(uuid) from public, anon;
grant execute on function public.start_or_resume_survey_submission(uuid, uuid) to authenticated;
grant execute on function public.save_survey_answer(uuid, uuid, numeric, text, uuid[]) to authenticated;
grant execute on function public.submit_survey_submission(uuid) to authenticated;
