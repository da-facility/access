"""Private Access account server and RustDesk personal address-book API."""
import argparse
import contextlib
import getpass
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4
from wsgiref.simple_server import make_server


class ApiError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def text(value, name, limit=256, empty=False):
    if not isinstance(value, str) or len(value) > limit or (not empty and not value.strip()):
        raise ApiError(400, 'Invalid ' + name)
    return value.strip()


def password_hash(password, salt):
    return hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), 600000).hex()


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


class Application:
    def __init__(self, database, registration=False):
        self.database = str(database)
        self.registration = registration
        Path(database).parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.db() as db:
            db.executescript('''
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL,
                    salt TEXT NOT NULL, password TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sessions (token TEXT PRIMARY KEY, owner TEXT NOT NULL
                    REFERENCES users(id) ON DELETE CASCADE, expires INTEGER NOT NULL);
                CREATE TABLE IF NOT EXISTS peers (owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(owner,id));
                CREATE TABLE IF NOT EXISTS tags (owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    name TEXT NOT NULL, color INTEGER NOT NULL, PRIMARY KEY(owner,name));
                CREATE TABLE IF NOT EXISTS kvms (owner TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY(owner,id));
                CREATE TABLE IF NOT EXISTS attempts (source TEXT PRIMARY KEY, started INTEGER, count INTEGER);
            ''')
        os.chmod(self.database, 0o600)

    @contextlib.contextmanager
    def db(self):
        db = sqlite3.connect(self.database, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            with db:
                yield db
        finally:
            db.close()

    def create_user(self, name, password):
        name = text(name, 'username', 64).lower()
        if not re.fullmatch(r'[a-z0-9_.-]{3,64}', name):
            raise ApiError(400, 'Use 3–64 letters, numbers, dots, underscores or hyphens for the username.')
        if not isinstance(password, str) or not 12 <= len(password) <= 256:
            raise ApiError(400, 'Use a password between 12 and 256 characters.')
        salt = secrets.token_hex(16)
        hashed = password_hash(password, salt)
        with self.db() as db:
            try:
                db.execute('INSERT INTO users VALUES (?,?,?,?)', (str(uuid4()), name, salt, hashed))
            except sqlite3.IntegrityError:
                raise ApiError(409, 'That username is already in use.')

    def limit_login(self, source):
        now = int(time.time())
        with self.db() as db:
            db.execute('DELETE FROM attempts WHERE started < ?', (now - 900,))
            db.execute('INSERT INTO attempts VALUES (?,?,1) ON CONFLICT(source) DO UPDATE SET count=count+1',
                       (source, now))
            count = db.execute('SELECT count FROM attempts WHERE source=?', (source,)).fetchone()[0]
        if count > 30:
            raise ApiError(429, 'Too many login attempts. Try again in 15 minutes.')

    @staticmethod
    def user_payload(user):
        return {'name': user['name'], 'display_name': user['name'], 'status': 1, 'is_admin': False}

    def authenticate(self, env):
        header = env.get('HTTP_AUTHORIZATION', '')
        if not header.startswith('Bearer ') or len(header) > 512:
            raise ApiError(401, 'Please log in again.')
        with self.db() as db:
            user = db.execute('SELECT users.* FROM users JOIN sessions ON users.id=sessions.owner '
                              'WHERE sessions.token=? AND sessions.expires>?',
                              (digest(header[7:]), int(time.time()))).fetchone()
        if user is None:
            raise ApiError(401, 'Please log in again.')
        return user

    @staticmethod
    def body(env):
        try:
            length = int(env.get('CONTENT_LENGTH') or 0)
            if length < 0 or length > 1048576:
                raise ApiError(413, 'Request too large.')
            return json.loads(env['wsgi.input'].read(length)) if length else {}
        except (ValueError, UnicodeDecodeError):
            raise ApiError(400, 'Invalid JSON request.')

    @staticmethod
    def peer(body):
        if not isinstance(body, dict):
            raise ApiError(400, 'Invalid connection.')
        allowed = {'id', 'alias', 'hash', 'username', 'hostname', 'platform', 'note', 'tags',
                   'forceAlwaysRelay', 'rdpPort', 'rdpUsername', 'loginName'}
        data = {}
        for key, value in body.items():
            if key in allowed:
                if key == 'tags':
                    if not isinstance(value, list) or len(value) > 100:
                        raise ApiError(400, 'Invalid tags.')
                    data[key] = [text(t, 'tag', 100) for t in value]
                else:
                    data[key] = text(value, key, 4096 if key in ('hash', 'note') else 256, empty=key != 'id')
        if not data.get('id'):
            raise ApiError(400, 'A RustDesk ID or address is required.')
        return data

    @staticmethod
    def kvm(body):
        if not isinstance(body, dict) or set(body) - {'id', 'name', 'address', 'model', 'username', 'certificateSha256'}:
            raise ApiError(400, 'Send KVM connection details only, without passwords.')
        data = {key: text(body.get(key), key) for key in ('id', 'name', 'address', 'model', 'username')}
        try:
            uri = urlsplit(data['address'])
            if any(c.isspace() for c in data['address']) or '?' in data['address'] or '#' in data['address'] or uri.scheme not in ('http', 'https') or not uri.hostname or uri.username is not None or uri.password is not None or uri.path not in ('', '/') or uri.query or uri.fragment or (uri.port is not None and not 1 <= uri.port <= 65535):
                raise ValueError()
        except ValueError:
            raise ApiError(400, 'Enter an HTTP or HTTPS KVM address without a path or credentials.')
        if data['model'] not in ('RMQ1', 'RM4PE'):
            raise ApiError(400, 'Choose Comet Q or Comet X.')
        pin = body.get('certificateSha256')
        if pin is not None and (not isinstance(pin, str) or not re.fullmatch('[0-9a-f]{64}', pin)):
            raise ApiError(400, 'Invalid certificate fingerprint.')
        data['certificateSha256'] = pin
        return data

    def rows(self, table, owner):
        with self.db() as db:
            return [json.loads(r['data']) for r in db.execute(
                'SELECT data FROM ' + table + ' WHERE owner=? ORDER BY id', (owner,))]

    @staticmethod
    def page(items, query):
        try:
            current = max(1, int(query.get('current', ['1'])[0]))
            size = max(1, min(100, int(query.get('pageSize', ['100'])[0])))
        except ValueError:
            raise ApiError(400, 'Invalid pagination.')
        return {'total': len(items), 'data': items[(current-1)*size:current*size]}

    def dispatch(self, env):
        path, method = env['PATH_INFO'], env['REQUEST_METHOD']
        query = parse_qs(env.get('QUERY_STRING', ''))
        if method == 'GET' and path in ('/', '/app.js', '/style.css'):
            filename = {'/': 'index.html', '/app.js': 'app.js', '/style.css': 'style.css'}[path]
            return (Path(__file__).parent / filename).read_bytes()
        if method == 'GET' and path == '/healthz':
            return {'ok': True}
        if method == 'GET' and path == '/api/access/capabilities':
            return {'version': 1, 'kvms': True, 'registration': self.registration}
        if method == 'GET' and path == '/api/login-options':
            return []
        if method == 'POST' and path in ('/api/login', '/api/access/register'):
            # Only trust the socket peer; forwarded IP headers can be forged outside a trusted proxy.
            self.limit_login(env.get('REMOTE_ADDR', 'unknown'))
            body = self.body(env)
            if not isinstance(body, dict):
                raise ApiError(400, 'Invalid login.')
            if path.endswith('/register'):
                if not self.registration:
                    raise ApiError(403, 'Registration is disabled. Ask the server operator for an account.')
                self.create_user(body.get('username'), body.get('password'))
                return {'created': True}
            name = text(body.get('username'), 'username', 64).lower()
            password = body.get('password')
            if not isinstance(password, str) or len(password) > 256:
                raise ApiError(401, 'Incorrect username or password.')
            with self.db() as db:
                user = db.execute('SELECT * FROM users WHERE name=?', (name,)).fetchone()
                candidate = password_hash(password, user['salt'] if user else '00' * 16)
                if user is None or not hmac.compare_digest(candidate, user['password']):
                    raise ApiError(401, 'Incorrect username or password.')
                token = secrets.token_urlsafe(32)
                db.execute('DELETE FROM sessions WHERE expires<=?', (int(time.time()),))
                db.execute('INSERT INTO sessions VALUES (?,?,?)', (digest(token), user['id'], int(time.time()) + 30*86400))
            return {'type': 'access_token', 'access_token': token, 'user': self.user_payload(user)}

        user = self.authenticate(env)
        owner = user['id']
        if method == 'POST' and path == '/api/currentUser':
            return self.user_payload(user)
        if method == 'POST' and path == '/api/logout':
            with self.db() as db:
                db.execute('DELETE FROM sessions WHERE token=?', (digest(env['HTTP_AUTHORIZATION'][7:]),))
            return None
        if method == 'POST' and path == '/api/ab/personal':
            return {'guid': owner}
        if method == 'POST' and path == '/api/ab/settings':
            return {'max_peer_one_ab': 1000}
        if (method, path) in (('POST', '/api/ab/shared/profiles'), ('GET', '/api/device-group/accessible'), ('GET', '/api/users'), ('GET', '/api/peers')):
            return {'total': 0, 'data': []}
        if method == 'POST' and path == '/api/ab/peers':
            if query.get('ab', [''])[0] != owner:
                raise ApiError(404, 'Address book not found.')
            return self.page(self.rows('peers', owner), query)
        if path.startswith('/api/ab/'):
            parts = path.split('/')
            if parts[-1] != owner:
                raise ApiError(404, 'Address book not found.')
            action = '/'.join(parts[3:-1])
            if method == 'POST' and action == 'tags':
                with self.db() as db:
                    return [dict(r) for r in db.execute('SELECT name,color FROM tags WHERE owner=? ORDER BY name', (owner,))]
            body = self.body(env)
            with self.db() as db:
                if action in ('peer/add', 'peer/update') and method == ('POST' if action.endswith('add') else 'PUT'):
                    data = self.peer(body)
                    old = db.execute('SELECT data FROM peers WHERE owner=? AND id=?', (owner, data['id'])).fetchone()
                    if action.endswith('update') and old is None:
                        raise ApiError(404, 'Connection not found.')
                    if old:
                        data = {**json.loads(old[0]), **data}
                    elif db.execute('SELECT count(*) FROM peers WHERE owner=?', (owner,)).fetchone()[0] >= 1000:
                        raise ApiError(409, 'Address book is full.')
                    db.execute('INSERT INTO peers VALUES (?,?,?) ON CONFLICT(owner,id) DO UPDATE SET data=excluded.data', (owner, data['id'], json.dumps(data)))
                elif action == 'peer' and method == 'DELETE':
                    if not isinstance(body, list) or len(body) > 1000:
                        raise ApiError(400, 'Invalid connection IDs.')
                    for peer_id in body:
                        db.execute('DELETE FROM peers WHERE owner=? AND id=?', (owner, text(peer_id, 'ID')))
                elif action in ('tag/add', 'tag/update', 'tag/rename', 'tag'):
                    self.mutate_tags(db, owner, action, method, body)
                else:
                    raise ApiError(404, 'Endpoint not found.')
            return None
        if path == '/api/access/kvms':
            if method == 'GET':
                return {'owner': owner, 'items': self.rows('kvms', owner)}
            if method in ('POST', 'PUT'):
                data = self.kvm(self.body(env))
                with self.db() as db:
                    old = db.execute('SELECT data FROM kvms WHERE owner=? AND id=?', (owner, data['id'])).fetchone()
                    if method == 'PUT' and old is None:
                        raise ApiError(404, 'KVM not found.')
                    if method == 'POST' and old is not None:
                        raise ApiError(409, 'KVM already exists.')
                    if old is None and db.execute('SELECT count(*) FROM kvms WHERE owner=?', (owner,)).fetchone()[0] >= 1000:
                        raise ApiError(409, 'Address book is full.')
                    if old and json.loads(old[0])['address'] != data['address']:
                        data['certificateSha256'] = None
                    db.execute('INSERT INTO kvms VALUES (?,?,?) ON CONFLICT(owner,id) DO UPDATE SET data=excluded.data', (owner, data['id'], json.dumps(data)))
                return data
            if method == 'DELETE':
                body = self.body(env)
                if not isinstance(body, dict):
                    raise ApiError(400, 'Invalid KVM.')
                with self.db() as db:
                    db.execute('DELETE FROM kvms WHERE owner=? AND id=?', (owner, text(body.get('id'), 'ID')))
                return None
        raise ApiError(404, 'Endpoint not found.')

    def mutate_tags(self, db, owner, action, method, body):
        if action == 'tag' and method == 'DELETE':
            if not isinstance(body, list) or len(body) > 100:
                raise ApiError(400, 'Invalid tags.')
            names = [text(t, 'tag', 100) for t in body]
            for name in names:
                db.execute('DELETE FROM tags WHERE owner=? AND name=?', (owner, name))
            replacement = None
        elif isinstance(body, dict) and action == 'tag/rename' and method == 'PUT':
            names = [text(body.get('old'), 'tag', 100)]
            replacement = text(body.get('new'), 'tag', 100)
            if db.execute('SELECT 1 FROM tags WHERE owner=? AND name=?', (owner, replacement)).fetchone():
                raise ApiError(409, 'Tag already exists.')
            db.execute('UPDATE tags SET name=? WHERE owner=? AND name=?', (replacement, owner, names[0]))
        elif isinstance(body, dict) and (action, method) in (('tag/add', 'POST'), ('tag/update', 'PUT')):
            name, color = text(body.get('name'), 'tag', 100), body.get('color', 0)
            if not isinstance(color, int) or not 0 <= color <= 0xffffffff:
                raise ApiError(400, 'Invalid color.')
            if db.execute('SELECT count(*) FROM tags WHERE owner=?', (owner,)).fetchone()[0] >= 100 and not db.execute('SELECT 1 FROM tags WHERE owner=? AND name=?', (owner, name)).fetchone():
                raise ApiError(409, 'Too many tags.')
            db.execute('INSERT INTO tags VALUES (?,?,?) ON CONFLICT(owner,name) DO UPDATE SET color=excluded.color', (owner, name, color))
            return
        else:
            raise ApiError(400, 'Invalid tag operation.')
        for row in db.execute('SELECT id,data FROM peers WHERE owner=?', (owner,)).fetchall():
            peer = json.loads(row['data'])
            peer['tags'] = [replacement if t in names else t for t in peer.get('tags', []) if t not in names or replacement]
            db.execute('UPDATE peers SET data=? WHERE owner=? AND id=?', (json.dumps(peer), owner, row['id']))

    def __call__(self, env, start_response):
        status = 200
        content_type = 'application/json; charset=utf-8'
        try:
            data = self.dispatch(env)
            if isinstance(data, bytes):
                content_type = {'/': 'text/html', '/app.js': 'text/javascript', '/style.css': 'text/css'}[env['PATH_INFO']] + '; charset=utf-8'
                body = data
            else:
                body = b'' if data is None else json.dumps(data).encode()
        except ApiError as error:
            status, body = error.status, json.dumps({'error': error.message}).encode()
        except Exception:
            # Request bodies and credentials must never enter logs.
            import logging
            logging.exception('Address-book request failed')
            status, body = 500, b'{"error":"Server error. Try again."}'
        headers = [('Content-Type', content_type), ('Content-Length', str(len(body))), ('Cache-Control', 'no-store'),
                   ('X-Content-Type-Options', 'nosniff'), ('Referrer-Policy', 'no-referrer'),
                   ('Content-Security-Policy', "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")]
        start_response(str(status) + ' ' + {200: 'OK', 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 409: 'Conflict', 413: 'Content Too Large', 429: 'Too Many Requests', 500: 'Internal Server Error'}.get(status, 'Error'), headers)
        return [body]


def create_app():
    os.umask(0o077)
    return Application(os.environ.get('ACCESS_DATABASE', 'data/access.sqlite3'), os.environ.get('ACCESS_ALLOW_REGISTRATION') == 'true')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['serve', 'create-user', 'reset-password'], nargs='?', default='serve')
    parser.add_argument('--username')
    parser.add_argument('--port', type=int, default=8123)
    args = parser.parse_args()
    app = create_app()
    if args.command == 'serve':
        with make_server('127.0.0.1', args.port, app) as server:
            print('Access API listening on loopback port ' + str(args.port), flush=True)
            server.serve_forever()
    else:
        password = getpass.getpass('New password: ')
        if args.command == 'create-user':
            app.create_user(args.username, password)
        else:
            if not 12 <= len(password) <= 256:
                raise SystemExit('Use a password between 12 and 256 characters.')
            with app.db() as db:
                user = db.execute('SELECT id FROM users WHERE name=?', (text(args.username, 'username').lower(),)).fetchone()
                if user is None:
                    raise SystemExit('User not found.')
                salt = secrets.token_hex(16)
                db.execute('UPDATE users SET salt=?,password=? WHERE id=?', (salt, password_hash(password, salt), user[0]))
                db.execute('DELETE FROM sessions WHERE owner=?', (user[0],))
        print('Account updated.')
