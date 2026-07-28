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
  return <main className="login-page">
    <section className="login-intro" aria-labelledby="login-brand-title">
      <div className="login-brand-mark" aria-hidden="true">✓</div>
      <p className="login-organization">역삼주간보호센터</p>
      <h1 id="login-brand-title">역삼 만족도 조사</h1>
      <p className="login-description">더 나은 돌봄과 서비스를 위해 소중한 의견을 모으고, 만족도 조사 결과를 체계적으로 관리합니다.</p>
      <div className="login-intro-accent" aria-hidden="true"><span /><span /><span /></div>
    </section>
    <section className="login-card" aria-labelledby="login-title">
      <div className="login-card-heading">
        <p className="eyebrow">WELCOME BACK</p>
        <h2 id="login-title">로그인</h2>
        <p className="muted">관리자 또는 직원 계정으로 로그인해 주세요.</p>
      </div>
      {!supabaseConfigured && <ErrorState title="연결 설정이 필요합니다." message={configurationMessage} />}
      {error && <ErrorState title="로그인하지 못했습니다." message={error} />}
      <form onSubmit={submit}>
        <label>이메일<input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="이메일을 입력해 주세요" required /></label>
        <label>비밀번호<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="비밀번호를 입력해 주세요" required /></label>
        <button className="button primary full" disabled={!supabaseConfigured || submitting}>{submitting ? '로그인 중…' : '로그인'}</button>
      </form>
    </section>
  </main>
}
