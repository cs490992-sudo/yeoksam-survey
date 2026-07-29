# 조사 데이터 모델

실제 정의는 `supabase/migrations/001_survey_core.sql`에 있으며 운영 적용 전 검토합니다.

- `survey_projects` 1 — N `survey_rounds` (단회는 single, 비교조사는 pre/post)
- `survey_projects` 1 — N `survey_questions` 1 — N `survey_question_options`
- `survey_projects` 1 — N `survey_participants`
- `survey_rounds` 1 — N `survey_submissions` 1 — N `survey_answers`
- `survey_answers` N — M `survey_question_options` (`survey_answer_options`)

프로젝트 삭제는 모든 조사 자식에 cascade됩니다. 질문은 회차별로 복제하지 않고 프로젝트에서 공유합니다. 순서와 참여자/제출/답변 중복은 unique 제약으로 방지합니다. updated_at이 있는 다섯 테이블에는 조사 전용 trigger가 적용됩니다.

모든 조사 테이블은 RLS를 사용합니다. 활성 admin/staff만 profiles의 동일 organization_id에 속한 프로젝트와 자식을 조회·관리하며, 프로젝트 영구 삭제는 admin만 가능합니다. 자식 정책은 항상 프로젝트까지 join합니다.

## 공유 데이터 가정

adapter는 `profiles(id, organization_id, role, is_active)`, `clients(id, organization_id, name, photo_path, is_active)`, `programs(id, organization_id, name, is_active)`와 UUID 식별자를 가정합니다. 운영 구조를 확인하지 못했으므로 migration은 clients/programs를 변경하거나 FK를 추가하지 않습니다. 사진 Storage URL 규칙도 가정하지 않아 현재 선택 카드에는 이름 fallback만 표시합니다.
