import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import type { AccessIssue, Profile } from '../types/auth'
import { loadProfile } from '../lib/auth'
import { getSupabase, supabaseConfigured } from '../lib/supabase'

interface AuthValue {
  session: Session | null
  profile: Profile | null
  issue: AccessIssue
  loading: boolean
  signOut: () => Promise<void>
}
const AuthContext = createContext<AuthValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [issue, setIssue] = useState<AccessIssue>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    const supabase = getSupabase()
    if (!supabase) { setLoading(false); return }
    const applySession = async (next: Session | null) => {
      setSession(next)
      setProfile(null)
      setIssue(null)
      if (next?.user) {
        const result = await loadProfile(next.user)
        setProfile(result.profile)
        setIssue(result.issue)
      }
      setLoading(false)
    }
    void supabase.auth.getSession().then(({ data }) => applySession(data.session))
    const { data } = supabase.auth.onAuthStateChange((_event, next) => { void applySession(next) })
    return () => data.subscription.unsubscribe()
  }, [])

  const value = useMemo(() => ({
    session, profile, issue, loading: loading && supabaseConfigured,
    signOut: async () => { await getSupabase()?.auth.signOut() },
  }), [session, profile, issue, loading])
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const value = useContext(AuthContext)
  if (!value) throw new Error('AuthProvider 안에서 useAuth를 사용해야 합니다.')
  return value
}
