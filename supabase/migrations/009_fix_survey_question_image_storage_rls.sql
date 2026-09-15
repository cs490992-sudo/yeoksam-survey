-- Evaluate question-image authorization without inheriting caller RLS on
-- profiles/survey_projects. Apply manually after 008.

create or replace function public.survey_can_access_question_image(
  p_object_name text,
  p_require_draft boolean,
  p_allow_missing_project_admin boolean default false
)
returns boolean
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_role text;
  v_folders text[];
begin
  if v_user_id is null or p_object_name is null then return false; end if;

  select p.organization_id, p.role::text
  into v_organization_id, v_role
  from public.profiles p
  where p.id = v_user_id
    and p.is_active = true
    and p.role in ('admin', 'staff');

  if v_organization_id is null then return false; end if;
  v_folders := storage.foldername(p_object_name);
  if coalesce(array_length(v_folders, 1), 0) < 2
     or v_folders[1] <> v_organization_id::text then
    return false;
  end if;

  if exists (
    select 1
    from public.survey_projects sp
    where sp.id::text = v_folders[2]
      and sp.organization_id = v_organization_id
      and (not p_require_draft or sp.status = 'draft')
  ) then
    return true;
  end if;

  -- After the admin-only project deletion RPC commits, the project row no
  -- longer exists. Permit cleanup only under that admin's own organization.
  return p_allow_missing_project_admin
    and v_role = 'admin'
    and not exists (
      select 1 from public.survey_projects sp where sp.id::text = v_folders[2]
    );
end;
$$;

revoke all on function public.survey_can_access_question_image(text, boolean, boolean)
from public, anon, authenticated;
grant execute on function public.survey_can_access_question_image(text, boolean, boolean)
to authenticated;

-- Preserve the private bucket and its server-enforced upload constraints.
update storage.buckets
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id = 'survey-question-images';

drop policy if exists survey_question_images_select on storage.objects;
drop policy if exists survey_question_images_insert on storage.objects;
drop policy if exists survey_question_images_update on storage.objects;
drop policy if exists survey_question_images_delete on storage.objects;

create policy survey_question_images_select
on storage.objects for select to authenticated
using (
  bucket_id = 'survey-question-images'
  and public.survey_can_access_question_image(name, false, false)
);

create policy survey_question_images_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'survey-question-images'
  and public.survey_can_access_question_image(name, true, false)
);

create policy survey_question_images_update
on storage.objects for update to authenticated
using (
  bucket_id = 'survey-question-images'
  and public.survey_can_access_question_image(name, true, false)
)
with check (
  bucket_id = 'survey-question-images'
  and public.survey_can_access_question_image(name, true, false)
);

create policy survey_question_images_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'survey-question-images'
  and public.survey_can_access_question_image(name, true, true)
);
