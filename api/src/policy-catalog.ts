/**
 * What a policy ("strategy" in RustDesk) can set on a device. The server
 * sends these as RustDesk's own option keys in the heartbeat reply; the
 * client writes them into its settings (RustDesk2.toml, [options]). Every
 * value travels as a string. Defaults are the client's own when unset.
 */
export type PolicyOption = {
  key: string
  label: string
  group: PolicyGroup
  description: string
  kind: 'toggle' | 'choice' | 'text' | 'number'
  /** For toggles: "Y" / "N". For choices: the allowed values. */
  choices?: { value: string; label: string }[]
  /** What the client does when the option is not set. */
  default: string
  /** Changing it can cut the device off from this server. */
  dangerous?: boolean
}

export type PolicyGroup = 'Permissions' | 'Security' | 'Sessions' | 'Network' | 'Server' | 'Recording' | 'Display' | 'Provisioning'

export const policyGroups: PolicyGroup[] = ['Permissions', 'Security', 'Sessions', 'Recording', 'Network', 'Display', 'Server', 'Provisioning']

const toggle = (key: string, label: string, group: PolicyGroup, description: string, def: 'Y' | 'N', extra: Partial<PolicyOption> = {}): PolicyOption => ({
  key,
  label,
  group,
  description,
  kind: 'toggle',
  default: def,
  ...extra,
})

export const policyCatalog: PolicyOption[] = [
  {
    key: 'access-mode',
    label: 'Permission preset',
    group: 'Permissions',
    description: 'What someone connecting to this device may do. "Full access" and "Screen share only" override the individual permissions below; "Custom" uses them.',
    kind: 'choice',
    choices: [
      { value: 'custom', label: 'Custom (use the toggles)' },
      { value: 'full', label: 'Full access' },
      { value: 'view', label: 'Screen share only' },
    ],
    default: 'custom',
  },
  toggle('enable-keyboard', 'Keyboard and mouse', 'Permissions', 'Let the remote side type and move the mouse.', 'Y'),
  toggle('enable-clipboard', 'Clipboard', 'Permissions', 'Sync the clipboard between the two sides.', 'Y'),
  toggle('enable-file-transfer', 'File transfer', 'Permissions', 'Allow copying files to and from this device.', 'Y'),
  toggle('enable-audio', 'Audio', 'Permissions', "Send this device's sound to the remote side.", 'Y'),
  toggle('enable-camera', 'Camera', 'Permissions', "Let the remote side view this device's camera.", 'Y'),
  toggle('enable-terminal', 'Terminal', 'Permissions', 'Allow opening a remote terminal (shell) session.', 'Y'),
  toggle('enable-tunnel', 'TCP tunnelling', 'Permissions', 'Allow port forwarding through this device.', 'Y'),
  toggle('enable-remote-restart', 'Remote restart', 'Permissions', 'Let the remote side restart this device.', 'Y'),
  toggle('enable-record-session', 'Session recording', 'Permissions', 'Let the remote side record the session.', 'Y'),
  toggle('enable-block-input', 'Block user input', 'Permissions', 'Let the remote side block the local keyboard and mouse.', 'Y'),
  toggle('enable-privacy-mode', 'Privacy mode', 'Permissions', "Let the remote side black out this device's screen while connected.", 'Y'),
  toggle('enable-remote-printer', 'Remote printer', 'Permissions', 'Let the remote side print to this device (Windows).', 'Y'),
  toggle('allow-remote-config-modification', 'Remote settings changes', 'Permissions', "Let a connected user change this device's RustDesk settings.", 'N'),
  {
    key: 'approve-mode',
    label: 'How connections are accepted',
    group: 'Security',
    description: 'Whether a password, a click on the device, or either is needed to let someone in.',
    kind: 'choice',
    choices: [
      { value: '', label: 'Password or click' },
      { value: 'password', label: 'Password only' },
      { value: 'click', label: 'Click only' },
    ],
    default: '',
  },
  {
    key: 'verification-method',
    label: 'Which passwords work',
    group: 'Security',
    description: 'Accept the rotating one-time password, the permanent password, or both.',
    kind: 'choice',
    choices: [
      { value: 'use-both-passwords', label: 'Both' },
      { value: 'use-temporary-password', label: 'One-time password only' },
      { value: 'use-permanent-password', label: 'Permanent password only' },
    ],
    default: 'use-both-passwords',
  },
  {
    key: 'temporary-password-length',
    label: 'One-time password length',
    group: 'Security',
    description: 'Number of characters in the one-time password.',
    kind: 'choice',
    choices: ['6', '8', '10'].map((value) => ({ value, label: value })),
    default: '6',
  },
  toggle('allow-numeric-one-time-password', 'Numeric one-time password', 'Security', 'Use digits only for the one-time password.', 'N'),
  {
    key: 'whitelist',
    label: 'IP allow list',
    group: 'Security',
    description: 'Only these IPs or CIDR ranges may connect, comma-separated. Empty allows everyone.',
    kind: 'text',
    default: '',
    dangerous: true,
  },
  {
    key: 'id-whitelist',
    label: 'ID allow list',
    group: 'Security',
    description: 'Only these RustDesk IDs may connect, comma-separated. Empty allows everyone.',
    kind: 'text',
    default: '',
  },
  toggle('enable-trusted-devices', 'Trusted devices', 'Security', 'Let users skip two-factor on devices they marked as trusted.', 'Y'),
  toggle('allow-only-conn-window-open', 'Only while RustDesk is open', 'Security', 'Accept connections only while the RustDesk window is open on this device.', 'N'),
  toggle('allow-scope-violation-close', 'Close on scope violation', 'Security', 'End a session that tries to do something its permissions forbid.', 'Y'),
  toggle('allow-scope-violation-alarm', 'Alarm on scope violation', 'Security', 'Report scope violations to the audit log.', 'Y'),
  toggle('allow-auto-disconnect', 'Disconnect idle sessions', 'Sessions', 'End incoming sessions after a period without input.', 'N'),
  { key: 'auto-disconnect-timeout', label: 'Idle timeout (minutes)', group: 'Sessions', description: 'Minutes without input before an idle session ends.', kind: 'number', default: '10' },
  toggle('keep-awake-during-incoming-sessions', 'Keep awake while connected', 'Sessions', 'Stop this device from sleeping during an incoming session.', 'Y'),
  toggle('allow-remove-wallpaper', 'Hide wallpaper', 'Sessions', 'Remove the desktop wallpaper during incoming sessions to save bandwidth.', 'N'),
  toggle('allow-auto-record-incoming', 'Record incoming sessions', 'Recording', 'Automatically record every incoming session on this device.', 'N'),
  { key: 'video-save-directory', label: 'Recording folder', group: 'Recording', description: 'Where recordings are saved on this device.', kind: 'text', default: '' },
  toggle('enable-lan-discovery', 'LAN discovery', 'Network', 'Let other RustDesk clients on the same network find this device.', 'Y'),
  toggle('direct-server', 'Direct IP access', 'Network', 'Accept direct connections by IP address, bypassing the ID server.', 'N'),
  { key: 'direct-access-port', label: 'Direct IP port', group: 'Network', description: 'Port for direct IP access.', kind: 'number', default: '21118' },
  toggle('disable-udp', 'Disable UDP', 'Network', 'Use TCP only; helps on restrictive networks, may be slower.', 'N'),
  toggle('allow-websocket', 'WebSocket transport', 'Network', 'Connect through WebSocket (for networks that only allow HTTPS).', 'N'),
  { key: 'proxy-url', label: 'Proxy', group: 'Network', description: 'SOCKS5 or HTTP proxy for all RustDesk traffic.', kind: 'text', default: '' },
  toggle('enable-abr', 'Adaptive bitrate', 'Display', 'Adjust video quality to the connection.', 'Y'),
  toggle('enable-hwcodec', 'Hardware codec', 'Display', 'Use the GPU to encode video when available.', 'Y'),
  toggle('allow-always-software-render', 'Software rendering', 'Display', 'Never use the GPU to render.', 'N'),
  toggle('enable-directx-capture', 'DirectX capture', 'Display', 'Capture the screen through DirectX (Windows).', 'Y'),
  {
    key: 'custom-rendezvous-server',
    label: 'ID server',
    group: 'Server',
    description: 'The ID server this device registers with. Wrong values cut the device off.',
    kind: 'text',
    default: '',
    dangerous: true,
  },
  { key: 'relay-server', label: 'Relay server', group: 'Server', description: 'The relay used when a direct connection fails.', kind: 'text', default: '', dangerous: true },
  { key: 'api-server', label: 'API server', group: 'Server', description: 'This console. Wrong values stop policies, audit and the address book.', kind: 'text', default: '', dangerous: true },
  { key: 'key', label: 'Server key', group: 'Server', description: "The ID server's public key.", kind: 'text', default: '', dangerous: true },
  toggle('allow-auto-update', 'Automatic updates', 'Server', 'Let the client update itself.', 'N'),
  { key: 'preset-device-name', label: 'Device name', group: 'Provisioning', description: 'Name the device reports, instead of its hostname.', kind: 'text', default: '' },
  { key: 'preset-device-username', label: 'Device user name', group: 'Provisioning', description: 'User name the device reports, instead of the logged-in OS user.', kind: 'text', default: '' },
  { key: 'preset-note', label: 'Device note', group: 'Provisioning', description: 'Note the device reports with its system info.', kind: 'text', default: '' },
]

export const policyOption = (key: string) => policyCatalog.find((o) => o.key === key)

export function describeValue(option: PolicyOption | undefined, value: string) {
  if (!option) return value || '(empty)'
  if (option.kind === 'toggle') return value === 'Y' ? 'On' : value === 'N' ? 'Off' : value
  if (option.choices) return option.choices.find((c) => c.value === value)?.label ?? value
  return value === '' ? '(empty)' : value
}
