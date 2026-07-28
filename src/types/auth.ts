export type AppRole = 'admin' | 'staff'

export interface Profile {
  id: string
  organization_id: string
  role: AppRole
  is_active: boolean
}

export type AccessIssue = 'profile_missing' | 'inactive' | 'invalid_role' | 'profile_error' | null
