import { Navigate, Outlet } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { ErrorState, LoadingState } from './ui'

const issueMessages = {
  profile_missing: '등록된 사용자 프로필이 없습니다. 관리자에게 문의해 주세요.',
  inactive: '비활성화된 계정입니다. 관리자에게 문의해 주세요.',
  invalid_role: '이 앱을 사용할 수 있는 역할이 아닙니다.',
  profile_error: '사용자 권한을 확인하지 못했습니다. 잠시 후 다시 시도해 주세요.',
}

export function ProtectedRoute() {
  const { loading, session, issue, signOut } = useAuth()
  if (loading) return <LoadingState label="로그인과 사용자 권한을 확인하고 있습니다." />
  if (!session) return <Navigate to="/login" replace />
  if (issue) return <main className="access-page"><ErrorState title="접근할 수 없습니다." message={issueMessages[issue]} /><button className="button" onClick={() => void signOut()}>로그아웃</button></main>
  return <Outlet />
}

export function AdminRoute() {
  const { profile } = useAuth()
  if (profile?.role !== 'admin') return <main><ErrorState title="관리자 전용 페이지" message="이 페이지는 관리자만 접근할 수 있습니다." /></main>
  return <Outlet />
}
