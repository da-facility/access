import { createHash, pbkdf2Sync, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { ApiError, text } from './http'
import { now, one, run } from './db'

export type User = {
  id: string
  name: string
  display_name: string
  email: string
  note: string
  salt: string
  password: string
  is_admin: number
  status: number
  created_at: number
  last_login_at: number | null
  sso_subject: string | null
}

// Same parameters as the original Python server so hashes stay portable.
export function passwordHash(password: string, salt: string) {
  return pbkdf2Sync(password, Buffer.from(salt, 'hex'), 600_000, 32, 'sha256').toString('hex')
}

export function checkPassword(user: User | undefined, password: string) {
  const candidate = Buffer.from(passwordHash(password, user?.salt ?? '00'.repeat(16)), 'hex')
  return !!user && timingSafeEqual(candidate, Buffer.from(user.password, 'hex'))
}

export const digest = (token: string) => createHash('sha256').update(token).digest('hex')
export const newToken = () => randomBytes(32).toString('base64url')

export function validUsername(value: unknown) {
  const name = text(value, 'username', 64).toLowerCase()
  if (!/^[a-z0-9_.-]{3,64}$/.test(name)) throw new ApiError(400, 'Use 3–64 letters, numbers, dots, underscores or hyphens for the username.')
  return name
}

export function validPassword(value: unknown) {
  if (typeof value !== 'string' || value.length < 12 || value.length > 256) throw new ApiError(400, 'Use a password between 12 and 256 characters.')
  return value
}

export function createUser(input: { name: unknown; password: unknown; displayName?: string; email?: string; note?: string; isAdmin?: boolean }) {
  const name = validUsername(input.name)
  const password = validPassword(input.password)
  if (one('SELECT 1 FROM users WHERE name=?', name)) throw new ApiError(409, 'That username is already in use.')
  const salt = randomBytes(16).toString('hex')
  const id = randomUUID()
  run(
    'INSERT INTO users (id, name, display_name, email, note, salt, password, is_admin, status, created_at) VALUES (?,?,?,?,?,?,?,?,1,?)',
    id,
    name,
    input.displayName ?? '',
    input.email ?? '',
    input.note ?? '',
    salt,
    passwordHash(password, salt),
    input.isAdmin ? 1 : 0,
    now(),
  )
  return id
}

export function setPassword(userId: string, password: unknown) {
  const salt = randomBytes(16).toString('hex')
  run('UPDATE users SET salt=?, password=? WHERE id=?', salt, passwordHash(validPassword(password), salt), userId)
  run('DELETE FROM sessions WHERE owner=?', userId)
}

export function userPayload(user: User) {
  return {
    name: user.name,
    display_name: user.display_name || user.name,
    email: user.email,
    note: user.note,
    status: user.status,
    is_admin: !!user.is_admin,
    info: {},
  }
}
