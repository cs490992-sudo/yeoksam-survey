import { getSupabase } from './supabase'
import type { CompletionRound, LoadedSurvey, RunParticipant, RunQuestion, RunSurvey, SavedAnswer, SharedClient, SharedProgram, SubmissionDetails, SubmissionRevision, SurveyDraft, SurveyListItem, SurveyStatus } from '../types/survey'

const friendlyError = '조사 정보를 저장하지 못했습니다. 잠시 후 다시 시도해 주세요.'
const db = () => { const client = getSupabase(); if (!client) throw new Error('Supabase 연결 설정을 확인해 주세요.'); return client }
type SaveStage = 'create-project' | 'save-rounds' | 'save-questions' | 'save-options' | 'save-participants' | 'open-project' | 'open-round'

function logSaveFailure(stage: SaveStage) {
  console.error(`[survey-save] failed at ${stage}`)
}

export async function loadSharedData(organizationId: string) {
  const client = db()
  const [clients, programs] = await Promise.all([
    client.from('clients').select('id,name,photo_path,is_active').eq('organization_id', organizationId).eq('is_active', true).order('name'),
    client.from('programs').select('id,name,is_active').eq('organization_id', organizationId).eq('is_active', true).order('name'),
  ])
  return { clients: (clients.data ?? []) as SharedClient[], programs: (programs.data ?? []) as SharedProgram[], clientsError: Boolean(clients.error), programsError: Boolean(programs.error) }
}

export async function listSurveys(organizationId: string): Promise<SurveyListItem[]> {
  const { data, error } = await db().from('survey_projects').select('id,title,description,survey_type,status,program_id,template_key,starts_at,ends_at,created_at,survey_participants(count),survey_questions(count),survey_rounds(id,round_type,status,starts_at,ends_at)').eq('organization_id', organizationId).order('created_at', { ascending: false })
  if (error) throw new Error('조사 목록을 불러오지 못했습니다.')
  const rows = data ?? []
  const programIds = [...new Set(rows.map((row) => row.program_id).filter(Boolean))] as string[]
  const programs = programIds.length ? await db().from('programs').select('id,name').in('id', programIds).eq('organization_id', organizationId) : { data: [] }
  const names = new Map((programs.data ?? []).map((p) => [p.id, p.name]))
  const roundIds=rows.flatMap(row=>row.survey_rounds.map(round=>round.id))
  const submissions=roundIds.length?await db().from('survey_submissions').select('survey_round_id,status').in('survey_round_id',roundIds):{data:[],error:null}
  if(submissions.error)throw new Error('조사 완료 현황을 불러오지 못했습니다.')
  const counts=new Map<string,{completed:number;draft:number}>()
  for(const submission of submissions.data??[]){const count=counts.get(submission.survey_round_id)??{completed:0,draft:0};submission.status==='submitted'?count.completed++:count.draft++;counts.set(submission.survey_round_id,count)}
  return rows.map((row) => ({ ...row, participant_count: row.survey_participants?.[0]?.count ?? 0, question_count: row.survey_questions?.[0]?.count ?? 0, program_name: row.program_id ? names.get(row.program_id) ?? null : null,rounds:row.survey_rounds.map(round=>({...round,completed_count:counts.get(round.id)?.completed??0,draft_count:counts.get(round.id)?.draft??0})) })) as SurveyListItem[]
}

async function saveDraftStructure(draft: SurveyDraft, organizationId: string, existingId?: string) {
  const client = db()
  let projectId = existingId
  let created = false
  let stage: SaveStage = 'create-project'

  try {
    const project = {
      organization_id: organizationId,
      program_id: draft.program_id || null,
      title: draft.title.trim(),
      description: draft.description.trim() || null,
      survey_type: draft.survey_type,
      template_key: draft.template_key,
      status: 'draft' as const,
      starts_at: null,
    }

    if (existingId) {
      const { data, error } = await client.from('survey_projects').update(project).eq('id', existingId).eq('organization_id', organizationId).eq('status', 'draft').select('id').single()
      if (error || !data) throw error ?? new Error('Draft project was not updated')

      for (const table of ['survey_participants', 'survey_questions', 'survey_rounds'] as const) {
        const { error: deleteError } = await client.from(table).delete().eq('survey_project_id', existingId)
        if (deleteError) throw deleteError
      }
    } else {
      const { data, error } = await client.from('survey_projects').insert(project).select('id').single()
      if (error || !data) throw error ?? new Error('Draft project was not created')
      projectId = data.id
      created = true
    }
    if (!projectId) throw new Error('Draft project id was not available')

    stage = 'save-rounds'
    const rounds = draft.survey_type === 'single'
      ? [{ survey_project_id: projectId, round_type: 'single', status: 'pending' }]
      : [
          { survey_project_id: projectId, round_type: 'pre', status: 'pending' },
          { survey_project_id: projectId, round_type: 'post', status: 'pending' },
        ]
    const { error: roundsError } = await client.from('survey_rounds').insert(rounds)
    if (roundsError) throw roundsError

    stage = 'save-questions'
    const questionRows = draft.questions.map((question, index) => ({
      survey_project_id: projectId,
      domain: question.domain.trim() || null,
      question_text: question.question_text.trim(),
      response_type: question.response_type,
      sort_order: index + 1,
      is_required: question.is_required,
    }))
    const { data: savedQuestions, error: questionsError } = await client.from('survey_questions').insert(questionRows).select('id,sort_order')
    if (questionsError || !savedQuestions || savedQuestions.length !== questionRows.length) throw questionsError ?? new Error('Questions were not saved')

    stage = 'save-options'
    const questionIds = new Map(savedQuestions.map((question) => [question.sort_order, question.id]))
    const optionRows = draft.questions.flatMap((question, questionIndex) => {
      if (question.response_type !== 'single_choice' && question.response_type !== 'multiple_choice' && question.response_type !== 'yes_no') return []
      const questionId = questionIds.get(questionIndex + 1)
      if (!questionId) throw new Error('Saved question was not found')
      const options = question.response_type === 'yes_no'
        ? [{ label:'예', numeric_value:1 }, { label:'아니요', numeric_value:0 }]
        : question.options
      return options.map((option, optionIndex) => ({
        survey_question_id: questionId,
        label: option.label.trim(),
        numeric_value: option.numeric_value ?? null,
        sort_order: optionIndex + 1,
      }))
    })
    if (optionRows.length) {
      const { error: optionsError } = await client.from('survey_question_options').insert(optionRows)
      if (optionsError) throw optionsError
    }

    stage = 'save-participants'
    const participants = draft.participant_ids.map((client_id) => ({ survey_project_id: projectId, client_id }))
    if (participants.length) {
      const { error: participantsError } = await client.from('survey_participants').insert(participants)
      if (participantsError) throw participantsError
    }

    return { projectId, created }
  } catch {
    logSaveFailure(stage)
    if (created && projectId) {
      const { error: cleanupError } = await client.from('survey_projects').delete().eq('id', projectId).eq('organization_id', organizationId).eq('status', 'draft')
      if (cleanupError) console.error('[survey-save] failed to clean up new draft project')
    }
    throw new Error(friendlyError)
  }
}

async function openSavedSurvey(projectId: string, organizationId: string, draft: SurveyDraft) {
  const client = db()
  const now = new Date().toISOString()
  let stage: SaveStage = 'open-project'

  try {
    const { data, error } = await client.from('survey_projects').update({ status: 'open', starts_at: now }).eq('id', projectId).eq('organization_id', organizationId).eq('status', 'draft').select('id').single()
    if (error || !data) throw error ?? new Error('Project was not opened')

    stage = 'open-round'
    const roundType = draft.survey_type === 'single' ? 'single' : 'pre'
    const { data: round, error: roundError } = await client.from('survey_rounds').update({ status: 'open', starts_at: now }).eq('survey_project_id', projectId).eq('round_type', roundType).eq('status', 'pending').select('id').single()
    if (roundError || !round) throw roundError ?? new Error('Round was not opened')
  } catch {
    logSaveFailure(stage)
    throw new Error(friendlyError)
  }
}

export async function saveSurvey(draft: SurveyDraft, organizationId: string, start: boolean, existingId?: string) {
  const client = db()
  const { projectId, created } = await saveDraftStructure(draft, organizationId, existingId)
  if (start) {
    try {
      await openSavedSurvey(projectId, organizationId, draft)
    } catch (error) {
      if (created) {
        const { error: cleanupError } = await client.from('survey_projects').delete().eq('id', projectId).eq('organization_id', organizationId).eq('status', 'draft')
        if (cleanupError) console.error('[survey-save] failed to clean up new draft project')
      }
      throw error
    }
  }
  return projectId
}

export async function loadSurvey(id: string, organizationId: string): Promise<LoadedSurvey> {
  const { data, error } = await db().from('survey_projects').select('id,title,description,survey_type,status,program_id,template_key,starts_at,created_at,survey_participants(client_id),survey_questions(id,domain,question_text,response_type,is_required,sort_order,survey_question_options(id,label,numeric_value,sort_order))').eq('id', id).eq('organization_id', organizationId).single()
  if (error || !data) throw new Error('조사를 찾을 수 없거나 접근 권한이 없습니다.')
  const questions = [...data.survey_questions].sort((a,b) => a.sort_order-b.sort_order).map((q) => ({ id:q.id, domain:q.domain ?? '', question_text:q.question_text, response_type:q.response_type, is_required:q.is_required, options:[...q.survey_question_options].sort((a,b)=>a.sort_order-b.sort_order).map(o=>({id:o.id,label:o.label,numeric_value:o.numeric_value})) }))
  return { project: { ...data, ends_at:null,participant_count:data.survey_participants.length, question_count:questions.length, program_name:null,rounds:[] } as SurveyListItem, draft: { title:data.title, description:data.description ?? '', survey_type:data.survey_type, program_id:data.program_id ?? '', template_key:data.template_key, participant_ids:data.survey_participants.map(p=>p.client_id), questions } }
}

export async function changeSurveyStatus(id: string, organizationId: string, from: SurveyStatus, to: SurveyStatus) {
  const allowed = `${from}:${to}`; if (!['draft:open','open:closed','closed:archived','archived:closed'].includes(allowed)) throw new Error('허용되지 않은 상태 변경입니다.')
  const now = new Date().toISOString(); const patch: Record<string,string|null> = { status:to }; if (to==='open') patch.starts_at=now; if(to==='closed') patch.ends_at=now
  const { error } = await db().from('survey_projects').update(patch).eq('id',id).eq('organization_id',organizationId).eq('status',from); if(error) throw new Error('조사 상태를 변경하지 못했습니다.')
}
export async function deleteSurvey(id:string, organizationId:string) { const {error}=await db().from('survey_projects').delete().eq('id',id).eq('organization_id',organizationId); if(error) throw new Error('조사를 삭제하지 못했습니다.') }

const runFailure = (stage: string, message: string) => { console.error(`[survey-run] failed at ${stage}`); throw new Error(message) }

export async function listRunnableSurveys(organizationId: string): Promise<RunSurvey[]> {
  const { data, error } = await db().from('survey_projects').select('id,title,survey_type,status,program_id,starts_at,survey_rounds(id,round_type,status,starts_at,ends_at),survey_participants(count)').eq('organization_id', organizationId).in('status', ['open','closed','archived']).order('starts_at', { ascending: false })
  if (error) return runFailure('load-surveys', '진행 중인 조사 목록을 불러오지 못했습니다.')
  const rows = data ?? []; const programIds = rows.flatMap(r => r.program_id ? [r.program_id] : [])
  const [{ data: programs }, { data: submissions, error: submissionError }] = await Promise.all([
    programIds.length ? db().from('programs').select('id,name').eq('organization_id', organizationId).in('id', programIds) : Promise.resolve({ data: [] }),
    db().from('survey_submissions').select('survey_round_id,status').eq('status', 'submitted'),
  ])
  if (submissionError) return runFailure('load-surveys', '완료 현황을 불러오지 못했습니다.')
  const names = new Map((programs ?? []).map(p => [p.id, p.name])); const completed = new Map<string, number>()
  for (const s of submissions ?? []) completed.set(s.survey_round_id, (completed.get(s.survey_round_id) ?? 0) + 1)
  return rows.filter(r => r.survey_rounds.some(round => round.status === 'open' || round.status === 'closed')).map(r => {
    const active = r.survey_rounds.find(round => round.status === 'open') ?? r.survey_rounds.find(round => round.status === 'closed')
    return { id:r.id,title:r.title,survey_type:r.survey_type,status:r.status,program_name:r.program_id?names.get(r.program_id)??null:null,starts_at:r.starts_at,participant_count:r.survey_participants[0]?.count??0,completed_count:active?completed.get(active.id)??0:0,rounds:r.survey_rounds }
  }) as RunSurvey[]
}

export async function loadRunParticipants(projectId: string, roundId: string, organizationId: string): Promise<RunParticipant[]> {
  const [{ data: links, error }, { data: submissions, error: submissionError }] = await Promise.all([
    db().from('survey_participants').select('client_id').eq('survey_project_id', projectId),
    db().from('survey_submissions').select('id,client_id,status').eq('survey_round_id', roundId),
  ])
  if (error || submissionError) return runFailure('load-participants', '참여 이용인을 불러오지 못했습니다.')
  const ids = (links ?? []).map(x => x.client_id); if (!ids.length) return []
  const { data: clients, error: clientError } = await db().from('clients').select('id,name,photo_path,is_active').eq('organization_id', organizationId).in('id', ids).order('name')
  if (clientError) return runFailure('load-participants', '참여 이용인을 불러오지 못했습니다.')
  const states = new Map((submissions ?? []).map(s => [s.client_id, s]))
  return (clients ?? []).map(c => ({ ...c, submission_id:states.get(c.id)?.id??null, submission_status:states.get(c.id)?.status??null })) as RunParticipant[]
}

export async function startRun(roundId: string, clientId: string) {
  const { data, error } = await db().rpc('start_or_resume_survey_submission', { p_survey_round_id:roundId, p_client_id:clientId })
  if (error || !data?.[0]) return runFailure('start-submission', '조사를 시작하지 못했습니다.')
  return data[0] as { submission_id:string; submission_status:'draft'|'submitted'; round_type:'single'|'pre'|'post'; already_completed:boolean }
}

export async function loadRunQuestions(projectId: string): Promise<RunQuestion[]> {
  const { data, error } = await db().from('survey_questions').select('id,domain,question_text,response_type,sort_order,is_required,survey_question_options(id,label,numeric_value,sort_order)').eq('survey_project_id', projectId).order('sort_order')
  if (error) return runFailure('load-questions', '문항을 불러오지 못했습니다.')
  return (data ?? []).map(q => ({ ...q, options:[...q.survey_question_options].sort((a,b)=>a.sort_order-b.sort_order) })) as RunQuestion[]
}

export async function loadSavedAnswers(submissionId: string): Promise<SavedAnswer[]> {
  const { data, error } = await db().from('survey_answers').select('survey_question_id,numeric_value,text_value,staff_note,survey_answer_options(survey_question_option_id)').eq('survey_submission_id', submissionId)
  if (error) return runFailure('load-saved-answers', '저장된 응답을 불러오지 못했습니다.')
  return (data ?? []).map(a => ({ question_id:a.survey_question_id,numeric_value:a.numeric_value,text_value:a.staff_note??a.text_value,option_ids:a.survey_answer_options.map(o=>o.survey_question_option_id) }))
}

export async function saveRunAnswer(submissionId:string, answer:SavedAnswer) {
  const { error } = await db().rpc('save_survey_answer', { p_submission_id:submissionId,p_question_id:answer.question_id,p_numeric_value:answer.numeric_value,p_text_value:answer.text_value,p_option_ids:answer.option_ids })
  if (error) return runFailure('save-answer', '응답을 저장하지 못했습니다. 연결을 확인하고 다시 시도해 주세요.')
}
export async function submitRun(submissionId:string) {
  const { data,error }=await db().rpc('submit_survey_submission',{p_submission_id:submissionId}); if(error||!data?.[0])return runFailure('submit-submission','필수 응답을 확인하거나 잠시 후 다시 시도해 주세요.'); return data[0]
}

export async function loadSubmissionDetails(submissionId:string):Promise<SubmissionDetails>{
  const {data,error}=await db().from('survey_submissions').select('id,status,submitted_at,submitted_by,last_edited_at,last_edited_by,edit_count').eq('id',submissionId).eq('status','submitted').single()
  if(error||!data)return runFailure('load-submission','완료 응답 정보를 불러오지 못했습니다.')
  return {...data,submitted_by_name:null,last_edited_by_name:null} as SubmissionDetails
}

export async function loadSubmissionRevisions(submissionId:string):Promise<SubmissionRevision[]>{
  const {data,error}=await db().from('survey_submission_revisions').select('id,edited_at,edited_by,edit_reason,revision_number,previous_answers').eq('survey_submission_id',submissionId).order('revision_number',{ascending:false})
  if(error)return runFailure('load-revisions','수정 이력을 불러오지 못했습니다.')
  return (data??[]).map(r=>({...r,edited_by_name:null,previous_answers:(r.previous_answers as (SavedAnswer&{staff_note?:string|null})[]).map(a=>({...a,text_value:a.staff_note??a.text_value,option_ids:a.option_ids??[]}))})) as SubmissionRevision[]
}

export async function reviseSubmission(submissionId:string,answers:SavedAnswer[],reason:string){
  const payload=answers.filter(answer=>{
    const hasNumeric=answer.numeric_value!==null&&answer.numeric_value!==undefined
    const hasText=typeof answer.text_value==='string'&&answer.text_value.trim().length>0
    const hasOptions=Array.isArray(answer.option_ids)&&answer.option_ids.length>0
    return hasNumeric||hasText||hasOptions
  }).map(answer=>({
    question_id:answer.question_id,
    numeric_value:answer.numeric_value??null,
    text_value:typeof answer.text_value==='string'&&answer.text_value.trim().length>0?answer.text_value.trim():null,
    option_ids:Array.isArray(answer.option_ids)?answer.option_ids:[],
  }))
  const {data,error}=await db().rpc('revise_survey_submission',{p_submission_id:submissionId,p_answers:payload,p_edit_reason:reason.trim()||null})
  if(error||!data?.[0])return runFailure('revise-submission','완료 응답을 수정하지 못했습니다. 조사 상태와 필수 응답을 확인해 주세요.')
  return data[0]
}

export async function closeSurveyRound(roundId:string){
  const {data,error}=await db().rpc('close_survey_round',{p_survey_round_id:roundId})
  if(error||!data?.[0])return runFailure('close-round',error?.message||'조사 회차를 종료하지 못했습니다.')
  return data[0] as {survey_round_id:string;round_status:'closed';project_status:'open'|'closed';ended_at:string;already_closed:boolean}
}

export async function openPostSurveyRound(projectId:string){
  const {data,error}=await db().rpc('open_post_survey_round',{p_survey_project_id:projectId})
  if(error||!data?.[0])return runFailure('open-post-round',error?.message||'사후 조사를 시작하지 못했습니다.')
  return data[0] as {survey_round_id:string;round_status:'open';project_status:'open';started_at:string}
}

export async function loadCompletionRounds(organizationId:string):Promise<CompletionRound[]>{
  const projects=await listSurveys(organizationId)
  const activeProjects=projects.filter(project=>project.status!=='draft')
  const result:CompletionRound[]=[]
  for(const project of activeProjects){
    const [{data:links,error:linkError},{data:submissions,error:submissionError}]=await Promise.all([
      db().from('survey_participants').select('client_id').eq('survey_project_id',project.id),
      db().from('survey_submissions').select('id,client_id,status,submitted_at,last_edited_at,survey_round_id').in('survey_round_id',project.rounds.map(round=>round.id)),
    ])
    if(linkError||submissionError)throw new Error('이용인별 완료 현황을 불러오지 못했습니다.')
    const clientIds=(links??[]).map(link=>link.client_id)
    const {data:clients,error:clientError}=clientIds.length?await db().from('clients').select('id,name,photo_path,is_active').eq('organization_id',organizationId).in('id',clientIds).order('name'): {data:[],error:null}
    if(clientError)throw new Error('완료 현황 이용인을 불러오지 못했습니다.')
    for(const round of project.rounds){
      const states=new Map((submissions??[]).filter(row=>row.survey_round_id===round.id).map(row=>[row.client_id,row]))
      result.push({project_id:project.id,project_title:project.title,program_id:project.program_id,program_name:project.program_name,survey_type:project.survey_type,project_status:project.status,round,participant_count:project.participant_count,participants:(clients??[]).map(client=>{const state=states.get(client.id);return{...client,submission_id:state?.id??null,submission_status:state?.status??null,submitted_at:state?.submitted_at??null,last_edited_at:state?.last_edited_at??null}})})
    }
  }
  return result
}
