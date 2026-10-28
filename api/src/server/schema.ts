// The database schema, applied on every start; statements must stay idempotent.
export const schema = `
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

-- RustDesk client accounts (people who log in from the RustDesk app).
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT '',
  salt TEXT NOT NULL,
  password TEXT NOT NULL,
  is_admin INTEGER NOT NULL DEFAULT 0,
  status INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  last_login_at INTEGER
);

CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires INTEGER NOT NULL,
  created_at INTEGER NOT NULL DEFAULT 0,
  last_used_at INTEGER NOT NULL DEFAULT 0,
  device_id TEXT NOT NULL DEFAULT '',
  device_uuid TEXT NOT NULL DEFAULT '',
  device_info TEXT NOT NULL DEFAULT '{}',
  ip TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS user_groups (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS user_group_members (
  group_id TEXT NOT NULL REFERENCES user_groups(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  PRIMARY KEY (group_id, user_id)
);

CREATE TABLE IF NOT EXISTS device_groups (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  note TEXT NOT NULL DEFAULT '',
  strategy_id TEXT REFERENCES strategies(id) ON DELETE SET NULL,
  -- Disconnect sessions from people who have no grant to the group.
  restrict_connections INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS strategies (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  note TEXT NOT NULL DEFAULT '',
  options TEXT NOT NULL DEFAULT '{}',
  is_default INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Devices that report in through /api/heartbeat and /api/sysinfo.
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY,
  uuid TEXT NOT NULL DEFAULT '',
  hostname TEXT NOT NULL DEFAULT '',
  username TEXT NOT NULL DEFAULT '',
  os TEXT NOT NULL DEFAULT '',
  version TEXT NOT NULL DEFAULT '',
  sysinfo TEXT NOT NULL DEFAULT '{}',
  alias TEXT NOT NULL DEFAULT '',
  note TEXT NOT NULL DEFAULT '',
  owner TEXT REFERENCES users(id) ON DELETE SET NULL,
  device_group_id TEXT REFERENCES device_groups(id) ON DELETE SET NULL,
  strategy_id TEXT REFERENCES strategies(id) ON DELETE SET NULL,
  disabled INTEGER NOT NULL DEFAULT 0,
  conns TEXT NOT NULL DEFAULT '[]',
  ip TEXT NOT NULL DEFAULT '',
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  sysinfo_at INTEGER NOT NULL DEFAULT 0,
  pending_disconnect TEXT NOT NULL DEFAULT '[]',
  -- Option keys the device last confirmed, so removed ones can be cleared.
  pushed_keys TEXT NOT NULL DEFAULT '[]',
  reported_policy INTEGER NOT NULL DEFAULT 0,
  ver INTEGER NOT NULL DEFAULT 0
);

-- Who may see/reach a device group: a user or a user group.
CREATE TABLE IF NOT EXISTS device_group_grants (
  device_group_id TEXT NOT NULL REFERENCES device_groups(id) ON DELETE CASCADE,
  subject_type TEXT NOT NULL CHECK (subject_type IN ('user', 'group')),
  subject_id TEXT NOT NULL,
  PRIMARY KEY (device_group_id, subject_type, subject_id)
);

-- Address books. Personal books have owner set and kind='personal'.
CREATE TABLE IF NOT EXISTS address_books (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('personal', 'shared')),
  name TEXT NOT NULL,
  owner TEXT REFERENCES users(id) ON DELETE CASCADE,
  note TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);

-- Shared address book rules. rule: 1 = read, 2 = read/write, 3 = full control.
CREATE TABLE IF NOT EXISTS address_book_rules (
  book_id TEXT NOT NULL REFERENCES address_books(id) ON DELETE CASCADE,
  subject_type TEXT NOT NULL CHECK (subject_type IN ('user', 'group', 'everyone')),
  subject_id TEXT NOT NULL DEFAULT '',
  rule INTEGER NOT NULL CHECK (rule BETWEEN 1 AND 3),
  PRIMARY KEY (book_id, subject_type, subject_id)
);

CREATE TABLE IF NOT EXISTS peers (
  book_id TEXT NOT NULL REFERENCES address_books(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  data TEXT NOT NULL,
  PRIMARY KEY (book_id, id)
);

CREATE TABLE IF NOT EXISTS tags (
  book_id TEXT NOT NULL REFERENCES address_books(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  color INTEGER NOT NULL,
  PRIMARY KEY (book_id, name)
);

CREATE TABLE IF NOT EXISTS kvms (
  owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  id TEXT NOT NULL,
  data TEXT NOT NULL,
  PRIMARY KEY (owner, id)
);

CREATE TABLE IF NOT EXISTS attempts (
  source TEXT PRIMARY KEY,
  started INTEGER NOT NULL,
  count INTEGER NOT NULL
);

-- One row per incoming session, reported by the device being controlled.
CREATE TABLE IF NOT EXISTS connections (
  guid TEXT PRIMARY KEY,
  device_id TEXT NOT NULL,
  conn_id INTEGER NOT NULL,
  session_id TEXT NOT NULL DEFAULT '',
  ip TEXT NOT NULL DEFAULT '',
  peer_id TEXT NOT NULL DEFAULT '',
  peer_name TEXT NOT NULL DEFAULT '',
  peer_user TEXT NOT NULL DEFAULT '',
  type INTEGER,
  primary_auth INTEGER,
  two_factor INTEGER,
  started_at INTEGER NOT NULL,
  authorized_at INTEGER,
  ended_at INTEGER,
  note TEXT NOT NULL DEFAULT '',
  blocked INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS connections_device ON connections (device_id, conn_id, started_at DESC);
CREATE INDEX IF NOT EXISTS connections_started ON connections (started_at DESC);

-- Devices retry audit posts; each carries a nonce.
CREATE TABLE IF NOT EXISTS nonces (
  nonce TEXT PRIMARY KEY,
  at INTEGER NOT NULL
);

-- Audit trail. category: file | alarm | login | console | device
CREATE TABLE IF NOT EXISTS audit (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  category TEXT NOT NULL,
  action TEXT NOT NULL DEFAULT '',
  device_id TEXT NOT NULL DEFAULT '',
  peer_id TEXT NOT NULL DEFAULT '',
  actor TEXT NOT NULL DEFAULT '',
  ip TEXT NOT NULL DEFAULT '',
  conn_id TEXT NOT NULL DEFAULT '',
  session_id TEXT NOT NULL DEFAULT '',
  summary TEXT NOT NULL DEFAULT '',
  data TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS audit_category_at ON audit (category, at DESC);
CREATE INDEX IF NOT EXISTS audit_device ON audit (device_id, at DESC);
CREATE INDEX IF NOT EXISTS audit_conn ON audit (device_id, conn_id);

-- Admin console sessions (SSO via Pocket ID).
CREATE TABLE IF NOT EXISTS console_sessions (
  token TEXT PRIMARY KEY,
  subject TEXT NOT NULL,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  expires INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
`
