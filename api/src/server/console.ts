/** Operations behind the admin console. Every call is made by a signed-in SSO admin. */
import { randomUUID } from 'node:crypto'
import QRCode from 'qrcode'
import { policyCatalog } from '../policy-catalog'
import { createUser, setPassword, validUsername, type User } from './accounts'
import { audit } from './audit'
import { all, getSetting, now, one, parse, run, setSetting, transaction } from './db'
import { ApiError, optionalText, text } from './http'
import type { ConsoleUser } from './oidc'
import { effectivePolicy, resolve, stamp, type Strategy } from './policy'
import { alarmText, describeAuth, describeConnType, personalBook } from './rustdesk'

const ONLINE_SECONDS = 60

type Ctx = { admin: ConsoleUser; ip: string }
const log = (ctx: Ctx, summary: string, data?: unknown, deviceId?: string) =>
  audit({ category: 'console', action: 'change', actor: ctx.admin.email || ctx.admin.name, ip: ctx.ip, summary, data, deviceId })

const id = (value: unknown, name = 'id') => text(value, name, 128)
const maybeId = (value: unknown) => (value === null || value === undefined || value === '' ? null : id(value))
const bool = (value: unknown) => (value ? 1 : 0)

// ---------------------------------------------------------------------------

function serverInfo() {
  return {
    idServer: process.env.RD_ID_SERVER ?? 'rd.dafacility.io',
    relayServer: process.env.RD_RELAY_SERVER ?? 'rd.dafacility.io',
    apiServer: (process.env.RD_PUBLIC_URL ?? 'https://rd.dafacility.io').replace(/\/$/, ''),
    key: process.env.RD_KEY ?? '',
  }
}

/**
 * The settings as RustDesk's share string: base64url of the JSON, reversed
 * (ServerConfig.encode in the Flutter client). The client's paste button
 * takes it as-is; its QR scanner wants it prefixed with "config=".
 */
export function shareString(info: ReturnType<typeof serverInfo>) {
  const json = JSON.stringify({ host: info.idServer, relay: info.relayServer, api: info.apiServer, key: info.key })
  return Buffer.from(json).toString('base64url').padEnd(Math.ceil(Buffer.byteLength(json) / 3) * 4, '=').split('').reverse().join('')
}

async function overview() {
  const t = now()
  const server = serverInfo()
  const share = shareString(server)
  const count = (sql: string, ...p: (string | number)[]) => one<{ n: number }>(sql, ...p)?.n ?? 0
  return {
    server,
    share,
    qr: await QRCode.toString('config=' + share, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' }),
    registration: getSetting('registration', 'off') === 'on',
    counts: {
      devices: count('SELECT count(*) AS n FROM devices'),
      online: count('SELECT count(*) AS n FROM devices WHERE last_seen > ?', t - ONLINE_SECONDS),
      users: count('SELECT count(*) AS n FROM users'),
      activeSessions: count('SELECT count(*) AS n FROM connections WHERE ended_at IS NULL AND started_at > ?', t - 86400),
      alarms24h: count("SELECT count(*) AS n FROM audit WHERE category='alarm' AND at > ?", t - 86400),
      policies: count('SELECT count(*) AS n FROM strategies'),
    },
    recentConnections: connections({ limit: 8 }).items,
    recentEvents: events({ limit: 8 }).items,
  }
}

// ---------------------------------------------------------------------------
// Devices

export type DeviceListItem = {
  id: string
  hostname: string
  alias: string
  username: string
  os: string
  version: string
  ip: string
  online: boolean
  lastSeen: number
  firstSeen: number
  ownerId: string | null
  ownerName: string | null
  groupId: string | null
  groupName: string | null
  strategyId: string | null
  disabled: boolean
  activeConns: number
  policyName: string | null
  policySource: string
  policyInSync: boolean
}

function deviceList(): DeviceListItem[] {
  const t = now()
  return all<any>(
    `SELECT d.*, u.name AS owner_name, g.name AS group_name FROM devices d
     LEFT JOIN users u ON u.id=d.owner LEFT JOIN device_groups g ON g.id=d.device_group_id ORDER BY d.last_seen DESC`,
  ).map((d) => {
    const policy = resolve(d.strategy_id, d.device_group_id)
    return {
      id: d.id,
      hostname: d.hostname,
      alias: d.alias,
      username: d.username,
      os: d.os,
      version: d.version,
      ip: d.ip,
      online: t - d.last_seen < ONLINE_SECONDS,
      lastSeen: d.last_seen,
      firstSeen: d.first_seen,
      ownerId: d.owner,
      ownerName: d.owner_name,
      groupId: d.device_group_id,
      groupName: d.group_name,
      strategyId: d.strategy_id,
      disabled: !!d.disabled,
      activeConns: parse<number[]>(d.conns, []).length,
      policyName: policy.source.strategy?.name ?? null,
      policySource: policy.source.kind,
      policyInSync: stamp(policy.options) === d.reported_policy,
    }
  })
}

function deviceGet(input: { id: string }) {
  const device = one<any>('SELECT * FROM devices WHERE id=?', id(input.id))
  if (!device) throw new ApiError(404, 'Device not found.')
  const item = deviceList().find((d) => d.id === device.id)!
  const policy = effectivePolicy(device.id)
  return {
    ...item,
    note: device.note,
    uuid: device.uuid,
    sysinfo: parse<Record<string, string>>(device.sysinfo, {}),
    conns: parse<number[]>(device.conns, []),
    reportedPolicy: device.reported_policy,
    pushedKeys: parse<string[]>(device.pushed_keys, []),
    policy: { options: policy.options, source: policy.source, version: stamp(policy.options) },
    signedIn: all<{ name: string; last_used_at: number }>(
      'SELECT users.name, sessions.last_used_at FROM sessions JOIN users ON users.id=sessions.owner WHERE sessions.device_id=? AND sessions.expires>? ORDER BY sessions.last_used_at DESC',
      device.id,
      now(),
    ),
    connections: connections({ deviceId: device.id, limit: 25 }).items,
    events: events({ deviceId: device.id, limit: 25 }).items,
  }
}

function deviceUpdate(ctx: Ctx, input: { id: string; alias?: string; note?: string; ownerId?: string | null; groupId?: string | null; strategyId?: string | null; disabled?: boolean }) {
  const deviceId = id(input.id)
  if (!one('SELECT 1 FROM devices WHERE id=?', deviceId)) throw new ApiError(404, 'Device not found.')
  const changes: string[] = []
  if (input.alias !== undefined) {
    run('UPDATE devices SET alias=? WHERE id=?', optionalText(input.alias, 'alias', 128), deviceId)
    changes.push('alias')
  }
  if (input.note !== undefined) {
    run('UPDATE devices SET note=? WHERE id=?', optionalText(input.note, 'note', 2000), deviceId)
    changes.push('note')
  }
  if (input.ownerId !== undefined) {
    run('UPDATE devices SET owner=? WHERE id=?', maybeId(input.ownerId), deviceId)
    changes.push('owner')
  }
  if (input.groupId !== undefined) {
    run('UPDATE devices SET device_group_id=? WHERE id=?', maybeId(input.groupId), deviceId)
    changes.push('group')
  }
  if (input.strategyId !== undefined) {
    run('UPDATE devices SET strategy_id=? WHERE id=?', maybeId(input.strategyId), deviceId)
    changes.push('policy')
  }
  if (input.disabled !== undefined) {
    run('UPDATE devices SET disabled=? WHERE id=?', bool(input.disabled), deviceId)
    changes.push(input.disabled ? 'blocked incoming sessions' : 'allowed incoming sessions')
  }
  log(ctx, `Updated device ${deviceId}: ${changes.join(', ')}`, input, deviceId)
}

function deviceForget(ctx: Ctx, input: { id: string }) {
  const deviceId = id(input.id)
  run('DELETE FROM devices WHERE id=?', deviceId)
  log(ctx, `Removed device ${deviceId}; it re-registers on its next check-in`, undefined, deviceId)
}

function deviceDisconnect(ctx: Ctx, input: { id: string; connId: number }) {
  const deviceId = id(input.id)
  const device = one<{ pending_disconnect: string }>('SELECT pending_disconnect FROM devices WHERE id=?', deviceId)
  if (!device) throw new ApiError(404, 'Device not found.')
  if (!Number.isInteger(input.connId)) throw new ApiError(400, 'Invalid connection.')
  const pending = new Set(parse<number[]>(device.pending_disconnect, []))
  pending.add(input.connId)
  run('UPDATE devices SET pending_disconnect=? WHERE id=?', JSON.stringify([...pending]), deviceId)
  log(ctx, `Ended session ${input.connId} on ${deviceId}`, undefined, deviceId)
}

// ---------------------------------------------------------------------------
// Users

function userList() {
  return all<User & { devices: number; groups: string | null; sessions: number }>(
    `SELECT u.*, (SELECT count(*) FROM devices d WHERE d.owner=u.id) AS devices,
       (SELECT group_concat(g.name, ', ') FROM user_group_members m JOIN user_groups g ON g.id=m.group_id WHERE m.user_id=u.id) AS groups,
       (SELECT count(*) FROM sessions s WHERE s.owner=u.id AND s.expires>?) AS sessions
     FROM users u ORDER BY u.name`,
    now(),
  ).map((u) => ({
    id: u.id,
    name: u.name,
    displayName: u.display_name,
    email: u.email,
    note: u.note,
    isAdmin: !!u.is_admin,
    sso: !!u.sso_subject,
    active: u.status === 1,
    createdAt: u.created_at,
    lastLoginAt: u.last_login_at,
    devices: u.devices,
    groups: u.groups ?? '',
    groupIds: all<{ group_id: string }>('SELECT group_id FROM user_group_members WHERE user_id=?', u.id).map((r) => r.group_id),
    sessions: u.sessions,
  }))
}

function userCreate(ctx: Ctx, input: { name: string; password: string; displayName?: string; email?: string; note?: string; isAdmin?: boolean; groupIds?: string[] }) {
  const userId = createUser({
    name: input.name,
    password: input.password,
    displayName: optionalText(input.displayName, 'display name', 128),
    email: optionalText(input.email, 'email', 256),
    note: optionalText(input.note, 'note', 2000),
    isAdmin: !!input.isAdmin,
  })
  setMemberships(userId, input.groupIds ?? [])
  personalBook({ id: userId })
  log(ctx, `Created user ${validUsername(input.name)}`)
  return { id: userId }
}

function setMemberships(userId: string, groupIds: string[]) {
  run('DELETE FROM user_group_members WHERE user_id=?', userId)
  for (const g of groupIds) run('INSERT OR IGNORE INTO user_group_members VALUES (?,?)', id(g), userId)
}

function userUpdate(ctx: Ctx, input: { id: string; displayName?: string; email?: string; note?: string; isAdmin?: boolean; active?: boolean; groupIds?: string[] }) {
  const user = one<User>('SELECT * FROM users WHERE id=?', id(input.id))
  if (!user) throw new ApiError(404, 'User not found.')
  transaction(() => {
    if (input.displayName !== undefined) run('UPDATE users SET display_name=? WHERE id=?', optionalText(input.displayName, 'display name', 128), user.id)
    if (input.email !== undefined) run('UPDATE users SET email=? WHERE id=?', optionalText(input.email, 'email', 256), user.id)
    if (input.note !== undefined) run('UPDATE users SET note=? WHERE id=?', optionalText(input.note, 'note', 2000), user.id)
    if (input.isAdmin !== undefined) run('UPDATE users SET is_admin=? WHERE id=?', bool(input.isAdmin), user.id)
    if (input.active !== undefined) {
      run('UPDATE users SET status=? WHERE id=?', input.active ? 1 : 0, user.id)
      if (!input.active) run('DELETE FROM sessions WHERE owner=?', user.id)
    }
    if (input.groupIds !== undefined) setMemberships(user.id, input.groupIds)
  })
  log(ctx, `Updated user ${user.name}`, { ...input, id: undefined })
}

function userPassword(ctx: Ctx, input: { id: string; password: string }) {
  const user = one<User>('SELECT * FROM users WHERE id=?', id(input.id))
  if (!user) throw new ApiError(404, 'User not found.')
  setPassword(user.id, input.password)
  log(ctx, `Reset the password of ${user.name} and signed them out everywhere`)
}

function userSignOut(ctx: Ctx, input: { id: string }) {
  const user = one<User>('SELECT * FROM users WHERE id=?', id(input.id))
  if (!user) throw new ApiError(404, 'User not found.')
  run('DELETE FROM sessions WHERE owner=?', user.id)
  log(ctx, `Signed ${user.name} out of every RustDesk client`)
}

function userDelete(ctx: Ctx, input: { id: string }) {
  const user = one<User>('SELECT * FROM users WHERE id=?', id(input.id))
  if (!user) throw new ApiError(404, 'User not found.')
  transaction(() => {
    run("DELETE FROM device_group_grants WHERE subject_type='user' AND subject_id=?", user.id)
    run("DELETE FROM address_book_rules WHERE subject_type='user' AND subject_id=?", user.id)
    run('DELETE FROM users WHERE id=?', user.id)
  })
  log(ctx, `Deleted user ${user.name}`)
}

// ---------------------------------------------------------------------------
// Groups and access

type Subject = { type: 'user' | 'group'; id: string }

function accessData() {
  const userGroups = all<{ id: string; name: string; note: string }>('SELECT id, name, note FROM user_groups ORDER BY name').map((g) => ({
    ...g,
    memberIds: all<{ user_id: string }>('SELECT user_id FROM user_group_members WHERE group_id=?', g.id).map((r) => r.user_id),
  }))
  const deviceGroups = all<{ id: string; name: string; note: string; strategy_id: string | null; restrict_connections: number }>(
    'SELECT id, name, note, strategy_id, restrict_connections FROM device_groups ORDER BY name',
  ).map((g) => ({
    id: g.id,
    name: g.name,
    note: g.note,
    strategyId: g.strategy_id,
    restrict: !!g.restrict_connections,
    devices: one<{ n: number }>('SELECT count(*) AS n FROM devices WHERE device_group_id=?', g.id)?.n ?? 0,
    grants: all<{ subject_type: 'user' | 'group'; subject_id: string }>('SELECT subject_type, subject_id FROM device_group_grants WHERE device_group_id=?', g.id).map(
      (r) => ({ type: r.subject_type, id: r.subject_id }),
    ),
  }))
  return {
    userGroups,
    deviceGroups,
    users: all<{ id: string; name: string }>('SELECT id, name FROM users ORDER BY name'),
    strategies: all<{ id: string; name: string }>('SELECT id, name FROM strategies ORDER BY name'),
  }
}

function userGroupSave(ctx: Ctx, input: { id?: string; name: string; note?: string; memberIds?: string[] }) {
  const name = text(input.name, 'name', 64)
  const groupId = input.id ? id(input.id) : randomUUID()
  transaction(() => {
    if (one('SELECT 1 FROM user_groups WHERE name=? AND id<>?', name, groupId)) throw new ApiError(409, 'A group with that name exists.')
    run(
      'INSERT INTO user_groups (id, name, note, created_at) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, note=excluded.note',
      groupId,
      name,
      optionalText(input.note, 'note', 2000),
      now(),
    )
    if (input.memberIds) {
      run('DELETE FROM user_group_members WHERE group_id=?', groupId)
      for (const u of input.memberIds) run('INSERT OR IGNORE INTO user_group_members VALUES (?,?)', groupId, id(u))
    }
  })
  log(ctx, `${input.id ? 'Updated' : 'Created'} user group ${name}`)
  return { id: groupId }
}

function userGroupDelete(ctx: Ctx, input: { id: string }) {
  const group = one<{ name: string }>('SELECT name FROM user_groups WHERE id=?', id(input.id))
  if (!group) throw new ApiError(404, 'Group not found.')
  transaction(() => {
    run("DELETE FROM device_group_grants WHERE subject_type='group' AND subject_id=?", input.id)
    run("DELETE FROM address_book_rules WHERE subject_type='group' AND subject_id=?", input.id)
    run('DELETE FROM user_groups WHERE id=?', input.id)
  })
  log(ctx, `Deleted user group ${group.name}`)
}

function deviceGroupSave(ctx: Ctx, input: { id?: string; name: string; note?: string; strategyId?: string | null; restrict?: boolean; grants?: Subject[] }) {
  const name = text(input.name, 'name', 64)
  const groupId = input.id ? id(input.id) : randomUUID()
  transaction(() => {
    if (one('SELECT 1 FROM device_groups WHERE name=? AND id<>?', name, groupId)) throw new ApiError(409, 'A device group with that name exists.')
    run(
      `INSERT INTO device_groups (id, name, note, strategy_id, restrict_connections, created_at) VALUES (?,?,?,?,?,?)
       ON CONFLICT(id) DO UPDATE SET name=excluded.name, note=excluded.note, strategy_id=excluded.strategy_id, restrict_connections=excluded.restrict_connections`,
      groupId,
      name,
      optionalText(input.note, 'note', 2000),
      maybeId(input.strategyId),
      bool(input.restrict),
      now(),
    )
    if (input.grants) {
      run('DELETE FROM device_group_grants WHERE device_group_id=?', groupId)
      for (const g of input.grants) {
        if (g.type !== 'user' && g.type !== 'group') throw new ApiError(400, 'Invalid grant.')
        run('INSERT OR IGNORE INTO device_group_grants VALUES (?,?,?)', groupId, g.type, id(g.id))
      }
    }
  })
  log(ctx, `${input.id ? 'Updated' : 'Created'} device group ${name}`, { restrict: !!input.restrict, grants: input.grants?.length })
  return { id: groupId }
}

function deviceGroupDelete(ctx: Ctx, input: { id: string }) {
  const group = one<{ name: string }>('SELECT name FROM device_groups WHERE id=?', id(input.id))
  if (!group) throw new ApiError(404, 'Device group not found.')
  run('DELETE FROM device_groups WHERE id=?', input.id)
  log(ctx, `Deleted device group ${group.name}`)
}

// ---------------------------------------------------------------------------
// Address books

type BookSubject = { type: 'user' | 'group' | 'everyone'; id: string; rule: number }

function books() {
  const shared = all<{ id: string; name: string; note: string; created_at: number }>("SELECT id, name, note, created_at FROM address_books WHERE kind='shared' ORDER BY name").map(
    (b) => ({
      ...b,
      peers: one<{ n: number }>('SELECT count(*) AS n FROM peers WHERE book_id=?', b.id)?.n ?? 0,
      rules: all<{ subject_type: BookSubject['type']; subject_id: string; rule: number }>(
        'SELECT subject_type, subject_id, rule FROM address_book_rules WHERE book_id=?',
        b.id,
      ).map((r) => ({ type: r.subject_type, id: r.subject_id, rule: r.rule })),
    }),
  )
  const personal = all<{ id: string; owner_name: string; peers: number }>(
    `SELECT b.id, u.name AS owner_name, (SELECT count(*) FROM peers p WHERE p.book_id=b.id) AS peers
     FROM address_books b JOIN users u ON u.id=b.owner WHERE b.kind='personal' ORDER BY u.name`,
  )
  return {
    shared,
    personal,
    users: all<{ id: string; name: string }>('SELECT id, name FROM users ORDER BY name'),
    groups: all<{ id: string; name: string }>('SELECT id, name FROM user_groups ORDER BY name'),
  }
}

function bookPeers(input: { id: string }) {
  return all<{ data: string }>('SELECT data FROM peers WHERE book_id=? ORDER BY id', id(input.id)).map((r) => {
    const p = parse<Record<string, unknown>>(r.data, {})
    // Never show stored passwords or hashes in the console.
    return { id: String(p.id ?? ''), alias: String(p.alias ?? ''), hostname: String(p.hostname ?? ''), platform: String(p.platform ?? ''), note: String(p.note ?? ''), tags: (p.tags as string[]) ?? [], hasPassword: !!(p.password || p.hash) }
  })
}

function bookSave(ctx: Ctx, input: { id?: string; name: string; note?: string; rules?: BookSubject[] }) {
  const name = text(input.name, 'name', 64)
  const bookId = input.id ? id(input.id) : randomUUID()
  transaction(() => {
    if (input.id && !one("SELECT 1 FROM address_books WHERE id=? AND kind='shared'", bookId)) throw new ApiError(404, 'Address book not found.')
    run(
      `INSERT INTO address_books (id, kind, name, owner, note, created_at) VALUES (?, 'shared', ?, NULL, ?, ?)
       ON CONFLICT(id) DO UPDATE SET name=excluded.name, note=excluded.note`,
      bookId,
      name,
      optionalText(input.note, 'note', 2000),
      now(),
    )
    if (input.rules) {
      run('DELETE FROM address_book_rules WHERE book_id=?', bookId)
      for (const r of input.rules) {
        if (!['user', 'group', 'everyone'].includes(r.type) || ![1, 2, 3].includes(r.rule)) throw new ApiError(400, 'Invalid rule.')
        run('INSERT OR REPLACE INTO address_book_rules VALUES (?,?,?,?)', bookId, r.type, r.type === 'everyone' ? '' : id(r.id), r.rule)
      }
    }
  })
  log(ctx, `${input.id ? 'Updated' : 'Created'} shared address book ${name}`)
  return { id: bookId }
}

function bookDelete(ctx: Ctx, input: { id: string }) {
  const book = one<{ name: string }>("SELECT name FROM address_books WHERE id=? AND kind='shared'", id(input.id))
  if (!book) throw new ApiError(404, 'Address book not found.')
  run('DELETE FROM address_books WHERE id=?', input.id)
  log(ctx, `Deleted shared address book ${book.name}`)
}

// ---------------------------------------------------------------------------
// Policies

function policies() {
  const strategies = all<Strategy>('SELECT * FROM strategies ORDER BY is_default DESC, name').map((s) => ({
    id: s.id,
    name: s.name,
    note: s.note,
    isDefault: !!s.is_default,
    options: parse<Record<string, string>>(s.options, {}),
    updatedAt: s.updated_at,
    devices: one<{ n: number }>('SELECT count(*) AS n FROM devices WHERE strategy_id=?', s.id)?.n ?? 0,
    groups: all<{ name: string }>('SELECT name FROM device_groups WHERE strategy_id=?', s.id).map((g) => g.name),
  }))
  const devices = deviceList().map((d) => ({ id: d.id, name: d.alias || d.hostname || d.id, online: d.online, policyName: d.policyName, policySource: d.policySource, policyInSync: d.policyInSync }))
  return { strategies, devices }
}

function devicePolicy(input: { id: string }) {
  const device = one<{ id: string; reported_policy: number; pushed_keys: string; hostname: string; alias: string }>(
    'SELECT id, reported_policy, pushed_keys, hostname, alias FROM devices WHERE id=?',
    id(input.id),
  )
  if (!device) throw new ApiError(404, 'Device not found.')
  const policy = effectivePolicy(device.id)
  const version = stamp(policy.options)
  return {
    id: device.id,
    name: device.alias || device.hostname || device.id,
    options: policy.options,
    source: policy.source,
    inSync: version === device.reported_policy,
    version,
    reportedVersion: device.reported_policy,
  }
}

const knownKeys = new Set(policyCatalog.map((o) => o.key))

function cleanOptions(options: unknown) {
  if (!options || typeof options !== 'object' || Array.isArray(options)) throw new ApiError(400, 'Invalid options.')
  const result: Record<string, string> = {}
  for (const [key, value] of Object.entries(options)) {
    if (!/^[a-z0-9-]{1,64}$/.test(key)) throw new ApiError(400, `Invalid option key ${key}.`)
    if (typeof value !== 'string' || value.length > 2000) throw new ApiError(400, `Invalid value for ${key}.`)
    result[key] = value
  }
  return result
}

function policySave(ctx: Ctx, input: { id?: string; name: string; note?: string; options: Record<string, string> }) {
  const name = text(input.name, 'name', 64)
  const options = cleanOptions(input.options)
  const policyId = input.id ? id(input.id) : randomUUID()
  if (one('SELECT 1 FROM strategies WHERE name=? AND id<>?', name, policyId)) throw new ApiError(409, 'A policy with that name exists.')
  run(
    `INSERT INTO strategies (id, name, note, options, is_default, created_at, updated_at) VALUES (?,?,?,?,0,?,?)
     ON CONFLICT(id) DO UPDATE SET name=excluded.name, note=excluded.note, options=excluded.options, updated_at=excluded.updated_at`,
    policyId,
    name,
    optionalText(input.note, 'note', 2000),
    JSON.stringify(options),
    now(),
    now(),
  )
  const custom = Object.keys(options).filter((k) => !knownKeys.has(k))
  log(ctx, `${input.id ? 'Updated' : 'Created'} policy ${name}`, { options, custom })
  return { id: policyId }
}

function policyDefault(ctx: Ctx, input: { id: string | null }) {
  const policyId = maybeId(input.id)
  transaction(() => {
    run('UPDATE strategies SET is_default=0')
    if (policyId) run('UPDATE strategies SET is_default=1 WHERE id=?', policyId)
  })
  const name = policyId ? one<{ name: string }>('SELECT name FROM strategies WHERE id=?', policyId)?.name : null
  log(ctx, name ? `Made ${name} the default policy` : 'Cleared the default policy')
}

function policyDelete(ctx: Ctx, input: { id: string }) {
  const policy = one<{ name: string }>('SELECT name FROM strategies WHERE id=?', id(input.id))
  if (!policy) throw new ApiError(404, 'Policy not found.')
  run('DELETE FROM strategies WHERE id=?', input.id)
  log(ctx, `Deleted policy ${policy.name}`)
}

// ---------------------------------------------------------------------------
// Audit

export type ConnectionItem = {
  guid: string
  deviceId: string
  deviceName: string
  connId: number
  ip: string
  peerId: string
  peerName: string
  peerUser: string
  type: string
  auth: string
  twoFactor: boolean
  startedAt: number
  authorizedAt: number | null
  endedAt: number | null
  note: string
  blocked: boolean
  live: boolean
}

function connections(input: { deviceId?: string; search?: string; limit?: number; offset?: number }) {
  const where: string[] = []
  const params: (string | number)[] = []
  if (input.deviceId) {
    where.push('(c.device_id=? OR c.peer_id=?)')
    params.push(input.deviceId, input.deviceId)
  }
  if (input.search) {
    where.push('(c.device_id LIKE ? OR c.peer_id LIKE ? OR c.peer_name LIKE ? OR c.peer_user LIKE ? OR c.ip LIKE ? OR d.hostname LIKE ?)')
    const like = `%${input.search}%`
    params.push(like, like, like, like, like, like)
  }
  const clause = where.length ? 'WHERE ' + where.join(' AND ') : ''
  const limit = Math.min(200, Math.max(1, input.limit ?? 50))
  const offset = Math.max(0, input.offset ?? 0)
  const total = one<{ n: number }>(`SELECT count(*) AS n FROM connections c LEFT JOIN devices d ON d.id=c.device_id ${clause}`, ...params)?.n ?? 0
  const items = all<any>(
    `SELECT c.*, d.hostname, d.alias, d.conns, d.last_seen FROM connections c LEFT JOIN devices d ON d.id=c.device_id ${clause} ORDER BY c.started_at DESC LIMIT ? OFFSET ?`,
    ...params,
    limit,
    offset,
  ).map(
    (c): ConnectionItem => ({
      guid: c.guid,
      deviceId: c.device_id,
      deviceName: c.alias || c.hostname || c.device_id,
      connId: c.conn_id,
      ip: c.ip,
      peerId: c.peer_id,
      peerName: c.peer_name,
      peerUser: c.peer_user,
      type: describeConnType(c.type),
      auth: describeAuth(c.primary_auth),
      twoFactor: !!c.two_factor,
      startedAt: c.started_at,
      authorizedAt: c.authorized_at,
      endedAt: c.ended_at,
      note: c.note,
      blocked: !!c.blocked,
      live: !c.ended_at && parse<number[]>(c.conns, []).includes(c.conn_id) && now() - (c.last_seen ?? 0) < ONLINE_SECONDS,
    }),
  )
  return { total, items }
}

export type EventItem = { seq: number; at: number; category: string; action: string; deviceId: string; deviceName: string; peerId: string; actor: string; ip: string; summary: string; data: unknown }

function events(input: { category?: string; deviceId?: string; search?: string; limit?: number; offset?: number }) {
  const where: string[] = []
  const params: (string | number)[] = []
  if (input.category) {
    where.push('a.category=?')
    params.push(input.category)
  }
  if (input.deviceId) {
    where.push('(a.device_id=? OR a.peer_id=?)')
    params.push(input.deviceId, input.deviceId)
  }
  if (input.search) {
    const like = `%${input.search}%`
    where.push('(a.summary LIKE ? OR a.actor LIKE ? OR a.device_id LIKE ? OR a.peer_id LIKE ? OR a.ip LIKE ?)')
    params.push(like, like, like, like, like)
  }
  const clause = where.length ? 'WHERE ' + where.join(' AND ') : ''
  const limit = Math.min(200, Math.max(1, input.limit ?? 50))
  const offset = Math.max(0, input.offset ?? 0)
  const total = one<{ n: number }>(`SELECT count(*) AS n FROM audit a ${clause}`, ...params)?.n ?? 0
  const items = all<any>(
    `SELECT a.*, d.hostname, d.alias FROM audit a LEFT JOIN devices d ON d.id=a.device_id ${clause} ORDER BY a.seq DESC LIMIT ? OFFSET ?`,
    ...params,
    limit,
    offset,
  ).map(
    (a): EventItem => ({
      seq: a.seq,
      at: a.at,
      category: a.category,
      action: a.action,
      deviceId: a.device_id,
      deviceName: a.alias || a.hostname || a.device_id,
      peerId: a.peer_id,
      actor: a.actor,
      ip: a.ip,
      summary: a.category === 'alarm' && /^\d+$/.test(a.action) && !a.summary ? alarmText(a.action) : a.summary,
      data: parse(a.data, {}),
    }),
  )
  return { total, items }
}

function setRegistration(ctx: Ctx, input: { on: boolean }) {
  setSetting('registration', input.on ? 'on' : 'off')
  log(ctx, input.on ? 'Opened self-service sign-up' : 'Closed self-service sign-up')
}

// ---------------------------------------------------------------------------

const operations = {
  overview: () => overview(),
  'settings.registration': (ctx: Ctx, i: { on: boolean }) => setRegistration(ctx, i),
  'devices.list': () => ({ devices: deviceList(), ...accessData() }),
  'devices.get': (_: Ctx, i: { id: string }) => ({ device: deviceGet(i), ...accessData() }),
  'devices.update': (ctx: Ctx, i: Parameters<typeof deviceUpdate>[1]) => deviceUpdate(ctx, i),
  'devices.forget': (ctx: Ctx, i: { id: string }) => deviceForget(ctx, i),
  'devices.disconnect': (ctx: Ctx, i: { id: string; connId: number }) => deviceDisconnect(ctx, i),
  'users.list': () => ({ users: userList(), groups: all<{ id: string; name: string }>('SELECT id, name FROM user_groups ORDER BY name') }),
  'users.create': (ctx: Ctx, i: Parameters<typeof userCreate>[1]) => userCreate(ctx, i),
  'users.update': (ctx: Ctx, i: Parameters<typeof userUpdate>[1]) => userUpdate(ctx, i),
  'users.password': (ctx: Ctx, i: { id: string; password: string }) => userPassword(ctx, i),
  'users.signOut': (ctx: Ctx, i: { id: string }) => userSignOut(ctx, i),
  'users.delete': (ctx: Ctx, i: { id: string }) => userDelete(ctx, i),
  access: () => accessData(),
  'userGroups.save': (ctx: Ctx, i: Parameters<typeof userGroupSave>[1]) => userGroupSave(ctx, i),
  'userGroups.delete': (ctx: Ctx, i: { id: string }) => userGroupDelete(ctx, i),
  'deviceGroups.save': (ctx: Ctx, i: Parameters<typeof deviceGroupSave>[1]) => deviceGroupSave(ctx, i),
  'deviceGroups.delete': (ctx: Ctx, i: { id: string }) => deviceGroupDelete(ctx, i),
  books: () => books(),
  'books.peers': (_: Ctx, i: { id: string }) => bookPeers(i),
  'books.save': (ctx: Ctx, i: Parameters<typeof bookSave>[1]) => bookSave(ctx, i),
  'books.delete': (ctx: Ctx, i: { id: string }) => bookDelete(ctx, i),
  policies: () => policies(),
  'policies.device': (_: Ctx, i: { id: string }) => devicePolicy(i),
  'policies.save': (ctx: Ctx, i: Parameters<typeof policySave>[1]) => policySave(ctx, i),
  'policies.default': (ctx: Ctx, i: { id: string | null }) => policyDefault(ctx, i),
  'policies.delete': (ctx: Ctx, i: { id: string }) => policyDelete(ctx, i),
  'audit.connections': (_: Ctx, i: Parameters<typeof connections>[0]) => connections(i),
  'audit.events': (_: Ctx, i: Parameters<typeof events>[0]) => events(i),
} satisfies Record<string, (ctx: Ctx, input: any) => unknown>

export type Operations = typeof operations
export type OperationName = keyof Operations

export function perform(ctx: Ctx, name: string, input: unknown) {
  const operation = (operations as Record<string, (ctx: Ctx, input: any) => unknown>)[name]
  if (!operation) throw new ApiError(404, 'Unknown operation.')
  return operation(ctx, input ?? {})
}
