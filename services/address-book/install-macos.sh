#!/usr/bin/env bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
export ACCESS_INSTALL_ROOT="${ACCESS_INSTALL_ROOT:-$HOME/Library/Application Support/Da Facility Access Server}"
export ACCESS_ALLOW_REGISTRATION="${ACCESS_ALLOW_REGISTRATION:-false}"
umask 077
mkdir -p "$ACCESS_INSTALL_ROOT/app"
cp "$source_dir"/{server.py,index.html,app.js,style.css,requirements.txt} "$ACCESS_INSTALL_ROOT/app/"
python3 -m venv "$ACCESS_INSTALL_ROOT/venv"
"$ACCESS_INSTALL_ROOT/venv/bin/pip" install -r "$ACCESS_INSTALL_ROOT/app/requirements.txt"
python3 - <<'PY'
import os, pathlib, plistlib
root = pathlib.Path(os.environ['ACCESS_INSTALL_ROOT'])
p = pathlib.Path.home() / 'Library/LaunchAgents/io.dafacility.access-api.plist'
p.parent.mkdir(parents=True, exist_ok=True)
config = {'Label': 'io.dafacility.access-api',
    'ProgramArguments': [str(root/'venv/bin/gunicorn'), '--bind', '127.0.0.1:8123', '--workers', '2', '--timeout', '30', 'server:create_app()'],
    'WorkingDirectory': str(root/'app'),
    'EnvironmentVariables': {'ACCESS_DATABASE': str(root/'access.sqlite3'), 'ACCESS_ALLOW_REGISTRATION': os.environ['ACCESS_ALLOW_REGISTRATION']},
    'RunAtLoad': True, 'KeepAlive': True,
    'StandardOutPath': str(root/'server.log'), 'StandardErrorPath': str(root/'server-error.log')}
p.write_bytes(plistlib.dumps(config))
PY
if launchctl bootout "gui/$(id -u)/io.dafacility.access-api" 2>/dev/null; then
  sleep 1
fi
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/io.dafacility.access-api.plist"
echo 'Installed Access API on loopback port 8123. Expose it privately using Tailscale Serve.'
