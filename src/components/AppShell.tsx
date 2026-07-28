import { useEffect, useState } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { InstallPrompt, UpdatePrompt } from './pwa'

const attendanceUrl = import.meta.env.VITE_ATTENDANCE_APP_URL || 'https://yeoksam-attendance1.vercel.app'
const votingUrl = import.meta.env.VITE_VOTING_APP_URL || 'https://yeoksam-voting.vercel.app'

export function AppShell() {
  const [open, setOpen] = useState(false)
  const { profile, signOut } = useAuth()
  useEffect(() => {
    const close = (event: KeyboardEvent) => { if (event.key === 'Escape') setOpen(false) }
    document.addEventListener('keydown', close)
    return () => document.removeEventListener('keydown', close)
  }, [])
  const link = ({ isActive }: { isActive: boolean }) => isActive ? 'nav-link active' : 'nav-link'
  return <div className="app-layout">
    <header className="mobile-header"><button aria-label="메뉴 열기" aria-expanded={open} aria-controls="sidebar" onClick={() => setOpen(true)}>☰</button><strong>역삼 만족도 조사</strong></header>
    {open && <button className="drawer-overlay" aria-label="메뉴 닫기" onClick={() => setOpen(false)} />}
    <aside id="sidebar" className={`sidebar ${open ? 'open' : ''}`}>
      <div className="brand"><span className="brand-symbol" aria-hidden="true">✓</span><div><strong>역삼 만족도 조사</strong><small>역삼주간보호센터</small></div></div>
      <nav aria-label="주 메뉴" onClick={() => setOpen(false)}>
        <section><h2>조사 관리</h2><NavLink end className={link} to="/">대시보드</NavLink><NavLink className={link} to="/admin/new">새 조사</NavLink><NavLink className={link} to="/surveys">조사 목록</NavLink><NavLink className={link} to="/surveys/run">조사 진행</NavLink></section>
        <section><h2>기록 및 분석</h2><NavLink className={link} to="/surveys/completion">완료 현황</NavLink><NavLink className={link} to="/surveys/search">조사 기록 검색</NavLink><NavLink end className={link} to="/reports">결과 분석</NavLink><NavLink className={link} to="/reports/print">보고서</NavLink></section>
        <section><h2>이용인 및 연동</h2>{profile?.role === 'admin' && <NavLink className={link} to="/admin/client-photos">이용인 사진</NavLink>}<a href={attendanceUrl} target="_blank" rel="noopener noreferrer">출석 앱으로 이동 ↗</a><a href={votingUrl} target="_blank" rel="noopener noreferrer">투표 앱으로 이동 ↗</a></section>
      </nav>
      <footer className="sidebar-footer"><span>{profile?.role === 'admin' ? '관리자' : '직원'}</span><InstallPrompt /><button className="sidebar-button" onClick={() => void signOut()}>로그아웃</button></footer>
    </aside>
    <div className="content-wrap"><main className="content"><Outlet /></main></div>
    <UpdatePrompt />
  </div>
}
