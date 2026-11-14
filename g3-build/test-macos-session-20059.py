"""Test the published Apple Silicon DMG against a disposable Linux lab desktop."""

from hashlib import sha256
from io import BytesIO
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import sys
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from zipfile import ZipFile

WORK = Path('session-20059').resolve()
WORK.mkdir(mode=0o700, exist_ok=True)
BASE = 'https://linx.g3nx.net/client/platform/'
MAC_SHA = '760512dd4b9f4f60f630cb845150329fa53c1591e2fe5a484b4341d7212fce0e'
LINUX_SHA = 'd6a754fed13478727929b36cf114fc02ca9af0fb0667b7e27553f112aad91024'
COLORS = ((101, 65, 172), (26, 156, 68))
TARGET = 'opslinx-test-target'


class SafeRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected and urlsplit(req.full_url).netloc != urlsplit(newurl).netloc:
            redirected.remove_header('Authorization')
        return redirected


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def fetch(url, token=None):
    request = Request(url, headers={'Authorization': f'Bearer {token}'} if token else {})
    with build_opener(SafeRedirect()).open(request, timeout=60) as response:
        return response.read()


def download(kind, digest, filename):
    payload = fetch(BASE + kind)
    assert sha256(payload).hexdigest() == digest, 'Published package digest mismatch'
    path = WORK / filename
    path.write_bytes(payload)
    return path


def artifact(name, entry=None, timeout=480):
    repo = os.environ['GITHUB_REPOSITORY']
    run_id = os.environ['GITHUB_RUN_ID']
    attempt = os.environ['GITHUB_RUN_ATTEMPT']
    token = os.environ['GH_TOKEN']
    url = f'https://api.github.com/repos/{repo}/actions/runs/{run_id}/artifacts'
    end = time.monotonic() + timeout
    while True:
        items = json.loads(fetch(url, token))['artifacts']
        for item in items:
            if item['name'] == f'{name}-{attempt}' and not item['expired']:
                if entry is None:
                    return True
                payload = fetch(item['archive_download_url'], token)
                assert 'sha256:' + sha256(payload).hexdigest() == item['digest']
                with ZipFile(BytesIO(payload)) as zipped:
                    return zipped.read(entry)
        if time.monotonic() >= end:
            return None
        time.sleep(8)


def prepare():
    run('openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:3072',
        '-out', str(WORK / 'viewer-private.pem'), stderr=subprocess.DEVNULL)
    run('openssl', 'pkey', '-in', str(WORK / 'viewer-private.pem'), '-pubout',
        '-out', str(WORK / 'viewer-public.pem'))


def target():
    download('linux_x86_64', LINUX_SHA, 'client.deb')
    (WORK / 'Dockerfile').write_text(
        'FROM ubuntu:22.04\n'
        'COPY client.deb /tmp/client.deb\n'
        'RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y '
        '/tmp/client.deb xvfb xauth dbus-x11 x11-xserver-utils xdotool openbox libegl1-mesa libgles2-mesa\n'
        'ENV DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus\n'
        'COPY start.sh /start.sh\nCMD ["bash","/start.sh"]\n'
    )
    (WORK / 'start.sh').write_text(
        'set -e\ndbus-uuidgen > /etc/machine-id\n'
        'mkdir -p /run/user/0 /var/lib/dbus; chmod 700 /run/user/0\n'
        'cp /etc/machine-id /var/lib/dbus/machine-id\n'
        'Xvfb :0 -screen 0 1280x1024x24 &\nsleep 2\n'
        'dbus-daemon --session --address=unix:path=/run/user/0/bus --fork\n'
        'openbox &\nexec /usr/bin/g3fernwartung\n'
    )
    run('docker', 'build', '-t', TARGET, str(WORK), stdout=subprocess.DEVNULL)
    run('docker', 'run', '-d', '--name', TARGET, TARGET, stdout=subprocess.DEVNULL)
    time.sleep(12)
    password = secrets.token_urlsafe(24)
    print(f'::add-mask::{password}', flush=True)
    response = run('docker', 'exec', '-i', TARGET, '/usr/bin/g3fernwartung', '--password-stdin',
                   input=password + '\n', text=True, capture_output=True, timeout=30)
    assert 'confirmed' in response.stdout.lower(), 'Target service did not confirm its test password'
    peer = run('docker', 'exec', TARGET, '/usr/bin/g3fernwartung', '--get-id',
               text=True, capture_output=True, timeout=30).stdout.strip()
    assert re.fullmatch(r'[0-9]{9,10}', peer)
    key = artifact('viewer-public-key', 'viewer-public.pem')
    assert key
    (WORK / 'viewer-public.pem').write_bytes(key)
    run('openssl', 'pkeyutl', '-encrypt', '-pubin', '-inkey', str(WORK / 'viewer-public.pem'),
        '-pkeyopt', 'rsa_padding_mode:oaep', '-out', str(WORK / 'target.enc'),
        input=json.dumps({'peer': peer, 'password': password}).encode())
    run('docker', 'exec', TARGET, 'bash', '-c',
        'for w in $(xdotool search --class g3fernwartung 2>/dev/null || '
        'xdotool search --class rustdesk 2>/dev/null); do xdotool windowunmap "$w" || true; done')
    print('Target registered and encrypted test handoff prepared.')


def animate():
    for cycle in range(15):
        color = COLORS[cycle % len(COLORS)]
        run('docker', 'exec', TARGET, 'xsetroot', '-solid', '#%02x%02x%02x' % color)
        if artifact('viewer-result', timeout=20):
            return
    raise SystemExit('Viewer did not report a passing session')


def viewer():
    from PIL import Image

    assert run('uname', '-m', capture_output=True, text=True).stdout.strip() == 'arm64'
    os_version = run('sw_vers', '-productVersion', capture_output=True, text=True).stdout.strip()
    dmg = download('macos_arm64', MAC_SHA, 'client.dmg')
    mount = WORK / 'mount'
    mount.mkdir(exist_ok=True)
    run('hdiutil', 'attach', str(dmg), '-readonly', '-nobrowse', '-mountpoint', str(mount))
    try:
        app, = mount.glob('*.app')
        run('ditto', str(app), str(WORK / app.name))
    finally:
        run('hdiutil', 'detach', str(mount))
    app = WORK / app.name
    run('codesign', '--verify', '--deep', '--strict', str(app))
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['G3BuildVersion'] == '1.5.3-g3.62.20059'
    executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
    encrypted = artifact('encrypted-target', 'target.enc')
    assert encrypted
    decoded = run('openssl', 'pkeyutl', '-decrypt', '-inkey', str(WORK / 'viewer-private.pem'),
                  '-pkeyopt', 'rsa_padding_mode:oaep', input=encrypted, capture_output=True)
    target_info = json.loads(decoded.stdout)
    print(f'::add-mask::{target_info["password"]}', flush=True)
    process = subprocess.Popen([str(executable), '--connect', target_info['peer'],
                                '--password', target_info['password']],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        best = [0.0, 0.0]
        frame = WORK / 'frame.png'
        for _ in range(66):
            time.sleep(3)
            run('screencapture', '-x', str(frame), capture_output=True)
            with Image.open(frame) as screen:
                pixels = list(screen.convert('RGB').resize((320, 200)).getdata())
            frame.unlink(missing_ok=True)
            for index, color in enumerate(COLORS):
                fraction = sum(all(abs(a - b) <= 12 for a, b in zip(pixel, color))
                               for pixel in pixels) / len(pixels)
                best[index] = max(best[index], fraction)
            if min(best) > 0.12:
                result = dict(passed=True, macos=os_version, architecture='arm64',
                              published_dmg_sha256=MAC_SHA, observed_frame_fractions=best)
                (WORK / 'result.json').write_text(json.dumps(result, indent=2))
                print(json.dumps(result))
                return
        raise SystemExit(f'Expected live desktop frames did not arrive. Observed fractions: {best}')
    finally:
        if process.poll() is None:
            process.terminate()
        (WORK / 'viewer-private.pem').unlink(missing_ok=True)


{'prepare': prepare, 'target': target, 'animate': animate, 'viewer': viewer}[sys.argv[1]]()
