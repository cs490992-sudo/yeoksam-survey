import { createClient, type SupabaseClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL?.trim()
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY?.trim()

export const supabaseConfigured = Boolean(url && publishableKey)
export const configurationMessage =
  'Supabase 연결 정보가 없습니다. .env.local에 VITE_SUPABASE_URL과 VITE_SUPABASE_PUBLISHABLE_KEY를 설정해 주세요.'

let client: SupabaseClient | null = null

export function getSupabase(): SupabaseClient | null {
  if (!supabaseConfigured) return null
  if (!client) client = createClient(url!, publishableKey!)
  return client
}
