from base64 import urlsafe_b64decode, urlsafe_b64encode
from contextlib import closing
from hashlib import sha256
from hmac import compare_digest, digest
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
portal_key = load_pem_public_key(Path(os.environ.get(
    'OPSTALX_PORTAL_PUBLIC_KEY_FILE', '/etc/opstalx-ar/portal-release.pub')).read_bytes())
base = 'https://talx.opslinx.de'
used = {}
lock = Lock()
room_codes = Path(os.environ['STATE_DIRECTORY']) / 'room-codes.sqlite3'
invite_lock = Lock()
receivers = {}
invitations = {}
send_limits = {}
last_cleanup = 0


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


def signed_claim(token, verifier, parts=2):
    if not isinstance(token, str) or len(token) > 2048:
        return {}
    fields = token.split('.')
    if len(fields) != parts or not all(re.fullmatch(r'[A-Za-z0-9_-]+', part) for part in fields):
        return {}
    try:
        verifier('.'.join(fields[:-1]).encode(), decode(fields[-1]))
        result = json.loads(decode(fields[-2]))
        if isinstance(result, dict) and type(result.get('exp')) is int and result['exp'] > time.time():
            return result
    except (ValueError, TypeError, InvalidSignature):
        pass
    return {}


def verify_moderator(body, signature):
    if not compare_digest(digest(key, body, sha256), signature):
        raise InvalidSignature()


def moderator_room(token):
    claim = signed_claim(token, verify_moderator, parts=3)
    if (claim.get('iss') == 'opstalx-lab' and claim.get('aud') == 'jitsi'
            and claim.get('sub') == 'talx.opslinx.de'
            and isinstance(claim.get('context'), dict)
            and claim['context'].get('user') == {'name': 'Support', 'moderator': True}
            and re.fullmatch(r'[a-f0-9]{32}', str(claim.get('room', '')))):
        return claim['room']
    return None


def inbox_device(token):
    claim = signed_claim(token, lambda body, signature: portal_key.verify(signature, body))
    now = int(time.time())
    device = claim.get('sub')
    if (claim.get('iss') == 'opslinx-vas-inbox' and claim.get('aud') == 'talx.opslinx.de'
            and type(claim.get('iat')) is int and now-300 <= claim['iat'] <= now+5
            and claim['exp'] <= claim['iat']+300
            and isinstance(device, str) and re.fullmatch(r'[A-Za-z0-9_-]{6,40}', device)):
        return digest(key, b'vas-inbox:' + device.encode(), sha256)
    return None


def cleanup_invites(now):
    global last_cleanup
    if now - last_cleanup < 1:
        return
    last_cleanup = now
    for data in (receivers, invitations, send_limits):
        for item, (expires, *_) in tuple(data.items()):
            if expires <= now:
                data.pop(item, None)


def send_invite(room, device):
    target = digest(key, b'vas-inbox:' + device.encode(), sha256)
    now = time.monotonic()
    wall = time.time()
    with closing(sqlite3.connect(room_codes, timeout=5)) as db:
        match = db.execute('SELECT code,expires FROM room_codes WHERE room=? AND expires>?', (room, wall)).fetchone()
    if not match:
        return 404, {'error': 'room'}
    with invite_lock:
        cleanup_invites(now)
        expiry, count = send_limits.get(room, (now+60, 0))
        if expiry <= now:
            expiry, count = now+60, 0
        if count >= 5 or len(send_limits) >= 4096:
            return 429, {'error': 'rate'}
        send_limits[room] = (expiry, count+1)
        if receivers.get(target, (0,))[0] <= now:
            return 409, {'error': 'offline'}
        existing = invitations.get(target)
        if existing and existing[0] > now:
            return (200, {'queued': True}) if existing[2] == match[0] else (409, {'error': 'busy'})
        if len(invitations) >= 4096:
            return 429, {'error': 'rate'}
        invitations[target] = (now+min(90, match[1]-wall), secrets.token_urlsafe(18), match[0])
        return 200, {'queued': True}


def receive_invite(target, value):
    now = time.monotonic()
    with invite_lock:
        cleanup_invites(now)
        if not value:
            if target not in receivers and len(receivers) >= 4096:
                return 503, {'error': 'busy'}
            receivers[target] = (now+20,)
            current = invitations.get(target)
            return 200, {'invitation': current[1] if current and current[0] > now else None}
        if value == {'state': 'away'}:
            receivers.pop(target, None)
            return 200, {}
        current = invitations.get(target)
        decision = value.get('decision')
        if decision not in ('join', 'decline') or not isinstance(value.get('invitation'), str):
            return 400, {'error': 'input'}
        if not current or current[0] <= now or not compare_digest(value['invitation'].encode(), current[1].encode()):
            return 404, {'error': 'expired'}
        invitations.pop(target)
        return 200, {'room': current[2]} if decision == 'join' else {}

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
        if self.path in ('/vas/invite', '/vas/inbox'):
            self.do_invitation()
            return
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

    def do_invitation(self):
        header = self.headers.get('Authorization', '')
        if not header.startswith('Bearer '):
            self.reply({'error': 'authorization'}, 401)
            return
        token = header[7:]
        try:
            length = int(self.headers.get('Content-Length', '-1'))
            if not 1 <= length <= 512:
                raise ValueError()
            value = json.loads(self.rfile.read(length))
            if not isinstance(value, dict):
                raise ValueError()
        except (TypeError, ValueError):
            self.reply({'error': 'input'}, 400)
            return
        if self.path == '/vas/invite':
            room = moderator_room(token)
            if self.headers.get('Origin') != base or not room:
                self.reply({'error': 'authorization'}, 403)
                return
            device = value.get('id')
            if not isinstance(device, str) or not re.fullmatch(r'[A-Za-z0-9_-]{6,40}', device):
                self.reply({'error': 'input'}, 400)
                return
            status, result = send_invite(room, device)
        else:
            target = inbox_device(token)
            if not target:
                self.reply({'error': 'authorization'}, 401)
                return
            status, result = receive_invite(target, value)
        self.reply(result, status)

    def reply(self, payload, status=200):
        response = json.dumps(payload).encode()
        self.send_response(status)
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
