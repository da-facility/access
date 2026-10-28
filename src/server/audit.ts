import { now, run } from './db'

export type AuditCategory = 'file' | 'alarm' | 'login' | 'console' | 'device'

export type AuditEntry = {
  category: AuditCategory
  action?: string
  deviceId?: string
  peerId?: string
  actor?: string
  ip?: string
  connId?: string
  sessionId?: string
  summary?: string
  data?: unknown
}

export function audit(entry: AuditEntry) {
  run(
    'INSERT INTO audit (at, category, action, device_id, peer_id, actor, ip, conn_id, session_id, summary, data) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
    now(),
    entry.category,
    entry.action ?? '',
    entry.deviceId ?? '',
    entry.peerId ?? '',
    entry.actor ?? '',
    entry.ip ?? '',
    entry.connId ?? '',
    entry.sessionId ?? '',
    entry.summary ?? '',
    JSON.stringify(entry.data ?? {}),
  )
}

// Keep the log bounded; RustDesk clients can be chatty.
export function pruneAudit(days = Number(process.env.RD_AUDIT_RETENTION_DAYS ?? 365)) {
  run('DELETE FROM audit WHERE at < ?', now() - days * 86400)
}
