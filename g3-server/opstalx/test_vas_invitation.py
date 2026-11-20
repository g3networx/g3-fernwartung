from base64 import b64encode
from contextlib import closing
from importlib.util import module_from_spec, spec_from_file_location
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from flask import Flask


root = Path(__file__).resolve().parent
sys.path.insert(0, str(root / 'portal'))
import opstalx_vas


class VASInvitation(unittest.TestCase):
    def test_foreground_identity_can_join_or_decline(self):
        with TemporaryDirectory() as temporary:
            data = Path(temporary)
            portal, phone, other = (Ed25519PrivateKey.generate() for _ in range(3))
            public = lambda key: key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
            (data/'peer-public-keys.json').write_text(json.dumps({'123456789': public(phone), '987654321': public(other)}))
            (data/'jwt.key').write_text('test-only-'+'X'*32)
            pub = data/'portal.pub'
            pub.write_bytes(portal.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo))
            app = Flask(__name__)
            app.secret_key = 'test-only-portal-session-key'
            app.config['OPSTALX_SIGNING_KEY'] = portal
            opstalx_vas.install(app, SimpleNamespace(DATA=data, limited=lambda *_: None), None, None)
            browser = app.test_client()

            def proof(device, identity, first):
                signature = identity.sign(f'g3-bootstrap-v1:{device}:{first["nonce"]}'.encode())
                return browser.post('/client-vas-inbox', json={
                    'id': device, 'challenge': first['challenge'], 'signature': b64encode(signature).decode(),
                })

            first = browser.post('/client-vas-inbox', json={'id': '123456789'}).json
            self.assertEqual(proof('123456789', other, first).status_code, 403)
            self.assertEqual(proof('987654321', other, first).status_code, 403)
            token = proof('123456789', phone, first).json['token']
            second = browser.post('/client-vas-inbox', json={'id': '987654321'}).json
            other_token = proof('987654321', other, second).json['token']

            options = {'CREDENTIALS_DIRECTORY': temporary, 'STATE_DIRECTORY': temporary,
                       'OPSTALX_PORTAL_PUBLIC_KEY_FILE': str(pub)}
            spec = spec_from_file_location('vas_room_server', root/'conference/room_server.py')
            room = module_from_spec(spec)
            with patch.dict(os.environ, options):
                spec.loader.exec_module(room)
            with closing(room.sqlite3.connect(room.room_codes)) as db, db:
                db.execute('CREATE TABLE room_codes (code TEXT PRIMARY KEY, room TEXT, expires INTEGER)')
            with room.ThreadingHTTPServer(('127.0.0.1', 0), room.Rooms) as service:
                thread = threading.Thread(target=service.serve_forever, daemon=True)
                thread.start()
                try:
                    def post(path, value, bearer=None, origin=room.base):
                        headers = {'Content-Type': 'application/json', 'Origin': origin}
                        if bearer:
                            headers['Authorization'] = 'Bearer '+bearer
                        request = Request(f'http://127.0.0.1:{service.server_port}'+path,
                                          data=json.dumps(value).encode(), headers=headers)
                        try:
                            response = urlopen(request, timeout=3)
                        except HTTPError as error:
                            response = error
                        with response:
                            return response.status, json.loads(response.read())

                    claim = dict(aud='talx.opslinx.de', iss='opslinx-portal', customer_id=1,
                                 exp=int(time.time())+30, jti='a'*32)
                    payload = opstalx_vas.b64(json.dumps(claim).encode())
                    grant = payload+'.'+opstalx_vas.b64(portal.sign(payload.encode()))
                    status, session = post('/vas/redeem', {'grant': grant})
                    self.assertEqual(200, status)
                    moderator = session['url'].split('#jwt=')[1]
                    send = lambda: post('/vas/invite', {'id':'123456789'}, moderator)
                    self.assertEqual((409, {'error':'offline'}), send())
                    self.assertEqual(401, post('/vas/inbox', {}, 'forged')[0])
                    self.assertEqual((200, {'invitation':None}), post('/vas/inbox', {}, token))
                    self.assertEqual(403, post('/vas/invite', {'id':'123456789'}, token)[0])
                    self.assertEqual(403, post('/vas/invite', {'id':'123456789'}, moderator, 'https://invalid.example')[0])
                    self.assertEqual((200, {'queued':True}), send())
                    invitation = post('/vas/inbox', {}, token)[1]['invitation']
                    self.assertIsNotNone(invitation)
                    self.assertEqual({'invitation':None}, post('/vas/inbox', {}, other_token)[1])
                    self.assertEqual(404, post('/vas/inbox', {'decision':'join','invitation':invitation}, other_token)[0])
                    self.assertEqual((200, {'room':session['code']}),
                                     post('/vas/inbox', {'decision':'join','invitation':invitation}, token))
                    self.assertEqual(404, post('/vas/inbox', {'decision':'join','invitation':invitation}, token)[0])
                    self.assertEqual(200, send()[0])
                    invitation = post('/vas/inbox', {}, token)[1]['invitation']
                    self.assertEqual((200, {}), post('/vas/inbox', {'decision':'decline','invitation':invitation}, token))
                    self.assertEqual({'invitation':None}, post('/vas/inbox', {}, token)[1])
                    self.assertEqual(200, post('/vas/inbox', {'state':'away'}, token)[0])
                    self.assertEqual((409, {'error':'offline'}), send())
                finally:
                    service.shutdown()
                    thread.join()


if __name__ == '__main__':
    unittest.main()
