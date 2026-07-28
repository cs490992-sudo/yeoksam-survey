import { useRegisterSW } from 'virtual:pwa-register/react'
import { useEffect, useState } from 'react'

interface InstallEvent extends Event { prompt: () => Promise<void>; userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }> }
export function InstallPrompt() {
  const [event, setEvent] = useState<InstallEvent | null>(null)
  useEffect(() => {
    const save = (e: Event) => { e.preventDefault(); setEvent(e as InstallEvent) }
    window.addEventListener('beforeinstallprompt', save)
    return () => window.removeEventListener('beforeinstallprompt', save)
  }, [])
  if (!event) return null
  return <button className="sidebar-button" onClick={async () => { await event.prompt(); await event.userChoice; setEvent(null) }}>앱 설치</button>
}
export function UpdatePrompt() {
  const { needRefresh: [needRefresh, setNeedRefresh], updateServiceWorker } = useRegisterSW()
  if (!needRefresh) return null
  return <aside className="update-prompt" role="status"><span>새 버전을 사용할 수 있습니다.</span><button onClick={() => updateServiceWorker(true)}>지금 업데이트</button><button aria-label="업데이트 안내 닫기" onClick={() => setNeedRefresh(false)}>닫기</button></aside>
}
