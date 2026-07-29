-- First-install survey schema. Review this file before manually applying it.
--
-- Verified shared schema: organizations, clients, programs and profiles use UUID keys;
-- profiles.role is public.user_role ('admin', 'staff'). Shared tables are referenced
-- but never altered by this migration.

create extension if not exists pgcrypto;

create table public.survey_projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  program_id uuid null references public.programs(id) on delete restrict,
  title text not null check (btrim(title) <> ''),
  description text null,
  survey_type text not null check (survey_type in ('single', 'pre_post')),
  template_key text null,
  status text not null default 'draft' check (status in ('draft', 'open', 'closed', 'archived')),
  starts_at timestamptz null,
  ends_at timestamptz null,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.survey_rounds (
  id uuid primary key default gen_random_uuid(),
  survey_project_id uuid not null references public.survey_projects(id) on delete cascade,
  round_type text not null check (round_type in ('single', 'pre', 'post')),
  status text not null default 'pending' check (status in ('pending', 'open', 'closed')),
  starts_at timestamptz null,
  ends_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (survey_project_id, round_type)
);

create table public.survey_questions (
  id uuid primary key default gen_random_uuid(),
  survey_project_id uuid not null references public.survey_projects(id) on delete cascade,
  domain text null,
  question_text text not null check (btrim(question_text) <> ''),
  response_type text not null check (response_type in ('face_3', 'face_5', 'scale_3', 'scale_5', 'yes_no', 'single_choice', 'multiple_choice', 'staff_note')),
  sort_order integer not null check (sort_order >= 1),
  is_required boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (survey_project_id, sort_order)
);

create table public.survey_question_options (
  id uuid primary key default gen_random_uuid(),
  survey_question_id uuid not null references public.survey_questions(id) on delete cascade,
  label text not null check (btrim(label) <> ''),
  numeric_value numeric null,
  image_path text null,
  sort_order integer not null check (sort_order >= 1),
  created_at timestamptz not null default now(),
  unique (survey_question_id, sort_order)
);

create table public.survey_participants (
  id uuid primary key default gen_random_uuid(),
  survey_project_id uuid not null references public.survey_projects(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete restrict,
  created_at timestamptz not null default now(),
  unique (survey_project_id, client_id)
);

create table public.survey_submissions (
  id uuid primary key default gen_random_uuid(),
  survey_round_id uuid not null references public.survey_rounds(id) on delete cascade,
  client_id uuid not null references public.clients(id) on delete restrict,
  status text not null default 'draft' check (status in ('draft', 'submitted')),
  staff_assisted boolean not null default false,
  submitted_by uuid null,
  submitted_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (survey_round_id, client_id)
);

create table public.survey_answers (
  id uuid primary key default gen_random_uuid(),
  survey_submission_id uuid not null references public.survey_submissions(id) on delete cascade,
  survey_question_id uuid not null references public.survey_questions(id) on delete cascade,
  numeric_value numeric null,
  text_value text null,
  staff_note text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (survey_submission_id, survey_question_id)
);

create table public.survey_answer_options (
  survey_answer_id uuid not null references public.survey_answers(id) on delete cascade,
  survey_question_option_id uuid not null references public.survey_question_options(id) on delete cascade,
  primary key (survey_answer_id, survey_question_option_id)
);

-- Foreign-key columns used by RLS joins and operational list filters.
create index if not exists survey_projects_organization_id_idx on public.survey_projects (organization_id);
create index if not exists survey_projects_status_idx on public.survey_projects (status);
create index if not exists survey_projects_program_id_idx on public.survey_projects (program_id);
-- Unique(survey_project_id, round_type) already supports round project lookups.
-- Unique(survey_project_id, sort_order) already supports question project lookups.
-- Unique(survey_question_id, sort_order) already supports option question lookups.
-- Unique(survey_project_id, client_id) already supports participant project lookups.
create index if not exists survey_participants_client_id_idx on public.survey_participants (client_id);
-- Unique(survey_round_id, client_id) already supports submission round lookups.
create index if not exists survey_submissions_client_id_idx on public.survey_submissions (client_id);
-- Unique(survey_submission_id, survey_question_id) supports answer submission lookups.
create index if not exists survey_answers_question_id_idx on public.survey_answers (survey_question_id);
create index if not exists survey_answer_options_question_option_id_idx on public.survey_answer_options (survey_question_option_id);

create or replace function public.survey_set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.survey_set_updated_at() from public;
revoke all on function public.survey_set_updated_at() from anon;
revoke all on function public.survey_set_updated_at() from authenticated;

create or replace function public.survey_validate_project_program()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.program_id is not null and not exists (
    select 1
    from public.programs p
    where p.id = new.program_id
      and p.organization_id = new.organization_id
  ) then
    raise exception '조사 기관과 프로그램 기관이 일치하지 않습니다.';
  end if;
  return new;
end;
$$;

create or replace function public.survey_protect_project_update()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  single_count integer;
  pre_count integer;
  post_count integer;
begin
  if new.organization_id is distinct from old.organization_id then
    raise exception '조사의 기관은 변경할 수 없습니다.';
  end if;
  if new.created_by is distinct from old.created_by then
    raise exception '조사 생성자는 변경할 수 없습니다.';
  end if;
  if new.status is distinct from old.status and not (
    (old.status = 'draft' and new.status = 'open') or
    (old.status = 'open' and new.status = 'closed') or
    (old.status = 'closed' and new.status = 'archived') or
    (old.status = 'archived' and new.status = 'closed')
  ) then
    raise exception '허용되지 않은 조사 상태 변경입니다.';
  end if;
  if old.status <> 'draft' and (
    new.title is distinct from old.title or
    new.description is distinct from old.description or
    new.survey_type is distinct from old.survey_type or
    new.template_key is distinct from old.template_key or
    new.program_id is distinct from old.program_id
  ) then
    raise exception '시작된 조사의 구조는 변경할 수 없습니다.';
  end if;

  -- A project may only open after its complete round structure exists.
  if old.status = 'draft' and new.status = 'open' then
    if new.title is distinct from old.title or
       new.description is distinct from old.description or
       new.survey_type is distinct from old.survey_type or
       new.template_key is distinct from old.template_key or
       new.program_id is distinct from old.program_id or
       new.organization_id is distinct from old.organization_id or
       new.created_by is distinct from old.created_by then
      raise exception '조사 시작과 구조 변경은 동시에 할 수 없습니다.';
    end if;
    select
      count(*) filter (where round_type = 'single'),
      count(*) filter (where round_type = 'pre'),
      count(*) filter (where round_type = 'post')
    into single_count, pre_count, post_count
    from public.survey_rounds
    where survey_project_id = old.id;
    if (new.survey_type = 'single' and not (single_count = 1 and pre_count = 0 and post_count = 0)) or
       (new.survey_type = 'pre_post' and not (single_count = 0 and pre_count = 1 and post_count = 1)) then
      raise exception '조사 회차 구성을 확인해 주세요.';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.survey_protect_question_project()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.survey_project_id is distinct from old.survey_project_id then
    raise exception '질문을 다른 조사로 이동할 수 없습니다.';
  end if;
  return new;
end;
$$;

create or replace function public.survey_protect_option_question()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if new.survey_question_id is distinct from old.survey_question_id then
    raise exception '선택지를 다른 질문으로 이동할 수 없습니다.';
  end if;
  return new;
end;
$$;

create or replace function public.survey_validate_participant_organization()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and (
    new.survey_project_id is distinct from old.survey_project_id or
    new.client_id is distinct from old.client_id
  ) then
    raise exception '참여자의 조사 또는 이용인은 변경할 수 없습니다.';
  end if;
  if not exists (
    select 1
    from public.survey_projects sp
    join public.clients c on c.organization_id = sp.organization_id
    where sp.id = new.survey_project_id
      and c.id = new.client_id
  ) then
    raise exception '조사 기관과 이용인 기관이 일치하지 않습니다.';
  end if;
  return new;
end;
$$;

create or replace function public.survey_validate_round()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
declare
  project_type text;
begin
  if tg_op = 'UPDATE' and (
    new.survey_project_id is distinct from old.survey_project_id or
    new.round_type is distinct from old.round_type
  ) then
    raise exception '조사 회차의 소속과 유형은 변경할 수 없습니다.';
  end if;
  if tg_op = 'UPDATE' and new.status is distinct from old.status and not (
    (old.status = 'pending' and new.status = 'open') or
    (old.status = 'open' and new.status = 'closed')
  ) then
    raise exception '허용되지 않은 조사 회차 상태 변경입니다.';
  end if;
  select survey_type into project_type
  from public.survey_projects
  where id = new.survey_project_id;
  if project_type is null or
     (project_type = 'single' and new.round_type <> 'single') or
     (project_type = 'pre_post' and new.round_type not in ('pre', 'post')) then
    raise exception '조사 유형에 맞지 않는 회차입니다.';
  end if;
  return new;
end;
$$;

create or replace function public.survey_validate_submission_participant()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and (
    new.survey_round_id is distinct from old.survey_round_id or
    new.client_id is distinct from old.client_id
  ) then
    raise exception '제출의 회차 또는 이용인은 변경할 수 없습니다.';
  end if;
  if not exists (
    select 1
    from public.survey_rounds r
    join public.survey_participants p on p.survey_project_id = r.survey_project_id
    where r.id = new.survey_round_id and p.client_id = new.client_id
  ) then
    raise exception '조사 참여자로 등록되지 않은 이용인입니다.';
  end if;
  return new;
end;
$$;

create or replace function public.survey_validate_answer_question()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and (
    new.survey_submission_id is distinct from old.survey_submission_id or
    new.survey_question_id is distinct from old.survey_question_id
  ) then
    raise exception '응답의 제출 또는 질문은 변경할 수 없습니다.';
  end if;
  if not exists (
    select 1
    from public.survey_submissions s
    join public.survey_rounds r on r.id = s.survey_round_id
    join public.survey_questions q on q.survey_project_id = r.survey_project_id
    where s.id = new.survey_submission_id and q.id = new.survey_question_id
  ) then
    raise exception '응답과 질문의 조사 정보가 일치하지 않습니다.';
  end if;
  return new;
end;
$$;

create or replace function public.survey_validate_answer_option()
returns trigger
language plpgsql
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'UPDATE' and (
    new.survey_answer_id is distinct from old.survey_answer_id or
    new.survey_question_option_id is distinct from old.survey_question_option_id
  ) then
    raise exception '응답 선택지 연결은 변경할 수 없습니다.';
  end if;
  if not exists (
    select 1
    from public.survey_answers a
    join public.survey_question_options o on o.survey_question_id = a.survey_question_id
    where a.id = new.survey_answer_id and o.id = new.survey_question_option_id
  ) then
    raise exception '응답 질문에 속하지 않은 선택지입니다.';
  end if;
  return new;
end;
$$;

revoke all on function public.survey_validate_project_program() from public, anon, authenticated;
revoke all on function public.survey_protect_project_update() from public, anon, authenticated;
revoke all on function public.survey_protect_question_project() from public, anon, authenticated;
revoke all on function public.survey_protect_option_question() from public, anon, authenticated;
revoke all on function public.survey_validate_participant_organization() from public, anon, authenticated;
revoke all on function public.survey_validate_round() from public, anon, authenticated;
revoke all on function public.survey_validate_submission_participant() from public, anon, authenticated;
revoke all on function public.survey_validate_answer_question() from public, anon, authenticated;
revoke all on function public.survey_validate_answer_option() from public, anon, authenticated;

create trigger survey_projects_validate_program
before insert or update on public.survey_projects
for each row execute function public.survey_validate_project_program();
create trigger survey_projects_protect_update
before update on public.survey_projects
for each row execute function public.survey_protect_project_update();
create trigger survey_projects_set_updated_at
before update on public.survey_projects
for each row execute function public.survey_set_updated_at();
create trigger survey_rounds_validate
before insert or update on public.survey_rounds
for each row execute function public.survey_validate_round();
create trigger survey_rounds_set_updated_at
before update on public.survey_rounds
for each row execute function public.survey_set_updated_at();
create trigger survey_questions_set_updated_at
before update on public.survey_questions
for each row execute function public.survey_set_updated_at();
create trigger survey_questions_protect_project
before update on public.survey_questions
for each row execute function public.survey_protect_question_project();
create trigger survey_question_options_protect_question
before update on public.survey_question_options
for each row execute function public.survey_protect_option_question();
create trigger survey_participants_validate_organization
before insert or update on public.survey_participants
for each row execute function public.survey_validate_participant_organization();
create trigger survey_submissions_validate_participant
before insert or update on public.survey_submissions
for each row execute function public.survey_validate_submission_participant();
create trigger survey_submissions_set_updated_at
before update on public.survey_submissions
for each row execute function public.survey_set_updated_at();
create trigger survey_answers_validate_question
before insert or update on public.survey_answers
for each row execute function public.survey_validate_answer_question();
create trigger survey_answers_set_updated_at
before update on public.survey_answers
for each row execute function public.survey_set_updated_at();
create trigger survey_answer_options_validate
before insert or update on public.survey_answer_options
for each row execute function public.survey_validate_answer_option();

alter table public.survey_projects enable row level security;
alter table public.survey_rounds enable row level security;
alter table public.survey_questions enable row level security;
alter table public.survey_question_options enable row level security;
alter table public.survey_participants enable row level security;
alter table public.survey_submissions enable row level security;
alter table public.survey_answers enable row level security;
alter table public.survey_answer_options enable row level security;

-- Project policies.
create policy survey_projects_select on public.survey_projects
for select to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')
    and p.organization_id = survey_projects.organization_id
));
create policy survey_projects_insert on public.survey_projects
for insert to authenticated
with check (
  survey_projects.status = 'draft' and survey_projects.created_by = auth.uid() and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')
      and p.organization_id = survey_projects.organization_id
  )
);
create policy survey_projects_update on public.survey_projects
for update to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')
    and p.organization_id = survey_projects.organization_id
))
with check (exists (
  select 1 from public.profiles p
  where p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')
    and p.organization_id = survey_projects.organization_id
));
create policy survey_projects_delete on public.survey_projects
for delete to authenticated
using (exists (
  select 1 from public.profiles p
  where p.id = auth.uid() and p.is_active = true and p.role = 'admin'
    and p.organization_id = survey_projects.organization_id
));

-- Round policies. Inserts/deletes require draft; operational updates allow draft/open.
create policy survey_rounds_select on public.survey_rounds for select to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_rounds.survey_project_id and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_rounds_insert on public.survey_rounds for insert to authenticated
with check (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_rounds.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_rounds_update on public.survey_rounds for update to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_rounds.survey_project_id and sp.status in ('draft', 'open') and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')))
with check (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_rounds.survey_project_id and sp.status in ('draft', 'open') and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_rounds_delete on public.survey_rounds for delete to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_rounds.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));

-- Question policies: writes are draft-only.
create policy survey_questions_select on public.survey_questions for select to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_questions.survey_project_id and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_questions_insert on public.survey_questions for insert to authenticated
with check (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_questions.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_questions_update on public.survey_questions for update to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_questions.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')))
with check (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_questions.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_questions_delete on public.survey_questions for delete to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_questions.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));

-- Option policies: resolve organization/status through the owning question.
create policy survey_question_options_select on public.survey_question_options for select to authenticated
using (exists (select 1 from public.survey_questions q join public.survey_projects sp on sp.id = q.survey_project_id join public.profiles p on p.organization_id = sp.organization_id where q.id = survey_question_options.survey_question_id and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_question_options_insert on public.survey_question_options for insert to authenticated
with check (exists (select 1 from public.survey_questions q join public.survey_projects sp on sp.id = q.survey_project_id join public.profiles p on p.organization_id = sp.organization_id where q.id = survey_question_options.survey_question_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_question_options_update on public.survey_question_options for update to authenticated
using (exists (select 1 from public.survey_questions q join public.survey_projects sp on sp.id = q.survey_project_id join public.profiles p on p.organization_id = sp.organization_id where q.id = survey_question_options.survey_question_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')))
with check (exists (select 1 from public.survey_questions q join public.survey_projects sp on sp.id = q.survey_project_id join public.profiles p on p.organization_id = sp.organization_id where q.id = survey_question_options.survey_question_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_question_options_delete on public.survey_question_options for delete to authenticated
using (exists (select 1 from public.survey_questions q join public.survey_projects sp on sp.id = q.survey_project_id join public.profiles p on p.organization_id = sp.organization_id where q.id = survey_question_options.survey_question_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));

-- Participant policies: writes are draft-only.
create policy survey_participants_select on public.survey_participants for select to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_participants.survey_project_id and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_participants_insert on public.survey_participants for insert to authenticated
with check (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id join public.clients c on c.id = survey_participants.client_id and c.organization_id = sp.organization_id where sp.id = survey_participants.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_participants_update on public.survey_participants for update to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id join public.clients c on c.id = survey_participants.client_id and c.organization_id = sp.organization_id where sp.id = survey_participants.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')))
with check (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id join public.clients c on c.id = survey_participants.client_id and c.organization_id = sp.organization_id where sp.id = survey_participants.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_participants_delete on public.survey_participants for delete to authenticated
using (exists (select 1 from public.survey_projects sp join public.profiles p on p.organization_id = sp.organization_id where sp.id = survey_participants.survey_project_id and sp.status = 'draft' and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));

-- Response tables are deliberately SELECT-only in phase 2.
create policy survey_submissions_select on public.survey_submissions for select to authenticated
using (exists (select 1 from public.survey_rounds r join public.survey_projects sp on sp.id = r.survey_project_id join public.profiles p on p.organization_id = sp.organization_id where r.id = survey_submissions.survey_round_id and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_answers_select on public.survey_answers for select to authenticated
using (exists (select 1 from public.survey_submissions s join public.survey_rounds r on r.id = s.survey_round_id join public.survey_projects sp on sp.id = r.survey_project_id join public.profiles p on p.organization_id = sp.organization_id where s.id = survey_answers.survey_submission_id and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));
create policy survey_answer_options_select on public.survey_answer_options for select to authenticated
using (exists (select 1 from public.survey_answers a join public.survey_submissions s on s.id = a.survey_submission_id join public.survey_rounds r on r.id = s.survey_round_id join public.survey_projects sp on sp.id = r.survey_project_id join public.profiles p on p.organization_id = sp.organization_id where a.id = survey_answer_options.survey_answer_id and p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')));

-- Table privileges complement RLS. anon receives no survey-table privileges.
revoke all on table public.survey_projects, public.survey_rounds, public.survey_questions,
  public.survey_question_options, public.survey_participants, public.survey_submissions,
  public.survey_answers, public.survey_answer_options from anon;
revoke all on table public.survey_projects, public.survey_rounds, public.survey_questions,
  public.survey_question_options, public.survey_participants, public.survey_submissions,
  public.survey_answers, public.survey_answer_options from authenticated;
grant select, insert, update, delete on table public.survey_projects, public.survey_rounds,
  public.survey_questions, public.survey_question_options, public.survey_participants to authenticated;
grant select on table public.survey_submissions, public.survey_answers,
  public.survey_answer_options to authenticated;
