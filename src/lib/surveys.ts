import { getSupabase } from './supabase'
import type { LoadedSurvey, SharedClient, SharedProgram, SurveyDraft, SurveyListItem, SurveyStatus } from '../types/survey'

const friendlyError = '조사 정보를 저장하지 못했습니다. 잠시 후 다시 시도해 주세요.'
const db = () => { const client = getSupabase(); if (!client) throw new Error('Supabase 연결 설정을 확인해 주세요.'); return client }

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

export async function saveSurvey(draft: SurveyDraft, organizationId: string, start: boolean, existingId?: string) {
  const client = db(); const now = new Date().toISOString(); let projectId = existingId; let created = false
  try {
    const project = { organization_id: organizationId, program_id: draft.program_id || null, title: draft.title.trim(), description: draft.description.trim() || null, survey_type: draft.survey_type, template_key: draft.template_key, status: start ? 'open' : 'draft', starts_at: start ? now : null }
    if (existingId) {
      const { error } = await client.from('survey_projects').update(project).eq('id', existingId).eq('organization_id', organizationId).eq('status', 'draft'); if (error) throw error
      for (const table of ['survey_participants', 'survey_question_options', 'survey_questions', 'survey_rounds']) { if (table === 'survey_question_options') continue; const { error: deleteError } = await client.from(table).delete().eq('survey_project_id', existingId); if (deleteError) throw deleteError }
    } else {
      const { data, error } = await client.from('survey_projects').insert(project).select('id').single(); if (error || !data) throw error; projectId = data.id; created = true
    }
    const rounds = draft.survey_type === 'single' ? [{ survey_project_id: projectId, round_type: 'single', status: start ? 'open' : 'pending', starts_at: start ? now : null }] : [{ survey_project_id: projectId, round_type: 'pre', status: start ? 'open' : 'pending', starts_at: start ? now : null }, { survey_project_id: projectId, round_type: 'post', status: 'pending' }]
    if ((await client.from('survey_rounds').insert(rounds)).error) throw new Error()
    for (let index = 0; index < draft.questions.length; index++) {
      const q = draft.questions[index]; const { data: saved, error } = await client.from('survey_questions').insert({ survey_project_id: projectId, domain: q.domain.trim() || null, question_text: q.question_text.trim(), response_type: q.response_type, sort_order: index + 1, is_required: q.is_required }).select('id').single(); if (error || !saved) throw error
      if (q.response_type === 'single_choice' || q.response_type === 'multiple_choice') { const options = q.options.map((o, i) => ({ survey_question_id: saved.id, label: o.label.trim(), numeric_value: o.numeric_value ?? null, sort_order: i + 1 })); if ((await client.from('survey_question_options').insert(options)).error) throw new Error() }
    }
    if ((await client.from('survey_participants').insert(draft.participant_ids.map((client_id) => ({ survey_project_id: projectId, client_id })))).error) throw new Error()
    return projectId!
  } catch {
    if (created && projectId) await client.from('survey_projects').delete().eq('id', projectId).eq('organization_id', organizationId)
    throw new Error(friendlyError)
  }
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
