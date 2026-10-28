import { createHash, randomBytes } from 'node:crypto'
import { now, one, run } from './db'

const issuer = () => process.env.RD_OIDC_ISSUER ?? 'https://sso.dafacility.io'
const clientId = () => process.env.RD_OIDC_CLIENT_ID ?? 'rustdesk-console'
export const adminGroup = () => process.env.RD_OIDC_ADMIN_GROUP ?? 'admins'
export const publicUrl = () => (process.env.RD_PUBLIC_URL ?? 'https://rd.dafacility.io').replace(/\/$/, '')
export const callbackPath = '/admin/auth/callback'
export const sessionCookie = 'rd_console'
const stateCookie = 'rd_console_state'
const sessionDays = 7

type Discovery = { authorization_endpoint: string; token_endpoint: string; userinfo_endpoint: string; end_session_endpoint?: string }
let discovery: { value: Discovery; at: number } | undefined

async function discover(): Promise<Discovery> {
  if (discovery && Date.now() - discovery.at < 3_600_000) return discovery.value
  const response = await fetch(issuer() + '/.well-known/openid-configuration')
  if (!response.ok) throw new Error('SSO discovery failed: ' + response.status)
  discovery = { value: (await response.json()) as Discovery, at: Date.now() }
  return discovery.value
}

const b64url = (buffer: Buffer) => buffer.toString('base64url')
const sha256 = (value: string) => createHash('sha256').update(value).digest('hex')

export function cookie(name: string, value: string, maxAge: number) {
  const secure = publicUrl().startsWith('https:') ? '; Secure' : ''
  return `${name}=${value}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAge}${secure}`
}

export function readCookie(request: Request, name: string) {
  for (const part of (request.headers.get('cookie') ?? '').split(';')) {
    const [key, ...rest] = part.trim().split('=')
    if (key === name) return rest.join('=')
  }
  return undefined
}

export type SsoProfile = { sub: string; email?: string; name?: string; preferred_username?: string; groups?: string[] }

export function pkce() {
  const verifier = b64url(randomBytes(32))
  return { verifier, state: b64url(randomBytes(16)), challenge: b64url(createHash('sha256').update(verifier).digest()) }
}

/** Where to send the browser to sign in with SSO (authorization code + PKCE). */
export async function authorizeUrl(client: string, redirectUri: string, state: string, challenge: string) {
  const { authorization_endpoint } = await discover()
  const url = new URL(authorization_endpoint)
  url.search = new URLSearchParams({
    response_type: 'code',
    client_id: client,
    redirect_uri: redirectUri,
    scope: 'openid profile email groups',
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256',
  }).toString()
  return url.toString()
}

/** Trades the callback's code for the signed-in person's SSO profile, or says why SSO refused. */
export async function redeem(client: string, code: string, verifier: string, redirectUri: string): Promise<SsoProfile | string> {
  const { token_endpoint, userinfo_endpoint } = await discover()
  const tokenResponse = await fetch(token_endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'authorization_code', code, redirect_uri: redirectUri, client_id: client, code_verifier: verifier }),
  })
  if (!tokenResponse.ok) return 'SSO rejected the sign-in code.'
  const { access_token } = (await tokenResponse.json()) as { access_token?: string }
  if (!access_token) return 'SSO did not return an access token.'
  const infoResponse = await fetch(userinfo_endpoint, { headers: { authorization: 'Bearer ' + access_token } })
  if (!infoResponse.ok) return 'SSO did not return your profile.'
  return (await infoResponse.json()) as SsoProfile
}

export async function beginLogin(returnTo: string) {
  const { verifier, state, challenge } = pkce()
  const location = await authorizeUrl(clientId(), publicUrl() + callbackPath, state, challenge)
  const safeReturn = returnTo.startsWith('/admin') ? returnTo : '/admin'
  const payload = Buffer.from(JSON.stringify({ state, verifier, returnTo: safeReturn })).toString('base64url')
  return new Response(null, { status: 302, headers: { location, 'set-cookie': cookie(stateCookie, payload, 600) } })
}

export async function finishLogin(request: Request) {
  const url = new URL(request.url)
  const raw = readCookie(request, stateCookie)
  const fail = (message: string, status = 400) =>
    new Response(page('Sign-in failed', message), { status, headers: { 'content-type': 'text/html; charset=utf-8', 'set-cookie': cookie(stateCookie, '', 0) } })
  if (!raw) return fail('The sign-in attempt expired. Start again from the console.')
  let saved: { state: string; verifier: string; returnTo: string }
  try {
    saved = JSON.parse(Buffer.from(raw, 'base64url').toString())
  } catch {
    return fail('The sign-in attempt was malformed. Start again from the console.')
  }
  if (url.searchParams.get('error')) return fail(url.searchParams.get('error_description') ?? url.searchParams.get('error')!, 403)
  if (!saved.state || url.searchParams.get('state') !== saved.state) return fail('The sign-in state did not match. Start again from the console.')
  const info = await redeem(clientId(), url.searchParams.get('code') ?? '', saved.verifier, publicUrl() + callbackPath)
  if (typeof info === 'string') return fail(info, 502)
  if (!info.groups?.includes(adminGroup())) return fail(`Your SSO account is not in the "${adminGroup()}" group.`, 403)
  const token = b64url(randomBytes(32))
  run('DELETE FROM console_sessions WHERE expires<=?', now())
  run(
    'INSERT INTO console_sessions VALUES (?,?,?,?,?,?)',
    sha256(token),
    info.sub,
    info.name || info.preferred_username || info.email || info.sub,
    info.email ?? '',
    now() + sessionDays * 86400,
    now(),
  )
  const { audit } = await import('./audit')
  audit({ category: 'console', action: 'sign-in', actor: info.email || info.sub, ip: clientIp(request), summary: 'Signed in to the console' })
  const headers = new Headers({ location: saved.returnTo })
  headers.append('set-cookie', cookie(sessionCookie, token, sessionDays * 86400))
  headers.append('set-cookie', cookie(stateCookie, '', 0))
  return new Response(null, { status: 302, headers })
}

export type ConsoleUser = { subject: string; name: string; email: string }

export function consoleUser(request: Request): ConsoleUser | undefined {
  const token = readCookie(request, sessionCookie)
  if (!token) return undefined
  return one<ConsoleUser>('SELECT subject, name, email FROM console_sessions WHERE token=? AND expires>?', sha256(token), now())
}

export async function logout(request: Request) {
  const token = readCookie(request, sessionCookie)
  if (token) run('DELETE FROM console_sessions WHERE token=?', sha256(token))
  const { end_session_endpoint } = await discover().catch(() => ({ end_session_endpoint: undefined }))
  const location = end_session_endpoint ? `${end_session_endpoint}?client_id=${encodeURIComponent(clientId())}` : '/admin'
  return new Response(null, { status: 302, headers: { location, 'set-cookie': cookie(sessionCookie, '', 0) } })
}

export function clientIp(request: Request) {
  return request.headers.get('x-forwarded-for')?.split(',')[0].trim() || request.headers.get('x-real-ip') || ''
}

export function page(title: string, message: string, retry = '/admin/login') {
  const escape = (value: string) => value.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!)
  return `<!doctype html><meta charset="utf-8"><title>${escape(title)}</title><body style="font:16px system-ui;max-width:32rem;margin:4rem auto"><h1>${escape(title)}</h1><p>${escape(message)}</p>${retry ? `<p><a href="${retry}">Try again</a></p>` : ''}</body>`
}
