import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import { EmptyState, ErrorState, LoadingState, PageHeader } from '../components/ui'
import { useAuth } from '../context/AuthContext'
import { getSupabase } from '../lib/supabase'

type Project = {
  id: string
  title: string
  survey_type: 'single' | 'pre_post'
  program_id: string | null
  status: 'draft' | 'open' | 'closed' | 'archived'
  created_at: string
}

type Round = {
  id: string
  survey_project_id: string
  round_type: 'single' | 'pre' | 'post'
  status: 'pending' | 'open' | 'closed'
  starts_at: string | null
  ends_at: string | null
}

type Client = { id: string; name: string }
type Submission = { id: string; client_id: string; submitted_at: string | null }
type Option = { id: string; survey_question_id: string; label: string; numeric_value: number | null; sort_order: number }
type Question = { id: string; question_text: string; response_type: string; sort_order: number }
type Answer = { id: string; survey_submission_id: string; survey_question_id: string; numeric_value: number | null; text_value: string | null; staff_note: string | null }
type AnswerOption = { survey_answer_id: string; survey_question_option_id: string }
type PrintChoice = { key: string; label: string; selected: boolean; marker?: string }

type PersonReport = {
  submission: Submission
  client: Client
  answers: Map<string, Answer>
}

const roundLabels = { single: '단회조사', pre: '사전조사', post: '사후조사' } as const
const fiveLabels = ['매우 어려워요', '어려워요', '보통이에요', '좋아요', '매우 좋아요']
const threeLabels = ['싫어요', '몰라요', '좋아요']
const threeMarkers = ['✕', '?', '○']
const centerLogoUrl = 'https://yeoksam-attendance1.vercel.app/branding/yeoksam-center-logo.png'

function numericLabel(question: Question, value: number | null) {
  if (value === null || value === undefined) return '무응답'
  if (question.response_type === 'face_3' || question.response_type === 'scale_3') {
    const index = Math.round(Number(value)) - 1
    return threeLabels[index] ? `${threeLabels[index]} (${value}점)` : `${value}점`
  }
  if (question.response_type === 'face_5' || question.response_type === 'scale_5') {
    const index = Math.round(Number(value)) - 1
    return fiveLabels[index] ? `${fiveLabels[index]} (${value}점)` : `${value}점`
  }
  return String(value)
}

export function PrintReportPage() {
  const { surveyId: routeSurveyId } = useParams()
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const { profile } = useAuth()
  const requestedRoundId = params.get('roundId') ?? ''
  const requestedClientId = params.get('clientId') ?? ''

  const [projects, setProjects] = useState<Project[]>([])
  const [project, setProject] = useState<Project | null>(null)
  const [rounds, setRounds] = useState<Round[]>([])
  const [round, setRound] = useState<Round | null>(null)
  const [programName, setProgramName] = useState<string | null>(null)
  const [questions, setQuestions] = useState<Question[]>([])
  const [options, setOptions] = useState<Option[]>([])
  const [answerOptions, setAnswerOptions] = useState<AnswerOption[]>([])
  const [reports, setReports] = useState<PersonReport[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!profile) return
    let active = true
    const load = async () => {
      setLoading(true)
      setError('')
      const db = getSupabase()
      if (!db) { setError('Supabase 연결 설정을 확인해 주세요.'); setLoading(false); return }
      try {
        const projectQuery = await db.from('survey_projects')
          .select('id,title,survey_type,program_id,status,created_at')
          .eq('organization_id', profile.organization_id)
          .neq('status', 'draft')
          .order('created_at', { ascending: false })
        if (projectQuery.error) throw new Error('조사 목록을 불러오지 못했습니다.')
        const projectRows = (projectQuery.data ?? []) as Project[]
        if (!active) return
        setProjects(projectRows)

        const selectedProject = routeSurveyId ? projectRows.find(item => item.id === routeSurveyId) ?? null : null
        setProject(selectedProject)
        if (!routeSurveyId) { setRounds([]); setRound(null); setReports([]); setLoading(false); return }
        if (!selectedProject) throw new Error('조사를 찾을 수 없거나 인쇄 권한이 없습니다.')

        let nextProgramName: string | null = null
        if (selectedProject.program_id) {
          const programQuery = await db.from('programs').select('name').eq('id', selectedProject.program_id).eq('organization_id', profile.organization_id).maybeSingle()
          if (programQuery.error) throw new Error('프로그램 정보를 불러오지 못했습니다.')
          nextProgramName = programQuery.data?.name ?? null
        }
        if (!active) return
        setProgramName(nextProgramName)

        const roundQuery = await db.from('survey_rounds')
          .select('id,survey_project_id,round_type,status,starts_at,ends_at')
          .eq('survey_project_id', selectedProject.id)
          .neq('status', 'pending')
          .order('starts_at', { ascending: true })
        if (roundQuery.error) throw new Error('조사 회차를 불러오지 못했습니다.')
        const roundRows = (roundQuery.data ?? []) as Round[]
        if (!active) return
        setRounds(roundRows)
        const selectedRound = requestedRoundId
          ? roundRows.find(item => item.id === requestedRoundId) ?? null
          : roundRows.find(item => item.round_type === 'pre' && item.status === 'closed')
            ?? roundRows.find(item => item.status === 'closed')
            ?? roundRows[0]
            ?? null
        setRound(selectedRound)
        if (!selectedRound) throw new Error('인쇄할 조사 회차가 없습니다.')
        if (requestedRoundId && selectedRound.id !== requestedRoundId) throw new Error('선택한 회차를 찾을 수 없거나 접근 권한이 없습니다.')

        const [questionQuery, submissionQuery] = await Promise.all([
          db.from('survey_questions').select('id,question_text,response_type,sort_order').eq('survey_project_id', selectedProject.id).order('sort_order'),
          db.from('survey_submissions').select('id,client_id,submitted_at').eq('survey_round_id', selectedRound.id).eq('status', 'submitted').order('submitted_at'),
        ])
        if (questionQuery.error) throw new Error('조사 문항을 불러오지 못했습니다.')
        if (submissionQuery.error) throw new Error('제출 응답을 불러오지 못했습니다.')
        const questionRows = (questionQuery.data ?? []) as Question[]
        let submissionRows = (submissionQuery.data ?? []) as Submission[]
        if (requestedClientId) submissionRows = submissionRows.filter(item => item.client_id === requestedClientId)
        if (requestedClientId && !submissionRows.length) throw new Error('해당 이용인의 제출 완료 응답을 찾을 수 없습니다.')
        if (!active) return
        setQuestions(questionRows)

        if (!submissionRows.length) { setOptions([]); setAnswerOptions([]); setReports([]); setLoading(false); return }
        const clientIds = [...new Set(submissionRows.map(item => item.client_id))]
        const submissionIds = submissionRows.map(item => item.id)
        const questionIds = questionRows.map(item => item.id)
        const [clientQuery, optionQuery, answerQuery] = await Promise.all([
          db.from('clients').select('id,name').eq('organization_id', profile.organization_id).in('id', clientIds),
          questionIds.length ? db.from('survey_question_options').select('id,survey_question_id,label,numeric_value,sort_order').in('survey_question_id', questionIds).order('sort_order') : Promise.resolve({ data: [], error: null }),
          db.from('survey_answers').select('id,survey_submission_id,survey_question_id,numeric_value,text_value,staff_note').in('survey_submission_id', submissionIds),
        ])
        if (clientQuery.error) throw new Error('이용인 정보를 불러오지 못했습니다.')
        if (optionQuery.error) throw new Error('선택지 정보를 불러오지 못했습니다.')
        if (answerQuery.error) throw new Error('응답 내용을 불러오지 못했습니다.')
        const clients = (clientQuery.data ?? []) as Client[]
        const optionRows = (optionQuery.data ?? []) as Option[]
        const answerRows = (answerQuery.data ?? []) as Answer[]
        if (clients.length !== clientIds.length) throw new Error('이용인 정보에 접근할 수 없습니다.')

        const answerIds = answerRows.map(item => item.id)
        const answerOptionQuery = answerIds.length
          ? await db.from('survey_answer_options').select('survey_answer_id,survey_question_option_id').in('survey_answer_id', answerIds)
          : { data: [], error: null }
        if (answerOptionQuery.error) throw new Error('선택 응답을 불러오지 못했습니다.')
        const answerOptionRows = (answerOptionQuery.data ?? []) as AnswerOption[]
        const clientMap = new Map(clients.map(item => [item.id, item]))
        const answerBySubmission = new Map<string, Map<string, Answer>>()
        for (const answer of answerRows) {
          const map = answerBySubmission.get(answer.survey_submission_id) ?? new Map<string, Answer>()
          map.set(answer.survey_question_id, answer)
          answerBySubmission.set(answer.survey_submission_id, map)
        }
        const nextReports = submissionRows
          .map(submission => ({ submission, client: clientMap.get(submission.client_id), answers: answerBySubmission.get(submission.id) ?? new Map<string, Answer>() }))
          .filter((item): item is PersonReport => Boolean(item.client))
          .sort((a, b) => a.client.name.localeCompare(b.client.name, 'ko'))
        if (!active) return
        setOptions(optionRows)
        setAnswerOptions(answerOptionRows)
        setReports(nextReports)
      } catch (err) {
        if (active) setError(err instanceof Error ? err.message : '인쇄 데이터를 불러오지 못했습니다.')
      } finally {
        if (active) setLoading(false)
      }
    }
    void load()
    return () => { active = false }
  }, [profile, routeSurveyId, requestedRoundId, requestedClientId])

  const optionMap = useMemo(() => new Map(options.map(item => [item.id, item])), [options])
  const optionsByQuestion = useMemo(() => {
    const result = new Map<string, Option[]>()
    for (const option of options) {
      result.set(option.survey_question_id, [...(result.get(option.survey_question_id) ?? []), option])
    }
    for (const [questionId, rows] of result) result.set(questionId, [...rows].sort((a, b) => a.sort_order - b.sort_order))
    return result
  }, [options])
  const selectedOptionIdsByAnswer = useMemo(() => {
    const result = new Map<string, string[]>()
    for (const row of answerOptions) result.set(row.survey_answer_id, [...(result.get(row.survey_answer_id) ?? []), row.survey_question_option_id])
    return result
  }, [answerOptions])

  const answerLabel = (question: Question, answer?: Answer) => {
    if (!answer) return '무응답'
    const selectedIds = selectedOptionIdsByAnswer.get(answer.id) ?? []
    const labels = selectedIds.map(id => optionMap.get(id)?.label).filter(Boolean) as string[]
    if (labels.length) return labels.join(', ')
    if (question.response_type === 'staff_note') return answer.text_value?.trim() || '무응답'
    if (answer.text_value?.trim()) return answer.text_value.trim()
    return numericLabel(question, answer.numeric_value)
  }

  const printChoices = (question: Question, answer?: Answer): PrintChoice[] => {
    if (question.response_type === 'face_3' || question.response_type === 'scale_3') {
      const selected = answer?.numeric_value === null || answer?.numeric_value === undefined ? null : Math.round(Number(answer.numeric_value))
      return threeLabels.map((label, index) => ({
        key: `${question.id}-${index + 1}`,
        label: `${label} (${index + 1}점)`,
        marker: threeMarkers[index],
        selected: selected === index + 1,
      }))
    }
    if (question.response_type === 'face_5' || question.response_type === 'scale_5') {
      const selected = answer?.numeric_value === null || answer?.numeric_value === undefined ? null : Math.round(Number(answer.numeric_value))
      return fiveLabels.map((label, index) => ({
        key: `${question.id}-${index + 1}`,
        label: `${label} (${index + 1}점)`,
        marker: String(index + 1),
        selected: selected === index + 1,
      }))
    }
    const questionOptions = optionsByQuestion.get(question.id) ?? []
    if (questionOptions.length && answer) {
      const selectedIds = new Set(selectedOptionIdsByAnswer.get(answer.id) ?? [])
      return questionOptions.map(option => ({
        key: option.id,
        label: option.numeric_value === null || option.numeric_value === undefined ? option.label : `${option.label} (${option.numeric_value}점)`,
        selected: selectedIds.has(option.id),
      }))
    }
    return []
  }

  const chooseProject = (id: string) => { if (id) navigate(`/reports/${id}/print`) }
  const chooseRound = (id: string) => { if (project && id) navigate(`/reports/${project.id}/print?roundId=${encodeURIComponent(id)}`) }
  const chooseClient = (id: string) => {
    if (!project || !round) return
    const suffix = id ? `&clientId=${encodeURIComponent(id)}` : ''
    navigate(`/reports/${project.id}/print?roundId=${encodeURIComponent(round.id)}${suffix}`)
  }

  if (loading) return <LoadingState label="인쇄할 응답을 불러오고 있습니다." />
  if (error) return <><PageHeader title="인쇄 보고서" /><ErrorState message={error} /><Link className="button secondary" to="/surveys/completion">완료 현황으로</Link></>

  if (!routeSurveyId) return <>
    <PageHeader title="인쇄 보고서" description="실제 제출 완료 응답을 선택해 인쇄하거나 PDF로 저장합니다." />
    <section className="panel report-picker"><label>조사 선택<select defaultValue="" onChange={e => chooseProject(e.target.value)}><option value="" disabled>조사를 선택해 주세요</option>{projects.map(item => <option key={item.id} value={item.id}>{item.title}</option>)}</select></label></section>
    <EmptyState title="인쇄할 조사를 선택해 주세요." description="진행 중이거나 종료된 조사의 제출 완료 응답만 인쇄합니다." />
  </>

  return <>
    <style>{`
      .report-toolbar{display:flex;gap:12px;flex-wrap:wrap;align-items:end;margin-bottom:20px}.report-toolbar label{display:grid;gap:6px;min-width:180px}.report-toolbar select{min-height:44px}.print-report{background:#fff;color:#111}.print-person{border:1.5px solid #222;padding:24px;margin:0 auto 28px;max-width:900px;background:#fff;display:flex;flex-direction:column}.print-title{text-align:center;font-size:28px;margin:0 0 18px}.print-meta{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px 20px;border-top:1px solid #333;border-bottom:1px solid #333;padding:12px 0;margin-bottom:18px}.print-question{border:1px solid #333;margin:0 0 12px;break-inside:avoid}.print-question-head{font-weight:800;padding:10px 12px;border-bottom:1px solid #333}.print-answer{padding:12px;font-size:17px}.print-answer strong{display:inline-block;margin-right:8px}.print-choice-grid{display:grid;gap:6px;padding:8px}.print-choice-grid.count-2{grid-template-columns:repeat(2,minmax(0,1fr))}.print-choice-grid.count-3{grid-template-columns:repeat(3,minmax(0,1fr))}.print-choice-grid.count-4{grid-template-columns:repeat(4,minmax(0,1fr))}.print-choice-grid.count-5{grid-template-columns:repeat(5,minmax(0,1fr))}.print-choice{min-height:70px;border:1px solid #777;padding:8px 6px;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;gap:4px;position:relative;background:#fff}.print-choice.selected{border:3px solid #0f766e;padding:6px 4px;background:#e6f7f4;box-shadow:inset 0 0 0 1px #0f766e;-webkit-print-color-adjust:exact;print-color-adjust:exact}.print-choice.selected .print-choice-marker,.print-choice.selected .print-choice-label,.print-choice.selected .print-choice-selected{font-weight:900}.print-choice-marker{font-size:24px;font-weight:900;line-height:1}.print-choice-label{font-size:13px;line-height:1.25}.print-choice-selected{font-size:12px;font-weight:900}.print-staff-note{margin:0 8px 8px;padding:8px;border-top:1px dashed #999;color:#444}.print-footer{margin-top:auto;padding-top:20px;text-align:center}.print-footer img{width:150px;max-width:45%;height:auto;object-fit:contain}.print-empty{text-align:center;padding:40px}.report-picker label{display:grid;gap:8px;max-width:520px}.report-picker select{min-height:46px}
      @media(max-width:640px){.print-person{padding:16px}.print-meta{grid-template-columns:1fr}.print-title{font-size:23px}.print-choice-grid.count-4,.print-choice-grid.count-5{grid-template-columns:repeat(2,minmax(0,1fr))}}
      @page{size:A4 portrait;margin:12mm}
      @media print{.sidebar,.mobile-header,.drawer-overlay,.no-print,.page-header,.report-toolbar{display:none!important}.content-wrap,.content{margin:0!important;padding:0!important;max-width:none!important}.print-report{width:100%}.print-person{border:0;padding:0;margin:0;max-width:none;min-height:273mm;break-after:page;page-break-after:always}.print-person:last-child{break-after:auto;page-break-after:auto}.print-question{break-inside:avoid;page-break-inside:avoid}.print-title{font-size:22pt}.print-answer{font-size:12pt}.print-choice{min-height:54px}.print-choice-label{font-size:10pt}.print-choice-selected{font-size:9pt}.print-footer{padding-top:8mm}}
    `}</style>
    <PageHeader title="인쇄 보고서" description="제출 완료된 실제 응답만 표시합니다." action={<button className="button primary no-print" onClick={() => window.print()} disabled={!reports.length}>인쇄하기 / PDF 저장</button>} />
    <section className="panel report-toolbar no-print">
      <label>조사<select value={project?.id ?? ''} onChange={e => chooseProject(e.target.value)}>{projects.map(item => <option key={item.id} value={item.id}>{item.title}</option>)}</select></label>
      <label>회차<select value={round?.id ?? ''} onChange={e => chooseRound(e.target.value)}>{rounds.map(item => <option key={item.id} value={item.id}>{roundLabels[item.round_type]} · {item.status === 'closed' ? '종료' : '진행 중'}</option>)}</select></label>
      <label>이용인<select value={requestedClientId} onChange={e => chooseClient(e.target.value)}><option value="">제출 완료 이용인 전체</option>{reports.map(item => <option key={item.client.id} value={item.client.id}>{item.client.name}</option>)}</select></label>
      <Link className="button secondary" to={`/surveys/${project?.id}/completion`}>완료 현황으로</Link>
    </section>
    <div className="print-report">
      {reports.length ? reports.map(person => <section className="print-person" key={person.submission.id}>
        <h1 className="print-title">{project?.title} {round ? roundLabels[round.round_type] : ''}</h1>
        <div className="print-meta"><span><strong>기관:</strong> 역삼주간보호센터</span><span><strong>작성자:</strong> {person.client.name}</span><span><strong>프로그램:</strong> {programName ?? '미지정'}</span></div>
        {questions.map(question => {
          const answer = person.answers.get(question.id)
          const choices = printChoices(question, answer)
          return <article className="print-question" key={question.id}>
            <div className="print-question-head">{question.sort_order}. {question.question_text}</div>
            {choices.length ? <div className={`print-choice-grid count-${Math.min(5, choices.length)}`}>{choices.map(choice => <div className={`print-choice ${choice.selected ? 'selected' : ''}`} key={choice.key}>{choice.marker && <span className="print-choice-marker" aria-hidden="true">{choice.marker}</span>}<span className="print-choice-label">{choice.label}</span>{choice.selected && <span className="print-choice-selected">✓ 선택</span>}</div>)}</div> : <div className="print-answer"><strong>응답:</strong>{answerLabel(question, answer)}</div>}
            {answer?.staff_note?.trim() && <div className="print-staff-note"><strong>담당자 메모:</strong> {answer.staff_note.trim()}</div>}
          </article>
        })}
        <footer className="print-footer"><img src={centerLogoUrl} alt="역삼주간보호센터 로고" /></footer>
      </section>) : <div className="print-empty"><h2>인쇄할 제출 완료 응답이 없습니다.</h2><p>선택한 회차의 제출 상태를 확인해 주세요.</p></div>}
    </div>
  </>
}
