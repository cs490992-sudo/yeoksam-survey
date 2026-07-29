export type SurveyType = 'single' | 'pre_post'
export type SurveyStatus = 'draft' | 'open' | 'closed' | 'archived'
export type ResponseType = 'face_3' | 'face_5' | 'scale_3' | 'scale_5' | 'yes_no' | 'single_choice' | 'multiple_choice' | 'staff_note'

export interface SharedClient { id: string; name: string; photo_path: string | null; is_active: boolean }
export interface SharedProgram { id: string; name: string; is_active: boolean }
export interface QuestionOptionDraft { id: string; label: string; numeric_value?: number | null }
export interface QuestionDraft { id: string; domain: string; question_text: string; response_type: ResponseType; is_required: boolean; options: QuestionOptionDraft[] }
export interface SurveyDraft { title: string; description: string; survey_type: SurveyType; program_id: string; template_key: string | null; participant_ids: string[]; questions: QuestionDraft[] }
export interface SurveyTemplate { key: string; name: string; description: string; survey_type: SurveyType; title: string; questions: Omit<QuestionDraft, 'id'>[] }
export interface SurveyListItem { id: string; title: string; description: string | null; survey_type: SurveyType; status: SurveyStatus; program_id: string | null; template_key: string | null; starts_at: string | null; created_at: string; participant_count: number; question_count: number; program_name: string | null }
export interface LoadedSurvey { project: SurveyListItem; draft: SurveyDraft }
