#!/bin/sh
# Builds the patched hbbs on df-central-1 and switches /opt/rustdesk to it. hbbr stays on the
# official image.
set -eu
host=${RD_HOST:-root@178.105.92.111}
cd "$(dirname "$0")"
rsync -az --delete --exclude kx-probe ./ "$host:/opt/rustdesk/hbbs-src/"
ssh "$host" 'set -e
  cd /opt/rustdesk
  tag=1.1.16-kx-$(date +%Y%m%d%H%M%S)
  DOCKER_BUILDKIT=1 docker build -q -t rustdesk-hbbs:$tag hbbs-src
  cp compose.json compose.json.bak-$(date +%Y%m%d%H%M%S)
  python3 - "rustdesk-hbbs:$tag" <<"PY"
import json, sys
c = json.load(open("compose.json"))
c["services"]["hbbs"]["image"] = sys.argv[1]
json.dump(c, open("compose.json.new", "w"), indent=2)
PY
  mv compose.json.new compose.json
  docker compose -f compose.json up -d hbbs
  echo "hbbs now runs rustdesk-hbbs:$tag"'
