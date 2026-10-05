import io
import json
from pathlib import Path
import tempfile
import unittest

from server import Application, ApiError


class ApiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / 'book.sqlite3'
        self.app = Application(self.path, registration=True)
        self.app.create_user('alice', 'alice-test-password')
        self.app.create_user('bob', 'bob-test-password')
        self.alice = self.call('POST', '/api/login', {'username': 'alice', 'password': 'alice-test-password'})[1]['access_token']
        self.bob = self.call('POST', '/api/login', {'username': 'bob', 'password': 'bob-test-password'})[1]['access_token']
        self.guid = self.call('POST', '/api/ab/personal', token=self.alice)[1]['guid']

    def tearDown(self):
        self.tmp.cleanup()

    def call(self, method, path, body=None, token='', query=''):
        payload = b'' if body is None else json.dumps(body).encode()
        env = {'PATH_INFO': path, 'REQUEST_METHOD': method, 'QUERY_STRING': query,
               'CONTENT_LENGTH': str(len(payload)), 'wsgi.input': io.BytesIO(payload),
               'HTTP_AUTHORIZATION': 'Bearer ' + token, 'REMOTE_ADDR': 'test-client'}
        status = []
        result = b''.join(self.app(env, lambda code, headers: status.append(int(code.split()[0]))))
        return status[0], json.loads(result) if result else None

    def test_login_isolation_persistence_and_revocation(self):
        self.assertEqual(self.call('GET', '/api/access/kvms')[0], 401)
        self.assertEqual(self.call('POST', '/api/login', {'username': 'alice', 'password': 'wrong'})[0], 401)
        self.assertEqual(self.call('POST', '/api/ab/peer/add/' + self.guid,
                                   {'id': '123456789', 'alias': 'Work'}, self.alice), (200, None))
        self.assertEqual(self.call('POST', '/api/ab/peers', token=self.bob, query='ab=' + self.guid)[0], 404)
        self.assertEqual(self.call('PUT', '/api/ab/peer/update/' + self.guid, {'id': '123456789', 'alias': 'stolen'}, self.bob)[0], 404)
        self.app = Application(self.path)
        self.assertEqual(self.call('POST', '/api/ab/peers', token=self.alice, query='ab=' + self.guid)[1]['data'][0]['alias'], 'Work')
        with self.app.db() as db:
            session = db.execute('SELECT token FROM sessions').fetchone()[0]
            self.assertNotEqual(session, self.alice)
            self.assertNotEqual(db.execute('SELECT password FROM users WHERE name="alice"').fetchone()[0], 'alice-test-password')
        self.assertEqual(self.call('POST', '/api/logout', token=self.alice), (200, None))
        self.assertEqual(self.call('POST', '/api/currentUser', token=self.alice)[0], 401)
        self.assertEqual(self.call('POST', '/api/access/register', {'username': 'charlie', 'password': 'charlie-test-password'})[0], 403)

    def test_rustdesk_crud_tags_and_pagination(self):
        root = '/api/ab/'
        for i in range(3):
            self.assertEqual(self.call('POST', root + 'peer/add/' + self.guid, {'id': str(i), 'alias': 'Computer', 'tags': ['office']}, self.alice), (200, None))
        self.assertEqual(self.call('POST', root + 'tag/add/' + self.guid, {'name': 'office', 'color': 0xff112233}, self.alice), (200, None))
        self.assertEqual(self.call('PUT', root + 'tag/rename/' + self.guid, {'old': 'office', 'new': 'home'}, self.alice), (200, None))
        result = self.call('POST', root + 'peers', token=self.alice, query='ab=' + self.guid + '&pageSize=2&current=2')[1]
        self.assertEqual(result['total'], 3)
        self.assertEqual(result['data'][0]['tags'], ['home'])
        self.assertEqual(self.call('PUT', root + 'peer/update/' + self.guid, {'id': '2', 'alias': 'Renamed'}, self.alice), (200, None))
        self.assertEqual(self.call('DELETE', root + 'tag/' + self.guid, ['home'], self.alice), (200, None))
        self.assertEqual(self.call('POST', root + 'tags/' + self.guid, token=self.alice)[1], [])
        self.assertEqual(self.call('DELETE', root + 'peer/' + self.guid, ['2'], self.alice), (200, None))
        self.assertEqual(self.call('POST', root + 'peers', token=self.alice, query='ab=' + self.guid)[1]['total'], 2)

    def test_kvm_crud_scoping_validation_and_registration(self):
        kvm = {'id': 'shared-id', 'name': 'Comet', 'address': 'https://kvm.example', 'model': 'RM4PE', 'username': 'admin', 'certificateSha256': 'a' * 64}
        self.assertEqual(self.call('POST', '/api/access/kvms', kvm, self.alice)[0], 200)
        self.assertEqual(self.call('GET', '/api/access/kvms', token=self.bob)[1]['items'], [])
        self.assertEqual(self.call('PUT', '/api/access/kvms', kvm, self.bob)[0], 404)
        self.assertEqual(self.call('POST', '/api/access/kvms', {**kvm, 'password': 'must-not-save'}, self.bob)[0], 400)
        self.assertEqual(self.call('POST', '/api/access/kvms', {**kvm, 'address': 'https://admin:secret@kvm.example'}, self.bob)[0], 400)
        self.assertEqual(self.call('PUT', '/api/access/kvms', {**kvm, 'address': 'https://other.example'}, self.alice)[1]['certificateSha256'], None)
        self.call('DELETE', '/api/access/kvms', {'id': 'shared-id'}, self.bob)
        self.assertEqual(len(self.call('GET', '/api/access/kvms', token=self.alice)[1]['items']), 1)
        self.call('DELETE', '/api/access/kvms', {'id': 'shared-id'}, self.alice)
        self.assertEqual(self.call('GET', '/api/access/kvms', token=self.alice)[1]['items'], [])
        self.assertEqual(self.call('POST', '/api/access/register', {'username': 'charlie', 'password': 'charlie-test-password'})[0], 200)
        self.assertEqual(self.call('POST', '/api/access/register', {'username': 'charlie', 'password': 'charlie-test-password'})[0], 409)
        for _ in range(30):
            self.app.limit_login('limited')
        with self.assertRaises(ApiError) as error:
            self.app.limit_login('limited')
        self.assertEqual(error.exception.status, 429)


if __name__ == '__main__':
    unittest.main()
