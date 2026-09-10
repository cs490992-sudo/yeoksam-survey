export type SurveyType = 'single' | 'pre_post'
export type SurveyStatus = 'draft' | 'scheduled' | 'open' | 'closed' | 'archived'
export type ResponseType = 'face_3' | 'face_5' | 'scale_3' | 'scale_5' | 'yes_no' | 'single_choice' | 'multiple_choice' | 'staff_note'

export interface SharedClient { id: string; name: string; photo_path: string | null; is_active: boolean }
export interface SharedProgram { id: string; name: string; is_active: boolean }
export interface QuestionOptionDraft { id: string; label: string; numeric_value?: number | null }
export interface QuestionDraft { id: string; domain: string; question_text: string; response_type: ResponseType; is_required: boolean; options: QuestionOptionDraft[] }
export interface SurveyDraft { title: string; description: string; survey_type: SurveyType; program_id: string; template_key: string | null; participant_ids: string[]; questions: QuestionDraft[] }
export interface SurveyTemplate { key: string; name: string; description: string; survey_type: SurveyType; title: string; questions: Omit<QuestionDraft, 'id'>[] }
export interface SurveyRoundSummary { id:string; round_type:SurveyRoundType; status:'pending'|'open'|'closed'; starts_at:string|null; ends_at:string|null; completed_count:number; draft_count:number }
export interface SurveyListItem { id: string; title: string; description: string | null; survey_type: SurveyType; status: SurveyStatus; program_id: string | null; template_key: string | null; starts_at: string | null; ends_at:string|null; created_at: string; participant_count: number; question_count: number; program_name: string | null; rounds:SurveyRoundSummary[] }
export interface LoadedSurvey { project: SurveyListItem; draft: SurveyDraft }

export type SurveyRoundType = 'single' | 'pre' | 'post'
export type SubmissionStatus = 'draft' | 'submitted'
export interface RunRound { id: string; round_type: SurveyRoundType; status: 'pending' | 'open' | 'closed'; starts_at: string | null; ends_at:string|null }
export interface RunSurvey { id: string; title: string; survey_type: SurveyType; status: SurveyStatus; program_name: string | null; starts_at: string | null; participant_count: number; completed_count: number; rounds: RunRound[] }
export interface RunParticipant extends SharedClient { submission_id: string | null; submission_status: SubmissionStatus | null }
export interface RunQuestion { id: string; domain: string | null; question_text: string; response_type: ResponseType; sort_order: number; is_required: boolean; options: { id: string; label: string; numeric_value: number | null }[] }
export interface SavedAnswer { question_id: string; numeric_value: number | null; text_value: string | null; option_ids: string[] }
export interface SubmissionDetails { id:string; status:SubmissionStatus; submitted_at:string|null; submitted_by:string|null; submitted_by_name:string|null; last_edited_at:string|null; last_edited_by:string|null; last_edited_by_name:string|null; edit_count:number }
export interface SubmissionRevision { id:string; edited_at:string; edited_by:string; edited_by_name:string|null; edit_reason:string|null; revision_number:number; previous_answers:SavedAnswer[] }
export interface CompletionParticipant extends SharedClient { submission_id:string|null; submission_status:SubmissionStatus|null; submitted_at:string|null; last_edited_at:string|null }
export interface CompletionRound { project_id:string; project_title:string; program_id:string|null; program_name:string|null; survey_type:SurveyType; project_status:SurveyStatus; round:SurveyRoundSummary; participant_count:number; participants:CompletionParticipant[] }
