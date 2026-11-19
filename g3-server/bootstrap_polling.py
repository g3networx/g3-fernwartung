"""Bound bootstrap writes and use the existing device credential for heartbeats."""
import base64
import hmac
import json
import re
import threading
import time

from flask import abort, g, request, Response


class BootstrapTraffic:
    def __init__(self):
        self.lock = threading.Lock()
        self.window = None
        self.counts = {}
        self.cleanup_after = 0

    def limited(self, key, maximum=120):
        # Worker-local and bounded; no writes to the shared SQLite database.
        now = time.monotonic()
        window = int(now // 900)
        with self.lock:
            if self.window != window:
                self.counts.clear()
                self.window = window
            if ((key not in self.counts and len(self.counts) >= 4096)
                    or self.counts.get(key, 0) >= maximum):
                abort(Response(status=429, headers={'Retry-After': '900'}))
            self.counts[key] = self.counts.get(key, 0) + 1

    def cleanup(self, portal):
        with self.lock:
            now = time.monotonic()
            if now < self.cleanup_after:
                return
            self.cleanup_after = now + 300
        portal.run('DELETE FROM bootstrap_challenges WHERE expires<?', (int(time.time()),))


def heartbeat_token(app, native_id, public_key, expires=None):
    expires = int(time.time()) + 86400 if expires is None else expires
    stamp = expires.to_bytes(8, 'big')
    secret = app.secret_key.encode() if isinstance(app.secret_key, str) else app.secret_key
    message = b'OpsLinX heartbeat v1\0' + native_id.encode() + b'\0' + public_key + stamp
    mac = hmac.digest(secret, message, 'sha256')
    return base64.urlsafe_b64encode(stamp + mac).decode().rstrip('=')


def heartbeat(app, portal, data, traffic):
    authorization = request.headers.get('Authorization', '')
    if not re.fullmatch(r'Bearer [A-Za-z0-9_-]{54}', authorization):
        abort(404)
    native_id = data.get('id', '')
    if not isinstance(native_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]{6,40}', native_id):
        abort(404)
    device = portal.db().execute('SELECT * FROM devices WHERE rustdesk_id=?', (native_id,)).fetchone()
    if not device:
        abort(404)
    try:
        key = bytes.fromhex(json.loads(
            (portal.DATA / 'peer-public-keys.json').read_text(encoding='utf-8')
        )[device['rustdesk_id']])
        if len(key) != 32:
            abort(404)
    except (OSError, KeyError, ValueError, TypeError):
        abort(404)
    stamp = int.from_bytes(base64.urlsafe_b64decode(authorization[7:] + '==')[:8], 'big')
    if stamp <= time.time() or not hmac.compare_digest(
        authorization[7:], heartbeat_token(app, native_id, key, stamp)
    ):
        abort(404)
    traffic.limited(('heartbeat', device['id']), 60)
    g.verified_device_id = device['id']
    response = app.config['ACTIVITY_OFFER'](device['id'], True)
    response.update(app.config['CREDENTIAL_OFFER'](device['id']))
    response['registered'] = True
    management = app.config.get('DEVICE_MANAGEMENT_BOOTSTRAP_RESPONSE')
    return management(data, device['id'], device['rustdesk_id'], key, response) if management else response
