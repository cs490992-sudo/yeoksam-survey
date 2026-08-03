-- Immutable snapshots and one transactional, organization-scoped path for editing
-- an already submitted survey. Apply manually after 002_survey_response_rpc.sql.

alter table public.survey_submissions
  add column last_edited_by uuid null,
  add column last_edited_at timestamptz null,
  add column edit_count integer not null default 0 check (edit_count >= 0);

create table public.survey_submission_revisions (
  id uuid primary key default gen_random_uuid(),
  survey_submission_id uuid not null references public.survey_submissions(id) on delete restrict,
  edited_by uuid not null,
  edited_at timestamptz not null default now(),
  edit_reason text null check (edit_reason is null or length(edit_reason) <= 200),
  previous_answers jsonb not null,
  revision_number integer not null check (revision_number >= 1),
  unique (survey_submission_id, revision_number)
);
create index survey_submission_revisions_submission_idx
  on public.survey_submission_revisions (survey_submission_id, revision_number desc);

alter table public.survey_submission_revisions enable row level security;
create policy survey_submission_revisions_select on public.survey_submission_revisions
for select to authenticated using (exists (
  select 1 from public.survey_submissions s
  join public.survey_rounds r on r.id = s.survey_round_id
  join public.survey_projects sp on sp.id = r.survey_project_id
  join public.profiles p on p.organization_id = sp.organization_id
  where s.id = survey_submission_revisions.survey_submission_id
    and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')
));
revoke all on table public.survey_submission_revisions from public, anon, authenticated;
grant select on table public.survey_submission_revisions to authenticated;

create or replace function public.revise_survey_submission(
  p_submission_id uuid,
  p_answers jsonb,
  p_edit_reason text default null
)
returns table (submission_id uuid, submission_status text, last_edited_at timestamptz, edit_count integer)
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_submission public.survey_submissions%rowtype;
  v_project_id uuid;
  v_answer jsonb;
  v_question_id uuid;
  v_type text;
  v_numeric numeric;
  v_text text;
  v_options uuid[];
  v_answer_id uuid;
  v_snapshot jsonb;
  v_distinct_question_count integer;
  v_payload_count integer;
begin
  if v_user_id is null then raise exception '로그인이 필요합니다.'; end if;
  select p.organization_id into v_organization_id from public.profiles p
  where p.id = v_user_id and p.is_active = true and p.role in ('admin', 'staff');
  if v_organization_id is null then raise exception '완료 응답을 수정할 권한이 없습니다.'; end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'array' then raise exception '응답 형식이 올바르지 않습니다.'; end if;
  if p_edit_reason is not null and length(p_edit_reason) > 200 then raise exception '수정 사유는 200자 이하여야 합니다.'; end if;

  select s.* into v_submission
  from public.survey_submissions s
  join public.survey_rounds r on r.id = s.survey_round_id
  join public.survey_projects sp on sp.id = r.survey_project_id
  join public.survey_participants participant on participant.survey_project_id = sp.id and participant.client_id = s.client_id
  join public.clients c on c.id = s.client_id and c.organization_id = sp.organization_id
  where s.id = p_submission_id and s.status = 'submitted'
    and sp.organization_id = v_organization_id and sp.status = 'open' and r.status = 'open'
  for update of s;
  if v_submission.id is null then raise exception '수정 가능한 완료 응답이 아닙니다.'; end if;
  select r.survey_project_id into v_project_id from public.survey_rounds r where r.id = v_submission.survey_round_id;

  -- Optional questions may be omitted. Compare the payload only with itself to
  -- reject duplicate question IDs; do not compare it with the survey's total
  -- question count.
  select count(*), count(distinct (x->>'question_id')) into v_payload_count, v_distinct_question_count
  from jsonb_array_elements(p_answers) x;
  if v_payload_count <> v_distinct_question_count then raise exception '중복된 문항은 저장할 수 없습니다.'; end if;
  if exists (select 1 from jsonb_array_elements(p_answers) x where coalesce(x->>'question_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
  then raise exception '문항 식별자가 올바르지 않습니다.'; end if;
  if exists (select 1 from jsonb_array_elements(p_answers) x
    where not exists (select 1 from public.survey_questions q where q.id = (x->>'question_id')::uuid and q.survey_project_id = v_project_id))
  then raise exception '다른 조사의 문항은 수정할 수 없습니다.'; end if;

  for v_answer in select value from jsonb_array_elements(p_answers) loop
    v_question_id := (v_answer->>'question_id')::uuid;
    select q.response_type into v_type from public.survey_questions q
      where q.id = v_question_id and q.survey_project_id = v_project_id;
    v_numeric := case when v_answer->>'numeric_value' is null then null else (v_answer->>'numeric_value')::numeric end;
    v_text := v_answer->>'text_value';
    if exists (select 1 from jsonb_array_elements_text(coalesce(v_answer->'option_ids', '[]'::jsonb)) o
      where o !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
    then raise exception '선택지 식별자가 올바르지 않습니다.'; end if;
    select coalesce(array_agg(value::uuid), array[]::uuid[]) into v_options
      from jsonb_array_elements_text(coalesce(v_answer->'option_ids', '[]'::jsonb));
    if cardinality(v_options) <> (select count(distinct x) from unnest(v_options) x) then raise exception '중복된 선택지는 저장할 수 없습니다.'; end if;
    if exists (select 1 from unnest(v_options) x where not exists
      (select 1 from public.survey_question_options o where o.id = x and o.survey_question_id = v_question_id))
    then raise exception '다른 문항의 선택지는 저장할 수 없습니다.'; end if;
    if v_type in ('face_3','scale_3') then
      if v_numeric is null or v_numeric not in (1,2,3) or v_text is not null or cardinality(v_options) <> 0 then raise exception '응답 형식이 올바르지 않습니다.'; end if;
    elsif v_type in ('face_5','scale_5') then
      if v_numeric is null or v_numeric not in (1,2,3,4,5) or v_text is not null or cardinality(v_options) <> 0 then raise exception '응답 형식이 올바르지 않습니다.'; end if;
    elsif v_type in ('yes_no','single_choice') then
      if v_numeric is not null or v_text is not null or cardinality(v_options) <> 1 then raise exception '선택지를 하나 선택해 주세요.'; end if;
    elsif v_type = 'multiple_choice' then
      if v_numeric is not null or v_text is not null or cardinality(v_options) < 1 then raise exception '선택지를 하나 이상 선택해 주세요.'; end if;
    elsif v_type = 'staff_note' then
      if v_numeric is not null or cardinality(v_options) <> 0 or v_text is null or btrim(v_text) = '' or length(v_text) > 2000 then raise exception '메모 내용을 확인해 주세요.'; end if;
    else raise exception '지원하지 않는 응답 유형입니다.';
    end if;
  end loop;

  if exists (select 1 from public.survey_questions q where q.survey_project_id = v_project_id and q.is_required
    and not exists (select 1 from jsonb_array_elements(p_answers) x where (x->>'question_id')::uuid = q.id))
  then raise exception '필수 문항의 응답을 확인해 주세요.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'question_id', q.id, 'response_type', q.response_type, 'numeric_value', a.numeric_value,
    'text_value', a.text_value, 'staff_note', a.staff_note, 'option_ids', coalesce(
      (select jsonb_agg(ao.survey_question_option_id order by ao.survey_question_option_id) from public.survey_answer_options ao where ao.survey_answer_id = a.id), '[]'::jsonb)
  ) order by q.sort_order), '[]'::jsonb) into v_snapshot
  from public.survey_answers a join public.survey_questions q on q.id = a.survey_question_id
  where a.survey_submission_id = p_submission_id;
  insert into public.survey_submission_revisions
    (survey_submission_id, edited_by, edit_reason, previous_answers, revision_number)
  values (p_submission_id, v_user_id, nullif(btrim(p_edit_reason), ''), v_snapshot, v_submission.edit_count + 1);

  delete from public.survey_answer_options ao using public.survey_answers a
    where ao.survey_answer_id = a.id and a.survey_submission_id = p_submission_id;
  delete from public.survey_answers a where a.survey_submission_id = p_submission_id;
  for v_answer in select value from jsonb_array_elements(p_answers) loop
    v_question_id := (v_answer->>'question_id')::uuid;
    select q.response_type into v_type from public.survey_questions q where q.id = v_question_id;
    insert into public.survey_answers (survey_submission_id, survey_question_id, numeric_value, text_value, staff_note)
    values (p_submission_id, v_question_id, nullif(v_answer->>'numeric_value','')::numeric,
      case when v_type = 'staff_note' then null else v_answer->>'text_value' end,
      case when v_type = 'staff_note' then v_answer->>'text_value' else null end) returning id into v_answer_id;
    insert into public.survey_answer_options (survey_answer_id, survey_question_option_id)
      select v_answer_id, value::uuid from jsonb_array_elements_text(coalesce(v_answer->'option_ids','[]'::jsonb));
  end loop;
  update public.survey_submissions set last_edited_by = v_user_id, last_edited_at = now(),
    edit_count = survey_submissions.edit_count + 1, status = 'submitted'
  where id = p_submission_id returning * into v_submission;
  return query select v_submission.id, v_submission.status, v_submission.last_edited_at, v_submission.edit_count;
end;
$$;

revoke all on function public.revise_survey_submission(uuid, jsonb, text) from public, anon;
grant execute on function public.revise_survey_submission(uuid, jsonb, text) to authenticated;
