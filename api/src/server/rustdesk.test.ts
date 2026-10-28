import { beforeAll, describe, expect, test } from 'bun:test'

process.env.RD_DATABASE = ':memory:'
const { handleRustDesk } = await import('./rustdesk')
const { createUser } = await import('./accounts')
const { perform } = await import('./console')
const { one, run } = await import('./db')

const ctx = { admin: { subject: 'admin', name: 'Admin', email: 'admin@example.com' }, ip: '127.0.0.1' }
const base = 'https://rd.test'

async function api(method: string, path: string, body?: unknown, token?: string) {
  const headers: Record<string, string> = { 'content-type': 'application/json', 'x-forwarded-for': '203.0.113.9' }
  if (token) headers.authorization = 'Bearer ' + token
  const response = await handleRustDesk(new Request(base + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) }))
  const text = await response.text()
  let json: any
  try {
    json = text ? JSON.parse(text) : undefined
  } catch {
    json = text
  }
  return { status: response.status, text, json }
}

let token = ''
let peerToken = ''

beforeAll(async () => {
  createUser({ name: 'alice', password: 'correct horse battery' })
  createUser({ name: 'bob', password: 'correct horse battery' })
  token = (await api('POST', '/api/login', { username: 'alice', password: 'correct horse battery', id: '111111111', uuid: 'dXVpZA==' })).json.access_token
  peerToken = (await api('POST', '/api/login', { username: 'bob', password: 'correct horse battery', id: '222222222', uuid: 'cGVlcg==' })).json.access_token
})

describe('accounts', () => {
  test('login returns a token and the user', async () => {
    expect(token).toBeString()
    const me = await api('POST', '/api/currentUser', {}, token)
    expect(me.json).toMatchObject({ name: 'alice', status: 1, is_admin: false, info: {} })
  })
  test('wrong password is refused with a JSON error', async () => {
    const result = await api('POST', '/api/login', { username: 'alice', password: 'nope nope nope' })
    expect(result.status).toBe(401)
    expect(result.json.error).toBeString()
  })
  test('sign-up is closed by default', async () => {
    expect((await api('POST', '/api/access/register', { username: 'carol', password: 'correct horse battery' })).status).toBe(403)
  })
})

describe('address book', () => {
  test('personal book: add, list, tag rename', async () => {
    const { guid } = (await api('POST', '/api/ab/personal', undefined, token)).json
    expect((await api('POST', `/api/ab/peer/add/${guid}`, { id: '999', alias: 'NAS', tags: ['home'], password: 'dropped' }, token)).text).toBe('')
    await api('POST', `/api/ab/tag/add/${guid}`, { name: 'home', color: 1 }, token)
    await api('PUT', `/api/ab/tag/rename/${guid}`, { old: 'home', new: 'house' }, token)
    const peers = (await api('POST', `/api/ab/peers?current=1&pageSize=100&ab=${guid}`, undefined, token)).json
    expect(peers.total).toBe(1)
    expect(peers.data[0]).toEqual({ id: '999', alias: 'NAS', tags: ['house'] })
  })
  test("another user's book is not found", async () => {
    const { guid } = (await api('POST', '/api/ab/personal', undefined, token)).json
    expect((await api('POST', `/api/ab/peers?ab=${guid}`, undefined, peerToken)).status).toBe(404)
  })
  test('shared book with a read rule is read-only', async () => {
    const bob = one<{ id: string }>("SELECT id FROM users WHERE name='bob'")!
    const { id } = perform(ctx, 'books.save', { name: 'Team', rules: [{ type: 'user', id: bob.id, rule: 1 }] }) as { id: string }
    const profiles = (await api('POST', '/api/ab/shared/profiles', undefined, peerToken)).json
    expect(profiles.data).toEqual([expect.objectContaining({ guid: id, name: 'Team', rule: 1 })])
    expect((await api('POST', `/api/ab/peer/add/${id}`, { id: '1' }, peerToken)).status).toBe(403)
  })
})

describe('devices', () => {
  test('unknown device is asked for sysinfo, then registered', async () => {
    expect((await api('POST', '/api/heartbeat', { id: '333333333', uuid: 'ZGV2', ver: 1005000 })).json).toEqual({ sysinfo: true })
    const info = await api('POST', '/api/sysinfo', { id: '333333333', uuid: 'ZGV2', hostname: 'office-pc', os: 'windows / Windows 11', version: '1.4.2', cpu: 'x', memory: '16GB' })
    expect(info.text).toBe('SYSINFO_UPDATED')
    expect(one<{ hostname: string }>("SELECT hostname FROM devices WHERE id='333333333'")?.hostname).toBe('office-pc')
  })
  test('a different machine cannot take over a known ID', async () => {
    await api('POST', '/api/sysinfo', { id: '333333333', uuid: 'b3RoZXI=', hostname: 'evil' })
    expect(one<{ hostname: string }>("SELECT hostname FROM devices WHERE id='333333333'")?.hostname).toBe('office-pc')
  })
  test('policy is pushed until acknowledged, and cleared keys are sent empty', async () => {
    const { id } = perform(ctx, 'policies.save', { name: 'Locked', options: { 'enable-file-transfer': 'N', 'approve-mode': 'password' } }) as { id: string }
    perform(ctx, 'policies.default', { id })
    const first = (await api('POST', '/api/heartbeat', { id: '333333333', uuid: 'ZGV2', modified_at: 0 })).json
    expect(first.strategy.config_options).toEqual({ 'enable-file-transfer': 'N', 'approve-mode': 'password' })
    const version = first.modified_at
    expect(version).toBeGreaterThan(0)
    expect((await api('POST', '/api/heartbeat', { id: '333333333', uuid: 'ZGV2', modified_at: version })).json).toEqual({})
    perform(ctx, 'policies.save', { id, name: 'Locked', options: { 'approve-mode': 'password' } })
    const second = (await api('POST', '/api/heartbeat', { id: '333333333', uuid: 'ZGV2', modified_at: version })).json
    expect(second.strategy.config_options).toEqual({ 'enable-file-transfer': '', 'approve-mode': 'password' })
  })
})

describe('audit and enforcement', () => {
  test('connection records are merged by conn_id and deduplicated by nonce', async () => {
    expect((await api('POST', '/api/audit/conn', { id: '333333333', uuid: 'ZGV2', conn_id: 7, session_id: 0, action: 'new', ip: '198.51.100.4', nonce: 'n1' })).text).toBe('')
    await api('POST', '/api/audit/conn', { id: '333333333', uuid: 'ZGV2', conn_id: 7, session_id: 0, action: 'new', ip: '198.51.100.4', nonce: 'n1' })
    await api('POST', '/api/audit/conn', { id: '333333333', uuid: 'ZGV2', conn_id: 7, session_id: 42, peer: ['111111111', 'alice-mac'], type: 0, primary_auth: 3, nonce: 'n2' })
    await api('POST', '/api/audit/conn', { id: '333333333', uuid: 'ZGV2', conn_id: 7, session_id: 42, action: 'close', nonce: 'n3' })
    const rows = (perform(ctx, 'audit.connections', { deviceId: '333333333' }) as { items: any[] }).items
    expect(rows).toHaveLength(1)
    expect(rows[0]).toMatchObject({ peerId: '111111111', peerUser: 'alice', type: 'Remote control', auth: 'Permanent password' })
    expect(rows[0].endedAt).toBeNumber()
  })
  test('a restricted group ends sessions from people without a grant', async () => {
    const alice = one<{ id: string }>("SELECT id FROM users WHERE name='alice'")!
    const { id: groupId } = perform(ctx, 'deviceGroups.save', { name: 'Servers', restrict: true, grants: [{ type: 'user', id: alice.id }] }) as { id: string }
    run("UPDATE devices SET device_group_id=? WHERE id='333333333'", groupId)
    await api('POST', '/api/audit/conn', { id: '333333333', uuid: 'ZGV2', conn_id: 8, action: 'new', nonce: 'n4' })
    await api('POST', '/api/audit/conn', { id: '333333333', uuid: 'ZGV2', conn_id: 8, session_id: 5, peer: ['222222222', 'bob-pc'], type: 0, nonce: 'n5' })
    const reply = (await api('POST', '/api/heartbeat', { id: '333333333', uuid: 'ZGV2', conns: [8], modified_at: 0 })).json
    expect(reply.disconnect).toEqual([8])
    // Alice is granted; her session stays.
    await api('POST', '/api/audit/conn', { id: '333333333', uuid: 'ZGV2', conn_id: 9, session_id: 6, peer: ['111111111', 'alice-mac'], type: 0, nonce: 'n6' })
    const next = (await api('POST', '/api/heartbeat', { id: '333333333', uuid: 'ZGV2', conns: [9], modified_at: 0 })).json
    expect(next.disconnect).toBeUndefined()
  })
  test('accessible peers follow grants', async () => {
    const forAlice = (await api('GET', '/api/peers?current=1&pageSize=100&accessible=&status=1', undefined, token)).json
    expect(forAlice.data.map((p: any) => p.id)).toEqual(['333333333'])
    const forBob = (await api('GET', '/api/peers?current=1&pageSize=100&accessible=&status=1', undefined, peerToken)).json
    expect(forBob.data).toEqual([])
  })
})
