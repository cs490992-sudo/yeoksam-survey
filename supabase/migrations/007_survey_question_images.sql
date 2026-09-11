-- Optional, private question images for surveys. Apply manually after 006.
-- Shared organizations/profiles/clients/programs tables are only read by policies.

alter table public.survey_questions
  add column image_path text null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'survey-question-images',
  'survey-question-images',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Object names are organization/project/question/random-file.ext. Both the
-- organization folder and project ownership are checked to prevent cross-tenant access.
create policy survey_question_images_select
on storage.objects for select to authenticated
using (
  bucket_id = 'survey-question-images'
  and exists (
    select 1
    from public.profiles p
    join public.survey_projects sp on sp.organization_id = p.organization_id
    where p.id = auth.uid()
      and p.is_active = true
      and p.role in ('admin', 'staff')
      and (storage.foldername(name))[1] = p.organization_id::text
      and (storage.foldername(name))[2] = sp.id::text
  )
);

create policy survey_question_images_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'survey-question-images'
  and exists (
    select 1
    from public.profiles p
    join public.survey_projects sp on sp.organization_id = p.organization_id
    where p.id = auth.uid()
      and p.is_active = true
      and p.role in ('admin', 'staff')
      and sp.status = 'draft'
      and (storage.foldername(name))[1] = p.organization_id::text
      and (storage.foldername(name))[2] = sp.id::text
  )
);

create policy survey_question_images_update
on storage.objects for update to authenticated
using (
  bucket_id = 'survey-question-images'
  and exists (
    select 1 from public.profiles p
    join public.survey_projects sp on sp.organization_id = p.organization_id
    where p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')
      and sp.status = 'draft'
      and (storage.foldername(name))[1] = p.organization_id::text
      and (storage.foldername(name))[2] = sp.id::text
  )
)
with check (
  bucket_id = 'survey-question-images'
  and exists (
    select 1 from public.profiles p
    join public.survey_projects sp on sp.organization_id = p.organization_id
    where p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')
      and sp.status = 'draft'
      and (storage.foldername(name))[1] = p.organization_id::text
      and (storage.foldername(name))[2] = sp.id::text
  )
);

create policy survey_question_images_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'survey-question-images'
  and exists (
    select 1 from public.profiles p
    join public.survey_projects sp on sp.organization_id = p.organization_id
    where p.id = auth.uid() and p.is_active = true and p.role in ('admin', 'staff')
      and sp.status = 'draft'
      and (storage.foldername(name))[1] = p.organization_id::text
      and (storage.foldername(name))[2] = sp.id::text
  )
);
