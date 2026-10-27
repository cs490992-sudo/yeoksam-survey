import { getSupabase } from './supabase'
import type { RecordAnswer, RecordQuestion, RecordSubmission, SharedClient, SurveyRecordData, SurveyRoundSummary } from '../types/survey'

const db=()=>{const client=getSupabase();if(!client)throw new Error('Supabase 연결 설정을 확인해 주세요.');return client}

/** Loads one organization-owned project, then batches all records used by every tab. RLS remains the final boundary. */
export async function loadSurveyRecords(projectId:string,organizationId:string):Promise<SurveyRecordData>{
  const client=db()
  const {data:project,error}=await client.from('survey_projects').select('id,title,description,survey_type,status,program_id,template_key,starts_at,ends_at,created_at').eq('id',projectId).eq('organization_id',organizationId).single()
  if(error||!project)throw new Error('조사를 찾을 수 없거나 기록에 접근할 권한이 없습니다.')
  const [roundResult,participantResult,questionResult]=await Promise.all([
    client.from('survey_rounds').select('id,round_type,status,starts_at,ends_at').eq('survey_project_id',projectId).order('starts_at'),
    client.from('survey_participants').select('client_id').eq('survey_project_id',projectId),
    client.from('survey_questions').select('id,domain,question_text,response_type,sort_order,is_required,image_path,survey_question_options(id,label,numeric_value,sort_order)').eq('survey_project_id',projectId).order('sort_order'),
  ])
  if(roundResult.error||participantResult.error||questionResult.error)throw new Error('조사 기록 구조를 불러오지 못했습니다.')
  const rounds=(roundResult.data??[]) as Omit<SurveyRoundSummary,'completed_count'|'draft_count'>[]
  const roundIds=rounds.map(r=>r.id);const clientIds=(participantResult.data??[]).map(p=>p.client_id)
  const [submissionResult,clientResult,programResult]=await Promise.all([
    roundIds.length?client.from('survey_submissions').select('id,survey_round_id,client_id,status,submitted_at,last_edited_at').in('survey_round_id',roundIds):Promise.resolve({data:[],error:null}),
    clientIds.length?client.from('clients').select('id,name,photo_path,is_active').eq('organization_id',organizationId).in('id',clientIds).order('name'):Promise.resolve({data:[],error:null}),
    project.program_id?client.from('programs').select('name').eq('id',project.program_id).eq('organization_id',organizationId).maybeSingle():Promise.resolve({data:null,error:null}),
  ])
  if(submissionResult.error||clientResult.error||programResult.error)throw new Error('조사 제출 기록을 불러오지 못했습니다.')
  const submissions=(submissionResult.data??[]) as RecordSubmission[];const submissionIds=submissions.map(s=>s.id)
  const answerResult=submissionIds.length?await client.from('survey_answers').select('id,survey_submission_id,survey_question_id,numeric_value,text_value,staff_note').in('survey_submission_id',submissionIds):{data:[],error:null}
  if(answerResult.error)throw new Error('실제 응답을 불러오지 못했습니다.')
  const rawAnswers=(answerResult.data??[]) as Omit<RecordAnswer,'option_ids'>[];const answerIds=rawAnswers.map(a=>a.id)
  const selectedResult=answerIds.length?await client.from('survey_answer_options').select('survey_answer_id,survey_question_option_id').in('survey_answer_id',answerIds):{data:[],error:null}
  if(selectedResult.error)throw new Error('선택 응답을 불러오지 못했습니다.')
  const selected=new Map<string,string[]>();for(const row of selectedResult.data??[])selected.set(row.survey_answer_id,[...(selected.get(row.survey_answer_id)??[]),row.survey_question_option_id])
  const counts=new Map<string,{completed:number;draft:number}>();for(const s of submissions){const c=counts.get(s.survey_round_id)??{completed:0,draft:0};s.status==='submitted'?c.completed++:c.draft++;counts.set(s.survey_round_id,c)}
  const fullRounds=rounds.map(r=>({...r,completed_count:counts.get(r.id)?.completed??0,draft_count:counts.get(r.id)?.draft??0})) as SurveyRoundSummary[]
  const questions=(questionResult.data??[]).map(q=>({...q,image_url:null,options:[...q.survey_question_options].sort((a,b)=>a.sort_order-b.sort_order)})) as RecordQuestion[]
  return {project:{...project,program_name:programResult.data?.name??null,participant_count:clientIds.length,question_count:questions.length,rounds:fullRounds},rounds:fullRounds,participants:(clientResult.data??[]) as SharedClient[],submissions,questions,answers:rawAnswers.map(a=>({...a,option_ids:selected.get(a.id)??[]}))}
}
