from base64 import urlsafe_b64decode, urlsafe_b64encode
from contextlib import closing
from hashlib import sha256
from hmac import digest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
from threading import Lock
import time
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.serialization import load_pem_public_key

def encode(value):
    return urlsafe_b64encode(json.dumps(value, separators=(',', ':')).encode()).rstrip(b'=')

def decode(value):
    return urlsafe_b64decode(value + '=' * (-len(value) % 4))

key = (Path(os.environ['CREDENTIALS_DIRECTORY']) / 'jwt.key').read_bytes().strip()
portal_key = load_pem_public_key(Path('/etc/opstalx-ar/portal-release.pub').read_bytes())
base = 'https://talx.opslinx.de'
used = {}
lock = Lock()
room_codes = Path(os.environ['STATE_DIRECTORY']) / 'room-codes.sqlite3'


def new_room_code(room, expires):
    with closing(sqlite3.connect(room_codes, timeout=5)) as db, db:
        db.execute('DELETE FROM room_codes WHERE expires <= ?', (int(time.time()),))
        while True:
            code = f'{secrets.randbelow(10**10):010d}'
            result = db.execute('INSERT OR IGNORE INTO room_codes VALUES (?, ?, ?)', (code, room, expires))
            if result.rowcount:
                return code


def find_room(code):
    if not isinstance(code, str) or not re.fullmatch(r'[0-9]{10}', code):
        return None
    with closing(sqlite3.connect(room_codes, timeout=5)) as db:
        match = db.execute('SELECT room FROM room_codes WHERE code = ? AND expires > ?',
                           (code, int(time.time()))).fetchone()
    return match[0] if match else None

def consume(grant):
    if not isinstance(grant, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,1000}[.][A-Za-z0-9_-]{86}',grant):
        return False
    payload, signature = grant.split('.')
    try:
        portal_key.verify(decode(signature), payload.encode())
        claim = json.loads(decode(payload))
        now = int(time.time())
        expiry = claim['exp']
        jti = claim['jti']
        if (claim['aud'] != 'talx.opslinx.de' or claim['iss'] != 'opslinx-portal'
                or type(claim['customer_id']) is not int or claim['customer_id'] <= 0
                or type(expiry) is not int or not now <= expiry <= now+65
                or not re.fullmatch(r'[a-f0-9]{32}', jti)):
            return False
    except (ValueError, KeyError, TypeError, InvalidSignature):
        return False
    with lock:
        for nonce in tuple(used):
            if used[nonce] < now:
                del used[nonce]
        if jti in used or len(used)>=512:
            return False
        used[jti]=expiry
        return True

class Rooms(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        if self.path != '/vas/redeem' or self.headers.get('Origin') != base:
            self.send_error(403)
            return
        try:
            length = int(self.headers.get('Content-Length','-1'))
            if not 1<=length<=2048:
                raise ValueError()
            value = json.loads(self.rfile.read(length))
            if isinstance(value, dict) and set(value) == {'code'}:
                room = find_room(value['code'])
                if not room:
                    self.send_error(404)
                    return
                self.reply({'room': room})
                return
            if not consume(value['grant']):
                self.send_error(403)
                return
        except (ValueError, TypeError, KeyError):
            self.send_error(400)
            return
        room = secrets.token_hex(16)
        expires = int(time.time()) + 1800
        code = new_room_code(room, expires)
        claim = {'iss':'opstalx-lab','aud':'jitsi','sub':'talx.opslinx.de','room':room,
                 'exp':expires,'context':{'user':{'name':'Support','moderator':True}}}
        body = encode({'alg':'HS256','typ':'JWT'})+b'.'+encode(claim)
        token = (body+b'.'+urlsafe_b64encode(digest(key,body,sha256)).rstrip(b'=')).decode()
        self.reply({'url':f'/vas/?room={room}#jwt={token}', 'code':code})

    def reply(self, payload):
        response = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Cache-Control','no-store')
        self.send_header('Content-Length',str(len(response)))
        self.end_headers()
        self.wfile.write(response)

if __name__ == '__main__':
    with closing(sqlite3.connect(room_codes, timeout=5)) as db, db:
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('CREATE TABLE IF NOT EXISTS room_codes (code TEXT PRIMARY KEY, room TEXT NOT NULL, expires INTEGER NOT NULL)')
    ThreadingHTTPServer(('127.0.0.1',8761),Rooms).serve_forever()
