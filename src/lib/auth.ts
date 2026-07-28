import type { User } from '@supabase/supabase-js'
import type { AccessIssue, AppRole, Profile } from '../types/auth'
import { getSupabase } from './supabase'

const roles: AppRole[] = ['admin', 'staff']

export async function loadProfile(user: User): Promise<{ profile: Profile | null; issue: AccessIssue }> {
  const supabase = getSupabase()
  if (!supabase) return { profile: null, issue: 'profile_error' }
  const { data, error } = await supabase
    .from('profiles')
    .select('id, organization_id, role, is_active')
    .eq('id', user.id)
    .maybeSingle()

  if (error) return { profile: null, issue: 'profile_error' }
  if (!data) return { profile: null, issue: 'profile_missing' }
  if (!data.is_active) return { profile: data as Profile, issue: 'inactive' }
  if (!roles.includes(data.role as AppRole)) return { profile: null, issue: 'invalid_role' }
  return { profile: data as Profile, issue: null }
}
