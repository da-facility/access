/**
 * The HTTP API RustDesk clients use when "API server" points here. It mirrors
 * the parts of RustDesk Server Pro's API that the open-source client calls:
 * accounts, address books, device check-ins (sysinfo/heartbeat), policy push
 * and audit. Request and response shapes follow the client source.
 */
import { randomUUID } from 'node:crypto'
import { accessibleDeviceGroupIds, bookRule, canAccessDevice, userGroupIds, userOnDevice } from './access'
import { checkPassword, createUser, digest, newToken, userPayload, type User } from './accounts'
import { audit } from './audit'
import { all, getSetting, now, one, parse, run, transaction } from './db'
import { ApiError, errorResponse, jsonResponse, optionalText, readJson, text, textResponse } from './http'
import { clientIp } from './oidc'
import { effectivePolicy, payloadFor, stamp } from './policy'

const SESSION_DAYS = 30
const MAX_PEERS = 1000
const MAX_TAGS = 100
const empty = () => new Response(null, { status: 200, headers: { 'cache-control': 'no-store' } })

export async function handleRustDesk(request: Request): Promise<Response> {
  try {
    const result = await dispatch(request)
    if (result instanceof Response) return result
    if (result === undefined) return empty()
    return jsonResponse(result)
  } catch (error) {
    return errorResponse(error)
  }
}

async function dispatch(request: Request): Promise<unknown> {
  const url = new URL(request.url)
  const path = url.pathname.replace(/\/+$/, '')
  const method = request.method
  const query = url.searchParams
  const ip = clientIp(request)

  // ---- Unauthenticated: devices and sign-in ------------------------------
  if (method === 'POST' && path === '/api/sysinfo') return sysinfo(await readJson(request), ip)
  if (method === 'POST' && path === '/api/heartbeat') return heartbeat(await readJson(request), ip)
  if (method === 'POST' && path.startsWith('/api/audit/')) return auditPost(path.slice('/api/audit/'.length), await readJson(request), ip)
  if (method === 'GET' && path === '/api/login-options') return []
  if (method === 'GET' && path === '/api/access/capabilities') return { version: 1, kvms: true, registration: registrationOpen() }
  if (method === 'POST' && path === '/api/login') return login(await readJson(request), ip)
  if (method === 'POST' && path === '/api/access/register') {
    limitLogin(ip)
    if (!registrationOpen()) throw new ApiError(403, 'Registration is disabled. Ask the server operator for an account.')
    const body = await readJson(request)
    createUser({ name: body?.username, password: body?.password })
    audit({ category: 'login', action: 'register', actor: String(body?.username ?? ''), ip, summary: 'Created an account from the sign-up page' })
    return { created: true }
  }

  // ---- Signed in ---------------------------------------------------------
  const { user, token } = authenticate(request)

  if (method === 'POST' && path === '/api/currentUser') return userPayload(user)
  if (method === 'POST' && path === '/api/logout') {
    run('DELETE FROM sessions WHERE token=?', digest(token))
    audit({ category: 'login', action: 'logout', actor: user.name, ip, summary: 'Signed out of RustDesk' })
    return undefined
  }

  if (method === 'POST' && path === '/api/ab/personal') return { guid: personalBook(user) }
  if (method === 'POST' && path === '/api/ab/settings') return { max_peer_one_ab: MAX_PEERS }
  if (method === 'POST' && path === '/api/ab/shared/profiles') return page(sharedProfiles(user), query)
  if (method === 'POST' && path === '/api/ab/peers') {
    const book = query.get('ab') ?? ''
    if (bookRule(user, book) < 1) throw new ApiError(404, 'Address book not found.')
    return page(
      all<{ data: string }>('SELECT data FROM peers WHERE book_id=? ORDER BY id', book).map((r) => parse(r.data, {})),
      query,
    )
  }
  if (path.startsWith('/api/ab/')) return addressBookAction(user, method, path, request)

  if (method === 'GET' && path === '/api/device-group/accessible') {
    const ids = accessibleDeviceGroupIds(user)
    const groups = all<{ id: string; name: string }>('SELECT id, name FROM device_groups ORDER BY name').filter((g) => ids.includes(g.id))
    return page(groups.map((g) => ({ name: g.name })), query)
  }
  if (method === 'GET' && path === '/api/users') return page(visibleUsers(user).map(userPayload), query)
  if (method === 'GET' && path === '/api/peers') return page(visiblePeers(user), query)

  if (method === 'GET' && path === '/api/audit/conn/active') {
    const row = one<{ guid: string }>(
      'SELECT guid FROM connections WHERE device_id=? AND session_id=? ORDER BY started_at DESC LIMIT 1',
      text(query.get('id'), 'id'),
      text(query.get('session_id'), 'session'),
    )
    if (!row) throw new ApiError(404, 'Connection not found.')
    return row.guid
  }
  if (method === 'PUT' && path === '/api/audit') {
    const body = await readJson(request)
    run('UPDATE connections SET note=? WHERE guid=?', optionalText(body?.note, 'note', 2000), text(body?.guid, 'guid'))
    return undefined
  }

  if (path === '/api/access/kvms') return kvms(user, method, request)

  throw new ApiError(404, 'Endpoint not found.')
}

// ---------------------------------------------------------------------------
// Accounts

function registrationOpen() {
  return getSetting('registration', 'off') === 'on'
}

function limitLogin(source: string) {
  const t = now()
  run('DELETE FROM attempts WHERE started < ?', t - 900)
  run('INSERT INTO attempts VALUES (?,?,1) ON CONFLICT(source) DO UPDATE SET count=count+1', source || 'unknown', t)
  const count = one<{ count: number }>('SELECT count FROM attempts WHERE source=?', source || 'unknown')?.count ?? 0
  if (count > 30) throw new ApiError(429, 'Too many login attempts. Try again in 15 minutes.')
}

function login(body: any, ip: string) {
  limitLogin(ip)
  if (!body || typeof body !== 'object') throw new ApiError(400, 'Invalid login.')
  const name = text(body.username, 'username', 64).toLowerCase()
  const password = body.password
  const user = one<User>('SELECT * FROM users WHERE name=?', name)
  if (typeof password !== 'string' || password.length > 256 || !checkPassword(user, password)) {
    audit({ category: 'login', action: 'failed', actor: name, ip, deviceId: optionalText(body.id, 'id'), summary: 'Wrong username or password' })
    throw new ApiError(401, 'Incorrect username or password.')
  }
  if (user!.status !== 1) {
    audit({ category: 'login', action: 'blocked', actor: name, ip, deviceId: optionalText(body.id, 'id'), summary: 'Disabled account tried to sign in' })
    throw new ApiError(403, 'This account is disabled.')
  }
  const token = newToken()
  const t = now()
  const deviceId = optionalText(body.id, 'id', 64)
  run('DELETE FROM sessions WHERE expires<=?', t)
  run(
    'INSERT INTO sessions (token, owner, expires, created_at, last_used_at, device_id, device_uuid, device_info, ip) VALUES (?,?,?,?,?,?,?,?,?)',
    digest(token),
    user!.id,
    t + SESSION_DAYS * 86400,
    t,
    t,
    deviceId,
    optionalText(body.uuid, 'uuid', 256),
    JSON.stringify(typeof body.deviceInfo === 'object' && body.deviceInfo ? body.deviceInfo : {}),
    ip,
  )
  run('UPDATE users SET last_login_at=? WHERE id=?', t, user!.id)
  const info = body.deviceInfo && typeof body.deviceInfo === 'object' ? body.deviceInfo : {}
  audit({
    category: 'login',
    action: 'login',
    actor: user!.name,
    ip,
    deviceId,
    summary: `Signed in to RustDesk${info.name ? ' on ' + String(info.name).slice(0, 80) : ''}`,
    data: { os: info.os, name: info.name },
  })
  return { type: 'access_token', access_token: token, user: userPayload(user!) }
}

function authenticate(request: Request) {
  const header = request.headers.get('authorization') ?? ''
  if (!header.startsWith('Bearer ') || header.length > 512) throw new ApiError(401, 'Please log in again.')
  const token = header.slice(7)
  const user = one<User>(
    'SELECT users.* FROM users JOIN sessions ON users.id=sessions.owner WHERE sessions.token=? AND sessions.expires>? AND users.status=1',
    digest(token),
    now(),
  )
  if (!user) throw new ApiError(401, 'Please log in again.')
  run('UPDATE sessions SET last_used_at=? WHERE token=?', now(), digest(token))
  return { user, token }
}

function page<T>(items: T[], query: URLSearchParams) {
  const current = Math.max(1, Number(query.get('current') ?? 1) || 1)
  const size = Math.max(1, Math.min(100, Number(query.get('pageSize') ?? 100) || 100))
  return { total: items.length, data: items.slice((current - 1) * size, current * size) }
}

function visibleUsers(user: User): User[] {
  if (user.is_admin) return all<User>('SELECT * FROM users WHERE status=1 ORDER BY name')
  const groups = userGroupIds(user.id)
  if (groups.length === 0) return [user]
  return all<User>(
    `SELECT DISTINCT users.* FROM users JOIN user_group_members m ON m.user_id=users.id
     WHERE users.status=1 AND m.group_id IN (${groups.map(() => '?').join(',')}) ORDER BY users.name`,
    ...groups,
  )
}

function visiblePeers(user: User) {
  const groupIds = accessibleDeviceGroupIds(user)
  const rows = all<{ id: string; hostname: string; username: string; os: string; note: string; alias: string; owner: string | null; owner_name: string | null; group_id: string | null; group_name: string | null; last_seen: number; disabled: number }>(
    `SELECT d.id, d.hostname, d.username, d.os, d.note, d.alias, d.owner, u.name AS owner_name, d.device_group_id AS group_id, g.name AS group_name, d.last_seen, d.disabled
     FROM devices d LEFT JOIN users u ON u.id=d.owner LEFT JOIN device_groups g ON g.id=d.device_group_id ORDER BY d.id`,
  )
  return rows
    .filter((d) => !d.disabled && (user.is_admin || d.owner === user.id || (d.group_id && groupIds.includes(d.group_id))))
    .map((d) => ({
      id: d.id,
      info: { username: d.username, os: d.os, device_name: d.alias || d.hostname },
      status: 1,
      user: d.owner ?? '',
      user_name: d.owner_name ?? '',
      device_group_name: d.group_name ?? '',
      note: d.note,
      online: now() - d.last_seen < 60,
    }))
}

// ---------------------------------------------------------------------------
// Address books

export function personalBook(user: Pick<User, 'id'>) {
  const existing = one<{ id: string }>("SELECT id FROM address_books WHERE kind='personal' AND owner=?", user.id)
  if (existing) return existing.id
  const id = randomUUID()
  run("INSERT INTO address_books (id, kind, name, owner, created_at) VALUES (?, 'personal', 'My address book', ?, ?)", id, user.id, now())
  return id
}

function sharedProfiles(user: User) {
  return all<{ id: string; name: string; note: string; owner_name: string | null }>(
    "SELECT b.id, b.name, b.note, u.name AS owner_name FROM address_books b LEFT JOIN users u ON u.id=b.owner WHERE b.kind='shared' ORDER BY b.name",
  )
    .map((b) => ({ guid: b.id, name: b.name, owner: b.owner_name ?? 'admin', note: b.note, rule: bookRule(user, b.id), info: {} }))
    .filter((b) => b.rule > 0)
}

const peerKeys = new Set(['id', 'alias', 'hash', 'password', 'username', 'hostname', 'platform', 'note', 'tags', 'forceAlwaysRelay', 'rdpPort', 'rdpUsername', 'loginName'])

function cleanPeer(body: unknown, shared: boolean) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new ApiError(400, 'Invalid connection.')
  const data: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(body)) {
    if (!peerKeys.has(key)) continue
    // A personal book keeps the password hash; a shared one keeps a password.
    if (key === (shared ? 'hash' : 'password')) continue
    if (key === 'tags') {
      if (!Array.isArray(value) || value.length > MAX_TAGS) throw new ApiError(400, 'Invalid tags.')
      data.tags = value.map((t) => text(t, 'tag', 100))
    } else {
      data[key] = text(value, key, key === 'hash' || key === 'note' || key === 'password' ? 4096 : 256, key !== 'id')
    }
  }
  if (!data.id) throw new ApiError(400, 'A RustDesk ID or address is required.')
  return data as { id: string; tags?: string[] }
}

async function addressBookAction(user: User, method: string, path: string, request: Request) {
  const parts = path.split('/')
  const bookId = parts[parts.length - 1]
  const action = parts.slice(3, -1).join('/')
  const rule = bookRule(user, bookId)
  if (rule < 1) throw new ApiError(404, 'Address book not found.')
  if (method === 'POST' && action === 'tags')
    return all('SELECT name, color FROM tags WHERE book_id=? ORDER BY name', bookId)
  if (rule < 2) throw new ApiError(403, 'You can only read this address book.')
  const shared = one<{ kind: string }>('SELECT kind FROM address_books WHERE id=?', bookId)?.kind === 'shared'
  const body = await readJson(request)
  transaction(() => {
    if ((action === 'peer/add' && method === 'POST') || (action === 'peer/update' && method === 'PUT')) {
      const data = cleanPeer(body, shared)
      const old = one<{ data: string }>('SELECT data FROM peers WHERE book_id=? AND id=?', bookId, data.id)
      if (action === 'peer/update' && !old) throw new ApiError(404, 'Connection not found.')
      const merged = old ? { ...parse<Record<string, unknown>>(old.data, {}), ...data } : data
      if (!old && (one<{ n: number }>('SELECT count(*) AS n FROM peers WHERE book_id=?', bookId)?.n ?? 0) >= MAX_PEERS)
        throw new ApiError(409, 'Address book is full.')
      run('INSERT INTO peers VALUES (?,?,?) ON CONFLICT(book_id, id) DO UPDATE SET data=excluded.data', bookId, data.id, JSON.stringify(merged))
    } else if (action === 'peer' && method === 'DELETE') {
      if (!Array.isArray(body) || body.length > MAX_PEERS) throw new ApiError(400, 'Invalid connection IDs.')
      for (const id of body) run('DELETE FROM peers WHERE book_id=? AND id=?', bookId, text(id, 'ID'))
    } else if (['tag/add', 'tag/update', 'tag/rename', 'tag'].includes(action)) {
      mutateTags(bookId, action, method, body)
    } else {
      throw new ApiError(404, 'Endpoint not found.')
    }
  })
  return undefined
}

function mutateTags(bookId: string, action: string, method: string, body: any) {
  let names: string[]
  let replacement: string | null = null
  if (action === 'tag' && method === 'DELETE') {
    if (!Array.isArray(body) || body.length > MAX_TAGS) throw new ApiError(400, 'Invalid tags.')
    names = body.map((t: unknown) => text(t, 'tag', 100))
    for (const name of names) run('DELETE FROM tags WHERE book_id=? AND name=?', bookId, name)
  } else if (action === 'tag/rename' && method === 'PUT' && body && typeof body === 'object') {
    names = [text(body.old, 'tag', 100)]
    replacement = text(body.new, 'tag', 100)
    if (one('SELECT 1 FROM tags WHERE book_id=? AND name=?', bookId, replacement)) throw new ApiError(409, 'Tag already exists.')
    run('UPDATE tags SET name=? WHERE book_id=? AND name=?', replacement, bookId, names[0])
  } else if ((action === 'tag/add' && method === 'POST') || (action === 'tag/update' && method === 'PUT')) {
    const name = text(body?.name, 'tag', 100)
    const color = body?.color ?? 0
    if (!Number.isInteger(color) || color < 0 || color > 0xffffffff) throw new ApiError(400, 'Invalid color.')
    const count = one<{ n: number }>('SELECT count(*) AS n FROM tags WHERE book_id=?', bookId)?.n ?? 0
    if (count >= MAX_TAGS && !one('SELECT 1 FROM tags WHERE book_id=? AND name=?', bookId, name)) throw new ApiError(409, 'Too many tags.')
    run('INSERT INTO tags VALUES (?,?,?) ON CONFLICT(book_id, name) DO UPDATE SET color=excluded.color', bookId, name, color)
    return
  } else {
    throw new ApiError(400, 'Invalid tag operation.')
  }
  for (const row of all<{ id: string; data: string }>('SELECT id, data FROM peers WHERE book_id=?', bookId)) {
    const peer = parse<{ tags?: string[] }>(row.data, {})
    const tags = (peer.tags ?? []).flatMap((t) => (names.includes(t) ? (replacement ? [replacement] : []) : [t]))
    run('UPDATE peers SET data=? WHERE book_id=? AND id=?', JSON.stringify({ ...peer, tags }), bookId, row.id)
  }
}

// ---------------------------------------------------------------------------
// Devices

type DeviceRow = {
  id: string
  uuid: string
  owner: string | null
  device_group_id: string | null
  strategy_id: string | null
  pushed_keys: string
  pending_disconnect: string
  reported_policy: number
  disabled: number
}

function sysinfo(body: any, ip: string) {
  if (!body || typeof body !== 'object') throw new ApiError(400, 'Invalid system info.')
  const id = text(body.id, 'id', 64)
  const uuid = optionalText(body.uuid, 'uuid', 256)
  const t = now()
  const existing = one<DeviceRow>('SELECT * FROM devices WHERE id=?', id)
  if (existing?.uuid && uuid && existing.uuid !== uuid) {
    // Another machine claiming a known ID; keep the original until an admin forgets it.
    audit({ category: 'alarm', action: 'uuid-mismatch', deviceId: id, ip, summary: 'A different machine reported this RustDesk ID; ignored' })
    return textResponse('SYSINFO_UPDATED')
  }
  const fields = {
    hostname: optionalText(body.hostname, 'hostname'),
    username: optionalText(body.username, 'username'),
    os: optionalText(body.os, 'os', 512),
    version: optionalText(body.version, 'version', 64),
  }
  const info = {
    cpu: optionalText(body.cpu, 'cpu', 512),
    memory: optionalText(body.memory, 'memory', 64),
    ...fields,
  }
  if (!existing) {
    run(
      'INSERT INTO devices (id, uuid, hostname, username, os, version, sysinfo, ip, first_seen, last_seen, sysinfo_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
      id,
      uuid,
      fields.hostname,
      fields.username,
      fields.os,
      fields.version,
      JSON.stringify(info),
      ip,
      t,
      t,
      t,
    )
    audit({ category: 'device', action: 'registered', deviceId: id, ip, summary: `New device ${fields.hostname || id} checked in` })
  } else {
    run(
      'UPDATE devices SET uuid=?, hostname=?, username=?, os=?, version=?, sysinfo=?, ip=?, last_seen=?, sysinfo_at=? WHERE id=?',
      uuid || existing.uuid,
      fields.hostname,
      fields.username,
      fields.os,
      fields.version,
      JSON.stringify(info),
      ip,
      t,
      t,
      id,
    )
  }
  applyPresets(id, body)
  return textResponse('SYSINFO_UPDATED')
}

/** Custom clients can pre-assign a device with preset-* options. */
function applyPresets(id: string, body: Record<string, unknown>) {
  const device = one<DeviceRow>('SELECT * FROM devices WHERE id=?', id)!
  const preset = (key: string) => (typeof body[key] === 'string' ? (body[key] as string).trim() : '')
  const owner = preset('preset-user-name')
  if (owner && !device.owner) {
    const user = one<{ id: string }>('SELECT id FROM users WHERE name=?', owner.toLowerCase())
    if (user) run('UPDATE devices SET owner=? WHERE id=?', user.id, id)
  }
  const group = preset('preset-device-group-name')
  if (group && !device.device_group_id) {
    const row = one<{ id: string }>('SELECT id FROM device_groups WHERE name=?', group)
    if (row) run('UPDATE devices SET device_group_id=? WHERE id=?', row.id, id)
  }
  const strategy = preset('preset-strategy-name')
  if (strategy && !device.strategy_id) {
    const row = one<{ id: string }>('SELECT id FROM strategies WHERE name=?', strategy)
    if (row) run('UPDATE devices SET strategy_id=? WHERE id=?', row.id, id)
  }
  const note = preset('preset-note')
  if (note) run("UPDATE devices SET note=? WHERE id=? AND note=''", note.slice(0, 2000), id)
  const bookName = preset('preset-address-book-name')
  if (bookName) {
    const book = one<{ id: string }>("SELECT id FROM address_books WHERE kind='shared' AND name=?", bookName)
    if (book && !one('SELECT 1 FROM peers WHERE book_id=? AND id=?', book.id, id)) {
      const tag = preset('preset-address-book-tag')
      const peer = {
        id,
        alias: preset('preset-address-book-alias'),
        note: preset('preset-address-book-note'),
        password: preset('preset-address-book-password'),
        tags: tag ? [tag] : [],
      }
      run('INSERT INTO peers VALUES (?,?,?)', book.id, id, JSON.stringify(peer))
    }
  }
}

function heartbeat(body: any, ip: string) {
  if (!body || typeof body !== 'object') throw new ApiError(400, 'Invalid heartbeat.')
  const id = text(body.id, 'id', 64)
  const uuid = optionalText(body.uuid, 'uuid', 256)
  const device = one<DeviceRow>('SELECT * FROM devices WHERE id=?', id)
  // Unknown device: ask it for its system info first.
  if (!device) return { sysinfo: true }
  if (device.uuid && uuid && device.uuid !== uuid) return {}
  const conns = Array.isArray(body.conns) ? body.conns.filter((c: unknown) => Number.isInteger(c)).slice(0, 100) : []
  const reported = Number.isSafeInteger(body.modified_at) ? body.modified_at : 0
  const reply: Record<string, unknown> = {}

  const { options } = effectivePolicy(id)
  // The version covers the policy's options; keys to clear ride along with it.
  const version = stamp(options)
  let pushedKeys = device.pushed_keys
  if (reported === version && device.reported_policy !== version && version !== 0) {
    // The device confirmed this version; from now on only its keys need clearing.
    pushedKeys = JSON.stringify(Object.keys(options))
    audit({ category: 'device', action: 'policy-applied', deviceId: id, ip, summary: 'Device applied its policy' })
  } else if (reported === version && version === 0) {
    pushedKeys = '[]'
  } else if (reported !== version) {
    reply.strategy = { config_options: payloadFor(options, parse<string[]>(device.pushed_keys, [])), extra: {} }
    reply.modified_at = version
  }

  const pending = parse<number[]>(device.pending_disconnect, []).filter((c) => conns.includes(c))
  if (device.disabled) reply.disconnect = conns
  else if (pending.length) reply.disconnect = pending

  run(
    "UPDATE devices SET last_seen=?, ip=?, conns=?, ver=?, reported_policy=?, pushed_keys=?, pending_disconnect='[]' WHERE id=?",
    now(),
    ip,
    JSON.stringify(conns),
    Number.isSafeInteger(body.ver) ? body.ver : 0,
    reported,
    pushedKeys,
    id,
  )
  return reply
}

// ---------------------------------------------------------------------------
// Audit (posted by the controlled device; no account)

const connTypes = ['Remote control', 'File transfer', 'Port forward', 'Camera', 'Terminal']
const authKinds = ['', 'Accepted by click', 'One-time password', 'Permanent password', 'Switched sides']

function seen(nonce: unknown) {
  if (typeof nonce !== 'string' || !nonce) return false
  run('DELETE FROM nonces WHERE at < ?', now() - 900)
  const fresh = run('INSERT OR IGNORE INTO nonces VALUES (?, ?)', nonce.slice(0, 64), now()).changes
  return fresh === 0
}

function auditPost(kind: string, body: any, ip: string) {
  if (!body || typeof body !== 'object') throw new ApiError(400, 'Invalid audit record.')
  // Retries carry the same nonce; answer them as if stored.
  if (seen(body.nonce)) return undefined
  const deviceId = text(String(body.id ?? ''), 'id', 64)
  const known = one<{ uuid: string }>('SELECT uuid FROM devices WHERE id=?', deviceId)
  if (known?.uuid && body.uuid && known.uuid !== body.uuid) return undefined

  if (kind === 'conn') {
    const connId = Number.isInteger(body.conn_id) ? body.conn_id : null
    const sessionId = body.session_id === undefined || body.session_id === 0 ? '' : String(body.session_id)
    // The controlling side's note at the end of a session.
    if (connId === null && typeof body.note === 'string') {
      run(
        'UPDATE connections SET note=? WHERE guid=(SELECT guid FROM connections WHERE device_id=? AND session_id=? ORDER BY started_at DESC LIMIT 1)',
        body.note.slice(0, 2000),
        deviceId,
        sessionId,
      )
      return undefined
    }
    if (connId === null) throw new ApiError(400, 'Invalid connection id.')
    const latest = () =>
      one<{ guid: string; ended_at: number | null }>(
        'SELECT guid, ended_at FROM connections WHERE device_id=? AND conn_id=? ORDER BY started_at DESC LIMIT 1',
        deviceId,
        connId,
      )
    if (body.action === 'new') {
      run(
        'INSERT INTO connections (guid, device_id, conn_id, ip, started_at) VALUES (?,?,?,?,?)',
        randomUUID(),
        deviceId,
        connId,
        optionalText(body.ip, 'ip', 128),
        now(),
      )
    } else if (body.action === 'close') {
      const row = latest()
      if (row && !row.ended_at) run('UPDATE connections SET ended_at=? WHERE guid=?', now(), row.guid)
    } else if (Array.isArray(body.peer)) {
      let row = latest()
      if (!row || row.ended_at) {
        const guid = randomUUID()
        run('INSERT INTO connections (guid, device_id, conn_id, started_at) VALUES (?,?,?,?)', guid, deviceId, connId, now())
        row = { guid, ended_at: null }
      }
      const peerId = String(body.peer[0] ?? '').slice(0, 64)
      const peerName = String(body.peer[1] ?? '').slice(0, 128)
      const peerUser = userOnDevice(peerId)
      run(
        'UPDATE connections SET session_id=?, peer_id=?, peer_name=?, peer_user=?, type=?, primary_auth=?, two_factor=?, authorized_at=? WHERE guid=?',
        sessionId,
        peerId,
        peerName,
        peerUser?.name ?? '',
        Number.isInteger(body.type) ? body.type : null,
        Number.isInteger(body.primary_auth) ? body.primary_auth : null,
        Number.isInteger(body.two_factor) ? body.two_factor : null,
        now(),
        row.guid,
      )
      enforce(deviceId, connId, row.guid, peerId, peerUser)
    }
    return undefined
  }

  if (kind === 'file') {
    const info = parse<{ ip?: string; name?: string; num?: number; files?: [string, number][] }>(body.info, {})
    const direction = body.type === 0 ? 'sent to' : 'received from'
    audit({
      category: 'file',
      action: body.type === 0 ? 'send' : 'receive',
      deviceId,
      peerId: optionalText(String(body.peer_id ?? ''), 'peer', 64),
      actor: info.name ?? '',
      ip: info.ip ?? ip,
      connId: String(body.conn_id ?? ''),
      summary: `${info.num ?? 1} ${body.is_file ? 'file' : 'item'}${(info.num ?? 1) === 1 ? '' : 's'} ${direction} ${String(body.path ?? '').slice(0, 300)}`,
      data: { path: body.path, is_file: body.is_file, files: info.files?.slice(0, 10) },
    })
    return undefined
  }

  if (kind === 'alarm') {
    const info = parse<{ ip?: string; id?: string; name?: string; message?: string }>(body.info, {})
    audit({
      category: 'alarm',
      action: String(body.typ ?? ''),
      deviceId,
      peerId: info.id ?? '',
      actor: info.name ?? '',
      ip: info.ip ?? '',
      connId: String(body.conn_id ?? ''),
      summary: alarmText(body.typ, info.message),
      data: info,
    })
    return undefined
  }
  throw new ApiError(404, 'Endpoint not found.')
}

export function alarmText(typ: unknown, message?: string) {
  const known: Record<number, string> = {
    0: 'Blocked by the IP allow list',
    1: 'More than 30 failed password attempts',
    2: '6 failed password attempts within a minute',
    6: 'Repeated attempts from one IPv6 prefix',
    7: 'Terminal OS sign-in back-off',
    8: 'Too many terminal OS sign-ins at once',
    9: 'Session tried to exceed its permissions',
    10: 'Blocked by the ID allow list',
  }
  const base = known[Number(typ)] ?? `Alarm ${String(typ)}`
  return message ? `${base}: ${message.slice(0, 200)}` : base
}

/** In a restricted group, end sessions from people who have no grant to it. */
function enforce(deviceId: string, connId: number, guid: string, peerId: string, peerUser: User | undefined) {
  const group = one<{ name: string; restrict_connections: number }>(
    'SELECT g.name, g.restrict_connections FROM devices d JOIN device_groups g ON g.id=d.device_group_id WHERE d.id=?',
    deviceId,
  )
  if (!group?.restrict_connections) return
  if (peerUser && canAccessDevice(peerUser, deviceId)) return
  const device = one<{ pending_disconnect: string }>('SELECT pending_disconnect FROM devices WHERE id=?', deviceId)
  const pending = new Set(parse<number[]>(device?.pending_disconnect, []))
  pending.add(connId)
  run('UPDATE devices SET pending_disconnect=? WHERE id=?', JSON.stringify([...pending]), deviceId)
  run('UPDATE connections SET blocked=1 WHERE guid=?', guid)
  audit({
    category: 'alarm',
    action: 'blocked',
    deviceId,
    peerId,
    actor: peerUser?.name ?? '',
    summary: peerUser
      ? `${peerUser.name} has no access to ${group.name}; session ended`
      : `${peerId} is not signed in to an account with access to ${group.name}; session ended`,
  })
}

export const describeConnType = (type: number | null) => (type === null ? '' : connTypes[type] ?? `Type ${type}`)
export const describeAuth = (kind: number | null) => (kind === null ? '' : authKinds[kind] ?? `Method ${kind}`)

// ---------------------------------------------------------------------------
// GL.iNet KVM book (Access fork)

async function kvms(user: User, method: string, request: Request) {
  if (method === 'GET') return { owner: user.id, items: all<{ data: string }>('SELECT data FROM kvms WHERE owner=? ORDER BY id', user.id).map((r) => parse(r.data, {})) }
  const body = await readJson(request)
  if (method === 'DELETE') {
    run('DELETE FROM kvms WHERE owner=? AND id=?', user.id, text(body?.id, 'ID'))
    return undefined
  }
  if (method !== 'POST' && method !== 'PUT') throw new ApiError(404, 'Endpoint not found.')
  const data = cleanKvm(body)
  const old = one<{ data: string }>('SELECT data FROM kvms WHERE owner=? AND id=?', user.id, data.id)
  if (method === 'PUT' && !old) throw new ApiError(404, 'KVM not found.')
  if (method === 'POST' && old) throw new ApiError(409, 'KVM already exists.')
  if (!old && (one<{ n: number }>('SELECT count(*) AS n FROM kvms WHERE owner=?', user.id)?.n ?? 0) >= MAX_PEERS) throw new ApiError(409, 'Address book is full.')
  if (old && parse<{ address?: string }>(old.data, {}).address !== data.address) data.certificateSha256 = null
  run('INSERT INTO kvms VALUES (?,?,?) ON CONFLICT(owner, id) DO UPDATE SET data=excluded.data', user.id, data.id, JSON.stringify(data))
  return data
}

function cleanKvm(body: any) {
  const allowed = new Set(['id', 'name', 'address', 'model', 'username', 'certificateSha256'])
  if (!body || typeof body !== 'object' || Object.keys(body).some((k) => !allowed.has(k)))
    throw new ApiError(400, 'Send KVM connection details only, without passwords.')
  const data: Record<string, string | null> = {}
  for (const key of ['id', 'name', 'address', 'model', 'username']) data[key] = text(body[key], key)
  let uri: URL
  try {
    uri = new URL(data.address!)
  } catch {
    throw new ApiError(400, 'Enter an HTTP or HTTPS KVM address without a path or credentials.')
  }
  if (!['http:', 'https:'].includes(uri.protocol) || uri.username || uri.password || (uri.pathname !== '/' && uri.pathname !== '') || uri.search || uri.hash || /\s/.test(data.address!))
    throw new ApiError(400, 'Enter an HTTP or HTTPS KVM address without a path or credentials.')
  if (!['RMQ1', 'RM4PE'].includes(data.model!)) throw new ApiError(400, 'Choose Comet Q or Comet X.')
  const pin = body.certificateSha256
  if (pin !== undefined && pin !== null && (typeof pin !== 'string' || !/^[0-9a-f]{64}$/.test(pin))) throw new ApiError(400, 'Invalid certificate fingerprint.')
  data.certificateSha256 = pin ?? null
  return data as { id: string; address: string; certificateSha256: string | null }
}
