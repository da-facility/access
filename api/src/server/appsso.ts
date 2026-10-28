/**
 * Signing in to the RustDesk app with SSO. The app asks for a URL
 * (/api/oidc/auth), opens it in the browser, and polls /api/oidc/auth-query
 * until the browser comes back through /api/oidc/callback. A first sign-in
 * creates the RustDesk account, linked to the SSO account.
 */
import { randomBytes } from 'node:crypto'
import { createUser, userPayload, type User } from './accounts'
import { audit } from './audit'
import { now, one, run } from './db'
import { ApiError, optionalText, text } from './http'
import { adminGroup, authorizeUrl, page, pkce, publicUrl, redeem, type SsoProfile } from './oidc'

export const ssoProvider = 'Da Facility'
const appClientId = () => process.env.RD_OIDC_APP_CLIENT_ID ?? 'rustdesk'
const callbackUrl = () => publicUrl() + '/api/oidc/callback'
const PENDING_SECONDS = 600

type Pending = { code: string; state: string; verifier: string; device_id: string; device_uuid: string; device_info: string; ip: string; user_id: string | null; token: string | null; error: string | null }

export async function startAppSignIn(body: any, ip: string) {
  if (!body || typeof body !== 'object') throw new ApiError(400, 'Invalid request.')
  if (body.op !== ssoProvider) throw new ApiError(400, 'Unknown sign-in provider.')
  run('DELETE FROM oidc_requests WHERE created_at < ?', now() - PENDING_SECONDS)
  const { verifier, state, challenge } = pkce()
  const code = randomBytes(24).toString('base64url')
  run(
    'INSERT INTO oidc_requests (code, state, verifier, device_id, device_uuid, device_info, ip, created_at) VALUES (?,?,?,?,?,?,?,?)',
    code,
    state,
    verifier,
    optionalText(body.id, 'id', 64),
    optionalText(body.uuid, 'uuid', 256),
    JSON.stringify(body.deviceInfo && typeof body.deviceInfo === 'object' ? body.deviceInfo : {}),
    ip,
    now(),
  )
  return { code, url: await authorizeUrl(appClientId(), callbackUrl(), state, challenge) }
}

const html = (title: string, message: string, status = 200) =>
  new Response(page(title, message, ''), { status, headers: { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' } })

export async function finishAppSignIn(request: Request) {
  const url = new URL(request.url)
  const pending = one<Pending>('SELECT * FROM oidc_requests WHERE state=? AND created_at > ?', url.searchParams.get('state') ?? '', now() - PENDING_SECONDS)
  if (!pending) return html('Sign-in expired', 'Start again from the RustDesk app.', 400)
  const fail = (message: string, status = 403) => {
    run('UPDATE oidc_requests SET error=? WHERE code=?', message, pending.code)
    return html('Sign-in failed', message, status)
  }
  if (url.searchParams.get('error')) return fail(url.searchParams.get('error_description') ?? url.searchParams.get('error')!)
  const profile = await redeem(appClientId(), url.searchParams.get('code') ?? '', pending.verifier, callbackUrl())
  if (typeof profile === 'string') return fail(profile, 502)
  const user = linkedUser(profile)
  if (user.status !== 1) return fail('Your RustDesk account is disabled. Ask the administrator.')
  const token = randomBytes(32).toString('base64url')
  const { openSession } = await import('./rustdesk')
  openSession(user, token, { deviceId: pending.device_id, uuid: pending.device_uuid, deviceInfo: pending.device_info, ip: pending.ip })
  run('UPDATE oidc_requests SET user_id=?, token=? WHERE code=?', user.id, token, pending.code)
  const info = JSON.parse(pending.device_info) as { name?: string }
  audit({
    category: 'login',
    action: 'sso',
    actor: user.name,
    ip: pending.ip,
    deviceId: pending.device_id,
    summary: `Signed in to RustDesk with SSO${info.name ? ' on ' + String(info.name).slice(0, 80) : ''}`,
  })
  return html('Signed in', `You're signed in to RustDesk as ${user.name}. You can close this page and go back to the app.`)
}

export function queryAppSignIn(params: URLSearchParams) {
  const pending = one<Pending>('SELECT * FROM oidc_requests WHERE code=? AND created_at > ?', text(params.get('code'), 'code'), now() - PENDING_SECONDS)
  if (!pending) throw new ApiError(404, 'This sign-in expired. Start again.')
  if (pending.device_id !== (params.get('id') ?? '') || pending.device_uuid !== (params.get('uuid') ?? '')) throw new ApiError(403, 'This sign-in belongs to another device.')
  if (pending.error) {
    run('DELETE FROM oidc_requests WHERE code=?', pending.code)
    throw new ApiError(403, pending.error)
  }
  // The app keeps polling while it sees exactly this message.
  if (!pending.token || !pending.user_id) return { error: 'No authed oidc is found' }
  run('DELETE FROM oidc_requests WHERE code=?', pending.code)
  const user = one<User>('SELECT * FROM users WHERE id=?', pending.user_id)
  if (!user) throw new ApiError(404, 'Account not found.')
  return { type: 'access_token', access_token: pending.token, user: userPayload(user) }
}

/** The RustDesk account for an SSO account, created on first sign-in. */
function linkedUser(profile: SsoProfile): User {
  const existing = one<User>('SELECT * FROM users WHERE sso_subject=?', profile.sub)
  if (existing) return existing
  const cleaned = (profile.preferred_username || profile.email?.split('@')[0] || '')
    .toLowerCase()
    .replace(/[^a-z0-9_.-]/g, '')
    .slice(0, 56)
  const base = cleaned.length >= 3 ? cleaned : 'user'
  let name = base
  for (let n = 2; one('SELECT 1 FROM users WHERE name=?', name); n++) name = `${base}-${n}`
  // SSO accounts have no usable password; an admin can set one in the console.
  const id = createUser({
    name,
    password: randomBytes(32).toString('base64url'),
    displayName: profile.name ?? '',
    email: profile.email ?? '',
    isAdmin: !!profile.groups?.includes(adminGroup()),
  })
  run('UPDATE users SET sso_subject=? WHERE id=?', profile.sub, id)
  audit({ category: 'login', action: 'provisioned', actor: name, summary: `Created RustDesk account ${name} from SSO (${profile.email ?? profile.sub})` })
  return one<User>('SELECT * FROM users WHERE id=?', id)!
}
