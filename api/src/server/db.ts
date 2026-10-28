import { Database } from 'bun:sqlite'
import { chmodSync, mkdirSync } from 'node:fs'
import { dirname } from 'node:path'
import { schema } from './schema'

type Row = Record<string, unknown>
type Param = string | number | bigint | boolean | null | Uint8Array

let instance: Database | undefined

export function db(): Database {
  if (instance) return instance
  const file = process.env.RD_DATABASE ?? 'data/rd.sqlite3'
  if (file !== ':memory:') mkdirSync(dirname(file), { recursive: true, mode: 0o700 })
  const database = new Database(file, { create: true, strict: true })
  database.exec('PRAGMA busy_timeout=5000;')
  database.exec(schema)
  migrate(database)
  if (file !== ':memory:') {
    try {
      chmodSync(file, 0o600)
    } catch {}
  }
  instance = database
  return database
}

/** Columns added after a table first shipped; CREATE TABLE IF NOT EXISTS won't add them. */
const added: [table: string, column: string, definition: string][] = [['users', 'sso_subject', 'TEXT']]

function migrate(database: Database) {
  for (const [table, column, definition] of added) {
    const columns = database.query(`PRAGMA table_info(${table})`).all() as { name: string }[]
    if (!columns.some((c) => c.name === column)) database.exec(`ALTER TABLE ${table} ADD COLUMN ${column} ${definition}`)
  }
  database.exec('CREATE UNIQUE INDEX IF NOT EXISTS users_sso_subject ON users (sso_subject) WHERE sso_subject IS NOT NULL')
}

export function all<T = Row>(sql: string, ...params: Param[]): T[] {
  return db().query(sql).all(...params) as T[]
}

export function one<T = Row>(sql: string, ...params: Param[]): T | undefined {
  return (db().query(sql).get(...params) ?? undefined) as T | undefined
}

export function run(sql: string, ...params: Param[]) {
  return db().query(sql).run(...params)
}

export function transaction<T>(body: () => T): T {
  return db().transaction(body)()
}

export function now(): number {
  return Math.floor(Date.now() / 1000)
}

export function getSetting(key: string, fallback: string): string {
  return one<{ value: string }>('SELECT value FROM settings WHERE key=?', key)?.value ?? fallback
}

export function setSetting(key: string, value: string) {
  run('INSERT INTO settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', key, value)
}

export function parse<T>(value: unknown, fallback: T): T {
  if (typeof value !== 'string') return fallback
  try {
    return JSON.parse(value) as T
  } catch {
    return fallback
  }
}
