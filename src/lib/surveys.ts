import { getSupabase } from './supabase'
import type { LoadedSurvey, SharedClient, SharedProgram, SurveyDraft, SurveyListItem, SurveyStatus } from '../types/survey'

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
  const { data, error } = await db().from('survey_projects').select('id,title,description,survey_type,status,program_id,template_key,starts_at,created_at,survey_participants(count),survey_questions(count)').eq('organization_id', organizationId).order('created_at', { ascending: false })
  if (error) throw new Error('조사 목록을 불러오지 못했습니다.')
  const rows = data ?? []
  const programIds = [...new Set(rows.map((row) => row.program_id).filter(Boolean))] as string[]
  const programs = programIds.length ? await db().from('programs').select('id,name').in('id', programIds).eq('organization_id', organizationId) : { data: [] }
  const names = new Map((programs.data ?? []).map((p) => [p.id, p.name]))
  return rows.map((row) => ({ ...row, participant_count: row.survey_participants?.[0]?.count ?? 0, question_count: row.survey_questions?.[0]?.count ?? 0, program_name: row.program_id ? names.get(row.program_id) ?? null : null })) as SurveyListItem[]
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
      if (question.response_type !== 'single_choice' && question.response_type !== 'multiple_choice') return []
      const questionId = questionIds.get(questionIndex + 1)
      if (!questionId) throw new Error('Saved question was not found')
      return question.options.map((option, optionIndex) => ({
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
  return { project: { ...data, participant_count:data.survey_participants.length, question_count:questions.length, program_name:null } as SurveyListItem, draft: { title:data.title, description:data.description ?? '', survey_type:data.survey_type, program_id:data.program_id ?? '', template_key:data.template_key, participant_ids:data.survey_participants.map(p=>p.client_id), questions } }
}

export async function changeSurveyStatus(id: string, organizationId: string, from: SurveyStatus, to: SurveyStatus) {
  const allowed = `${from}:${to}`; if (!['draft:open','open:closed','closed:archived','archived:closed'].includes(allowed)) throw new Error('허용되지 않은 상태 변경입니다.')
  const now = new Date().toISOString(); const patch: Record<string,string|null> = { status:to }; if (to==='open') patch.starts_at=now; if(to==='closed') patch.ends_at=now
  const { error } = await db().from('survey_projects').update(patch).eq('id',id).eq('organization_id',organizationId).eq('status',from); if(error) throw new Error('조사 상태를 변경하지 못했습니다.')
}
export async function deleteSurvey(id:string, organizationId:string) { const {error}=await db().from('survey_projects').delete().eq('id',id).eq('organization_id',organizationId); if(error) throw new Error('조사를 삭제하지 못했습니다.') }
