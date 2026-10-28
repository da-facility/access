import { createHash } from 'node:crypto'
import { one, parse } from './db'

export type Strategy = { id: string; name: string; note: string; options: string; is_default: number; created_at: number; updated_at: number }
export type Source = { kind: 'device' | 'group' | 'default' | 'none'; strategy?: Pick<Strategy, 'id' | 'name'>; groupName?: string }

/** Which policy applies to a device: its own, else its group's, else the default one. */
export function effectivePolicy(deviceId: string): { options: Record<string, string>; source: Source } {
  const device = one<{ strategy_id: string | null; device_group_id: string | null }>('SELECT strategy_id, device_group_id FROM devices WHERE id=?', deviceId)
  return resolve(device?.strategy_id ?? null, device?.device_group_id ?? null)
}

export function resolve(strategyId: string | null, groupId: string | null): { options: Record<string, string>; source: Source } {
  if (strategyId) {
    const strategy = one<Strategy>('SELECT * FROM strategies WHERE id=?', strategyId)
    if (strategy) return { options: parse(strategy.options, {}), source: { kind: 'device', strategy } }
  }
  if (groupId) {
    const group = one<{ name: string; strategy_id: string | null }>('SELECT name, strategy_id FROM device_groups WHERE id=?', groupId)
    const strategy = group?.strategy_id ? one<Strategy>('SELECT * FROM strategies WHERE id=?', group.strategy_id) : undefined
    if (strategy) return { options: parse(strategy.options, {}), source: { kind: 'group', strategy, groupName: group!.name } }
  }
  const fallback = one<Strategy>('SELECT * FROM strategies WHERE is_default=1')
  if (fallback) return { options: parse(fallback.options, {}), source: { kind: 'default', strategy: fallback } }
  return { options: {}, source: { kind: 'none' } }
}

/**
 * What to send a device: the policy's options, plus an empty value for each
 * key it was given before but no longer has, so the client drops it.
 */
export function payloadFor(options: Record<string, string>, pushedKeys: string[]) {
  const config: Record<string, string> = {}
  for (const key of pushedKeys) if (!(key in options)) config[key] = ''
  for (const [key, value] of Object.entries(options)) config[key] = String(value)
  return config
}

/** A stable version number for a payload; the device echoes it back as modified_at. */
export function stamp(config: Record<string, string>) {
  const keys = Object.keys(config).sort()
  if (keys.length === 0) return 0
  const canonical = JSON.stringify(keys.map((k) => [k, config[k]]))
  return parseInt(createHash('sha256').update(canonical).digest('hex').slice(0, 12), 16)
}
