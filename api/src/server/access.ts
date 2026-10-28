import { all, now, one } from './db'
import type { User } from './accounts'

/** Group ids the user belongs to. */
export function userGroupIds(userId: string) {
  return all<{ group_id: string }>('SELECT group_id FROM user_group_members WHERE user_id=?', userId).map((r) => r.group_id)
}

/** Device groups the user may see, directly or through a user group. */
export function accessibleDeviceGroupIds(user: Pick<User, 'id' | 'is_admin'>): string[] {
  if (user.is_admin) return all<{ id: string }>('SELECT id FROM device_groups').map((r) => r.id)
  return all<{ device_group_id: string }>(
    `SELECT DISTINCT device_group_id FROM device_group_grants
     WHERE (subject_type='user' AND subject_id=?)
        OR (subject_type='group' AND subject_id IN (SELECT group_id FROM user_group_members WHERE user_id=?))`,
    user.id,
    user.id,
  ).map((r) => r.device_group_id)
}

/** Whether a user may reach a device: owner, a grant on its group, or an admin. */
export function canAccessDevice(user: Pick<User, 'id' | 'is_admin'>, deviceId: string) {
  if (user.is_admin) return true
  const device = one<{ owner: string | null; device_group_id: string | null }>('SELECT owner, device_group_id FROM devices WHERE id=?', deviceId)
  if (!device) return false
  if (device.owner === user.id) return true
  return !!device.device_group_id && accessibleDeviceGroupIds(user).includes(device.device_group_id)
}

/** The account signed in on a RustDesk ID, from its most recent live session. */
export function userOnDevice(deviceId: string) {
  return one<User>(
    `SELECT users.* FROM sessions JOIN users ON users.id=sessions.owner
     WHERE sessions.device_id=? AND sessions.expires>? AND users.status=1
     ORDER BY sessions.last_used_at DESC LIMIT 1`,
    deviceId,
    now(),
  )
}

/** A user's rule on an address book: 0 none, 1 read, 2 read/write, 3 full. */
export function bookRule(user: Pick<User, 'id' | 'is_admin'>, bookId: string): number {
  const book = one<{ kind: string; owner: string | null }>('SELECT kind, owner FROM address_books WHERE id=?', bookId)
  if (!book) return 0
  if (book.kind === 'personal') return book.owner === user.id ? 3 : 0
  if (user.is_admin) return 3
  const row = one<{ rule: number | null }>(
    `SELECT MAX(rule) AS rule FROM address_book_rules WHERE book_id=? AND (
       subject_type='everyone'
       OR (subject_type='user' AND subject_id=?)
       OR (subject_type='group' AND subject_id IN (SELECT group_id FROM user_group_members WHERE user_id=?)))`,
    bookId,
    user.id,
    user.id,
  )
  return row?.rule ?? 0
}
