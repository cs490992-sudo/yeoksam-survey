import { useEffect, useRef, type ReactNode } from 'react'

export function PageHeader({ title, description, action }: { title: string; description?: string; action?: ReactNode }) {
  return <header className="page-header"><div><h1>{title}</h1>{description && <p>{description}</p>}</div>{action}</header>
}
export function EmptyState({ title, description }: { title: string; description: string }) {
  return <div className="empty-state"><span aria-hidden="true">◇</span><strong>{title}</strong><p>{description}</p></div>
}
export function LoadingState({ label = '정보를 확인하고 있습니다.' }: { label?: string }) {
  return <div className="center-state" role="status"><span className="spinner" aria-hidden="true" />{label}</div>
}
export function ErrorState({ title = '문제가 발생했습니다.', message }: { title?: string; message: string }) {
  return <div className="error-state" role="alert"><strong>{title}</strong><p>{message}</p></div>
}
export function StatusBadge({ tone = 'neutral', children }: { tone?: 'success' | 'warning' | 'neutral'; children: ReactNode }) {
  return <span className={`badge ${tone}`}>{children}</span>
}

export function ConfirmDialog({ open, title, description, confirmLabel = '확인', onConfirm, onClose }: {
  open: boolean; title: string; description: string; confirmLabel?: string; onConfirm: () => void; onClose: () => void
}) {
  const cancelRef = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    if (!open) return
    cancelRef.current?.focus()
    const close = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose() }
    document.addEventListener('keydown', close)
    return () => document.removeEventListener('keydown', close)
  }, [open, onClose])
  if (!open) return null
  return <div className="dialog-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose() }}>
    <div role="dialog" aria-modal="true" aria-labelledby="dialog-title" aria-describedby="dialog-description" className="dialog">
      <h2 id="dialog-title">{title}</h2><p id="dialog-description">{description}</p>
      <div className="button-row"><button ref={cancelRef} className="button secondary" onClick={onClose}>취소</button><button className="button danger" onClick={onConfirm}>{confirmLabel}</button></div>
    </div>
  </div>
}
