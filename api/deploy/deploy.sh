#!/bin/sh
# Builds rd-console on df-central-1 and (re)starts it.
set -eu
host=${RD_HOST:-root@178.105.92.111}
cd "$(dirname "$0")/.."
rsync -az --delete --exclude node_modules --exclude dist --exclude data --exclude .git ./ "$host:/opt/rd-console/src/"
ssh "$host" 'set -e
  cd /opt/rd-console
  mkdir -p data && chown 1000:1000 data && chmod 700 data
  docker build -q -t rd-console:$(date +%Y%m%d%H%M%S) -t rd-console:latest src
  cp src/deploy/compose.json compose.json
  docker compose -f compose.json up -d --remove-orphans
  docker image prune -f --filter label!=keep >/dev/null'
