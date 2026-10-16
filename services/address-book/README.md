# Access account and address-book server

A small, separate API server for this fork. Each account owns one personal address book with RustDesk connections and Comet Q/X KVMs. SQLite stores the data. Existing RustDesk ID and relay services still handle RustDesk sessions; this service does not implement rendezvous, relaying or remote desktop transport.

The browser page lets users create an account when registration is enabled, sign in, and add, rename or remove both kinds of connection. The iOS app uses its existing Settings → Account login and address-book tab. Regular computers use the existing Add ID control. An additional GL.iNet KVMs row opens the account's KVM list, editor and local-client import. KVMs connect through the existing session screen, including the Comet X port selector.

## Run privately

Python 3.9 or later is required. Install dependencies in a virtual environment:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
export ACCESS_DATABASE=/absolute/private/path/access.sqlite3
export ACCESS_ALLOW_REGISTRATION=false
.venv/bin/gunicorn --bind 127.0.0.1:8123 --workers 2 --timeout 30 'server:create_app()'
```

The account database and parent directory must be private to the server user. The application creates new data directories with mode 0700 and its database with mode 0600. Do not commit the database, logs or credentials.

Expose the service through private Tailscale Serve, choosing an unused HTTPS port and preserving existing services:

```sh
tailscale status --json
tailscale serve status
tailscale serve --bg --https=8463 http://127.0.0.1:8123
```

Use the HTTPS URL printed by Tailscale. The phone and browser must be connected to the tailnet and allowed to reach that host and port. Do not expose the plain HTTP listener publicly.

For a persistent macOS installation, run `install-macos.sh`. It copies the application and creates a virtual environment under `~/Library/Application Support/Da Facility Access Server`, then installs the `io.dafacility.access-api` launch agent. Keeping the runtime outside Documents avoids macOS background-process access restrictions. The service starts when this Mac's user logs in and is available while the Mac is awake and connected. The installer preserves the database; rerun it to deploy source updates. It does not change Tailscale configuration.

Set `ACCESS_ALLOW_REGISTRATION=true` when installing only if people who can reach this private service should be able to create their own accounts. Registration grants access to a new, empty personal address book. It does not grant access to anyone else's data. The default is false.

```sh
ACCESS_ALLOW_REGISTRATION=true ./install-macos.sh
```

For closed registration, create users with an interactive password prompt using the same `ACCESS_DATABASE`:

```sh
.venv/bin/python server.py create-user --username alice
.venv/bin/python server.py reset-password --username alice
```

A password reset revokes that user's existing sessions. To run these commands against the macOS installation, use its `venv/bin/python`, `app/server.py` and database path under Application Support.

## Connect Access

1. Open the service's private HTTPS URL and create an account, or obtain one from the operator.
2. In Access, open Settings → ID/Relay Server. Set **API Server** to that same HTTPS origin. Keep the existing ID server, relay and key settings.
3. Log in under Settings → Account.
4. Open the address-book tab under Connection. Use Add ID for RustDesk computers or GL.iNet KVMs for Comet devices.

Additions appear on other devices when the address book is refreshed or reopened. Local KVM definitions are not uploaded automatically. Use Copy a local KVM to my account to opt in. Copying does not upload its Keychain password.

## Data and authentication

- Passwords use salted PBKDF2-HMAC-SHA256 with 600,000 iterations. Bearer tokens contain 256 random bits; only their SHA-256 digests are stored. Tokens expire after 30 days and logout revokes the current token.
- Every data query and mutation is scoped to the authenticated account. Clients cannot choose another owner. Book GUIDs are checked against the token's owner.
- Login and registration are limited to 30 attempts per socket source in 15 minutes. When proxied, callers share the proxy's budget. Forwarded source headers are deliberately not trusted.
- KVM passwords are rejected by the API and stay in iOS Keychain. Their Keychain identities include the API origin, account UUID and KVM identity. Certificate fingerprints approved in a KVM session are saved in the account; changing the KVM address clears the fingerprint.
- RustDesk peers can include their existing saved credential hashes for compatibility with RustDesk's personal-address-book behavior. Treat the database and backups as sensitive. The web editor never asks for remote connection passwords.
- The browser keeps its bearer token in memory only. Reloading the page requires login again. Browser mutations require an Authorization header; there are no authentication cookies or cross-origin API permissions.

Use SQLite's backup API or `.backup` command for live backups. Do not copy only the main database file while WAL writes are active. Stop the service before restoring a backup.

## Supported API

The implementation follows the client code in this repository, not RustDesk Server Pro's implementation. It supports the modern personal-address-book path:

- Login, logout, current user and empty third-party login options.
- Personal book identity, settings and paginated peers.
- Per-peer add/update/delete, aliases, notes, tags and tag colors.
- Tag add/update/rename/delete, including updates to peer tags.
- Empty shared-book, user-group and managed-device lists.
- `/api/access/capabilities` and account-scoped `/api/access/kvms` CRUD for Comet connections.

Successful RustDesk mutation responses intentionally have an empty HTTP 200 body because that is what this client's action parser expects. The obsolete `/api/ab` whole-book replacement API is not implemented. Other RustDesk versions need their own compatibility testing.

This first version does not implement sharing, organizations, SSO, email verification, MFA, password recovery by email, automatic conflict resolution or managed-device inventory. Concurrent edits to one entry use the last completed write; edits to different entries do not replace the whole book. There is no live push synchronization. Deleting a KVM from another device does not remotely erase an old password from this phone's Keychain, but that entry is no longer available in the account list.

## Verify

```sh
python3 -m unittest discover -s . -v
```

Tests cover authentication, logout revocation, registration controls, hashed secrets, persistence across application instances, cross-account read/write isolation, RustDesk CRUD and pagination, tag propagation, KVM CRUD, rejected passwords/credential URLs and certificate reset on address change. The Flutter test `glinet_address_book_test.dart` verifies Keychain separation between accounts, servers and local profiles.
