# hbbs with the TCP key exchange

The ID server at rd.dafacility.io: the official rustdesk-server 1.1.16, plus the server half of the key exchange that RustDesk clients run on their TCP connection to hbbs.

## Why

A client signed in to the API server holds an access token. It will not send the token to hbbs in the clear, so it waits for the server to offer a key exchange first. The open-source hbbs never offers one. Every connection from a signed-in client therefore failed with "Failed to secure tcp: deadline has elapsed". Connections from signed-out clients kept working.

## What the patch does

The server code is in `secure_tcp.rs`. Its wiring into the official source is `rendezvous_server.patch`, and `hbb_common.patch` adds the proto fields.

1. Every TCP connection on 21116 gets an offer: a fresh X25519 key signed with the server key.
2. A client that wants encryption answers it, and the rest of the connection is encrypted.
3. Clients that don't want it skip the offer, as they already do with RustDesk Server Pro.
4. Version 1 (one key per direction, bound to the handshake) is used with clients that speak it. Older clients fall back to version 0.
5. The relay (hbbr) is unchanged and keeps the official image.

Clients from before the exchange was introduced, around RustDesk 1.1.x, read the offer as the reply they were waiting for, and their NAT test and punch hole fail. Use RustDesk 1.2 or newer; every device here runs 1.5.

## Testing and deploying

- `kx-probe/` connects the way RustDesk 1.5 clients do, as a plain, an old-style and a current client. It uses the client's own `libs/hbb_common` and a verbatim copy of its key exchange.
- `deploy.sh` builds the image on the server, which also runs the unit tests, and points `/opt/rustdesk/compose.json` at it. It backs up the previous compose file next to it.
