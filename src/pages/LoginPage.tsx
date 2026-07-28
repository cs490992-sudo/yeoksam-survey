import { useState, type FormEvent } from 'react'
import { Navigate, useNavigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { configurationMessage, getSupabase, supabaseConfigured } from '../lib/supabase'
import { ErrorState } from '../components/ui'

export function LoginPage() {
  const { session, loading } = useAuth()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')
  if (!loading && session) return <Navigate to="/" replace />
  async function submit(event: FormEvent) {
    event.preventDefault()
    const supabase = getSupabase()
    if (!supabase) return
    setSubmitting(true); setError('')
    const { error: authError } = await supabase.auth.signInWithPassword({ email, password })
    setSubmitting(false)
    if (authError) setError('로그인 정보를 확인해 주세요.')
    else navigate('/', { replace: true })
  }
  return <main className="login-page"><section className="login-card">
    <div className="login-symbol" aria-hidden="true">✓</div><p className="eyebrow">역삼주간보호센터</p><h1>역삼 만족도 조사</h1><p className="muted">관리자와 직원 계정으로 로그인해 주세요.</p>
    {!supabaseConfigured && <ErrorState title="연결 설정이 필요합니다." message={configurationMessage} />}
    {error && <ErrorState title="로그인하지 못했습니다." message={error} />}
    <form onSubmit={submit}><label>이메일<input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required /></label><label>비밀번호<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label><button className="button primary full" disabled={!supabaseConfigured || submitting}>{submitting ? '로그인 중…' : '로그인'}</button></form>
  </section></main>
}
