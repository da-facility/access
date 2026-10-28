# RustDesk API server and admin console

API server and admin console for the self-hosted RustDesk at `rd.dafacility.io`.

- `/api/*`: the HTTP API RustDesk clients call when their "API server" points here. It covers accounts, address books, device check-ins (`/api/sysinfo`, `/api/heartbeat`), policy ("strategy") push and audit intake (`/api/audit/*`). See `src/server/rustdesk.ts`.
- `/admin`: the admin console (TanStack Start, @da-facility/ui, Astryx). It signs in through Pocket ID at `sso.dafacility.io`, and only members of the `admins` group get in.

The ID/relay servers (`hbbs`/`hbbr`, RustDesk OSS) run separately from `/opt/rustdesk` on df-central-1.

## Develop

From `api/`:

    bun install
    bun run dev        # http://localhost:3140
    bun run test
    bun run check

## Deploy (df-central-1)

    api/deploy/deploy.sh

This builds the image on the server, then runs `deploy/compose.json` from `/opt/rd-console`. The data lives in `/opt/rd-console/data/rd.sqlite3`. Caddy (`/opt/oddball-coordinator/Caddyfile`) proxies `rd.dafacility.io` to the `rd-console` container on the `oddball-central_default` network.
