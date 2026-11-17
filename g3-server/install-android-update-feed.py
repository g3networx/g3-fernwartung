"""Install the Android version feed and optionally activate a staged APK."""

import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory
from urllib.request import HTTPRedirectHandler, ProxyHandler, build_opener


ROOT = Path('/opt/rustdesk-client')
FEED = ROOT / 'android-update.json'
SNIPPET = Path('/etc/nginx/snippets/opslinx-android-update.conf')
IMMUTABLE = SNIPPET.with_name('opslinx-immutable-artifacts.conf')
ARTIFACTS_INCLUDE = f'include {IMMUTABLE};'
NODES = {'rustdesk': 'rust.g3nx.net', 'opslinx02': 'opslinx02.g3nx.net', 'opslinx03': 'opslinx03.g3nx.net'}
CERTUM_SIGNER = '8182b64c243398abc093b5359743dfcc6cbbae9b397d9e109def321c2ae9e0ee'
FEED_LOCATION = '''location = /client/android/update.json {{
    alias {feed};
    types {{}}
    default_type application/json;
    add_header Cache-Control "no-store" always;
}}
'''
APK_LOCATION = '''location = /client/platform/android_arm64 {{
    alias {apk};
    types {{}}
    default_type application/vnd.android.package-archive;
    add_header Content-Disposition 'attachment; filename="{name}"';
    add_header Cache-Control "no-store" always;
    add_header X-Content-Type-Options "nosniff" always;
}}
'''


def atomic_write(path, content, mode):
    pending = None
    try:
        with NamedTemporaryFile(dir=path.parent, delete=False) as file:
            pending = Path(file.name)
            file.write(content)
        pending.chmod(mode)
        os.replace(pending, path)
    finally:
        if pending is not None:
            pending.unlink(missing_ok=True)


def checksum(stream, limit):
    digest = hashlib.sha256()
    size = 0
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        size += len(block)
        if size > limit:
            raise ValueError('Android artifact exceeds its declared size limit')
        digest.update(block)
    return size, digest.hexdigest()


def verify_certum(apk, proof):
    if not 0 < proof.stat().st_size <= 65_536:
        raise ValueError('Missing or oversized Certum signature')
    cms = ['openssl', 'cms', '-inform', 'DER', '-in', str(proof)]
    description = subprocess.check_output(cms + ['-cmsout', '-print'], text=True)
    if not re.search(r'(?m)^\s*eContent: <ABSENT>\s*$', description):
        raise ValueError('Expected detached Certum CMS signature')
    signer_description = description.split('signerInfos:', 1)[-1]
    if not re.search(r'digestAlgorithm:\s*\n\s*algorithm: sha256 \(2\.16\.840\.1\.101\.3\.4\.2\.1\)', signer_description):
        raise ValueError('Expected SHA-256 Certum signer digest')
    with TemporaryDirectory() as directory:
        signer = Path(directory) / 'signer.pem'
        subprocess.run(cms + ['-verify', '-binary', '-noverify', '-content', str(apk),
                              '-out', os.devnull, '-signer', str(signer)], check=True, capture_output=True)
        if signer.read_text().count('-----BEGIN CERTIFICATE-----') != 1:
            raise ValueError('Expected one Certum signer')
        fingerprint = subprocess.check_output(
            ['openssl', 'x509', '-in', str(signer), '-noout', '-sha256', '-fingerprint'], text=True)
        if fingerprint.strip().split('=', 1)[-1].replace(':', '').lower() != CERTUM_SIGNER:
            raise ValueError('Unexpected Android Certum signing certificate')
        start = subprocess.check_output(['openssl', 'x509', '-in', str(signer), '-noout', '-startdate'], text=True)
        if parsedate_to_datetime(start.strip().split('=', 1)[1]) > datetime.now(timezone.utc):
            raise ValueError('Certum signing certificate is not yet valid')
        subprocess.run(['openssl', 'x509', '-in', str(signer), '-noout', '-checkend', '0'],
                       check=True, capture_output=True)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def verify_cluster(build, apk_identity, proof_identity):
    opener = build_opener(ProxyHandler({}), NoRedirect())
    for host in NODES.values():
        for suffix, expected in (('.apk', apk_identity), ('.certum.p7s', proof_identity)):
            url = f'https://{host}/client/platform/android_arm64/{build}{suffix}'
            try:
                with opener.open(url, timeout=20) as response:
                    if response.status != 200 or checksum(response, expected[0]) != expected:
                        raise ValueError('artifact size or SHA-256 differs')
            except (OSError, ValueError) as error:
                raise RuntimeError(f'{host}: staged Android {build}{suffix} failed verification: {error}') from error


def stage_routes(config, build, apk, proof):
    for suffix, file, mime in (('.apk', apk, 'application/vnd.android.package-archive'),
                               ('.certum.p7s', proof, 'application/pkcs7-signature')):
        endpoint = f'/client/platform/android_arm64/{build}{suffix}'
        existing = re.search(r'(?m)^\s*location\s*=\s*' + re.escape(endpoint) + r'\s*\{([^{}]*(?:\{\}[^{}]*)*)\}', config)
        if existing:
            if f'alias {file};' not in existing[1]:
                raise ValueError(f'Conflicting immutable Android route: {endpoint}')
            continue
        config += f'''
location = {endpoint} {{
    alias {file};
    types {{}}
    default_type {mime};
    add_header Content-Disposition 'attachment; filename="{file.name}"';
    add_header X-Content-Type-Options "nosniff" always;
}}
'''
    return config


def site_path(name):
    site = Path('/etc/nginx/sites-enabled', name).resolve(strict=True)
    if site.parent != Path('/etc/nginx/sites-available'):
        raise ValueError('Unexpected nginx site path')
    return site


def main():
    modes = {'--stage-apk', '--verify-apk', '--activate-apk'}
    if (len(sys.argv) not in (2, 3) or sys.argv[1] not in NODES
            or (len(sys.argv) == 3 and sys.argv[2] not in modes)):
        raise SystemExit('Usage: install-android-update-feed.py SITE [--stage-apk|--verify-apk|--activate-apk] < release.json')
    mode = sys.argv[2] if len(sys.argv) == 3 else None
    site = site_path(sys.argv[1])

    metadata = json.load(sys.stdin)
    version, digest, size = (metadata[key] for key in ('version', 'sha256', 'size'))
    if (not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+-g3\.\d+(?:\.\d+)?', version)
            or not isinstance(digest, str) or not re.fullmatch(r'[a-f0-9]{64}', digest)
            or type(size) is not int or not 0 < size <= 150_000_000):
        raise SystemExit('Invalid Android release metadata')
    payload = (json.dumps(dict(version=version, sha256=digest, size=size)) + '\n').encode()
    feed = FEED
    if mode:
        name = f'g3-OpsLinX-Android-{version}-arm64.apk'
        build = re.fullmatch(r'\d+\.\d+\.\d+-g3\.\d+\.(\d+)', version)
        if not build or metadata.get('file') != name:
            raise SystemExit('Android release filename does not match the version')
        apk = ROOT / name
        if apk.is_symlink() or not apk.is_file() or apk.stat().st_size != size:
            raise SystemExit('Staged Android APK missing or incomplete')
        with apk.open('rb') as package:
            apk_identity = checksum(package, size)
        if apk_identity != (size, digest):
            raise SystemExit('Staged Android APK failed its SHA-256 check')
        proof = apk.with_name(name + '.certum.p7s')
        if proof.is_symlink() or not proof.is_file():
            raise SystemExit('Staged Android Certum signature missing')
        with proof.open('rb') as signature:
            proof_identity = checksum(signature, 65_536)
        if proof_identity[1] != metadata.get('certum_sha256'):
            raise SystemExit('Staged Android Certum signature failed its SHA-256 check')
        try:
            verify_certum(apk, proof)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            raise SystemExit(f'Invalid Android Certum signature: {error}') from error
        if mode == '--verify-apk':
            print(f'Android {version} APK and Certum signature verified')
            return
        if mode == '--activate-apk':
            verify_cluster(build[1], apk_identity, proof_identity)
        feed = apk.with_suffix('.json')
        config = (FEED_LOCATION.format(feed=feed) +
                  APK_LOCATION.format(apk=apk, name=name))
    else:
        if SNIPPET.exists() and '/client/platform/android_arm64' in SNIPPET.read_text():
            raise SystemExit('An APK is active. Supply its replacement with --activate-apk.')
        config = FEED_LOCATION.format(feed=feed)

    existing_site = site.read_text()
    include = f'include {SNIPPET};'
    if ARTIFACTS_INCLUDE not in existing_site:
        raise SystemExit('Existing OpsLinX location include missing')
    if include not in existing_site:
        updated_site = re.sub(r'(?m)^([ \t]*)(' + re.escape(ARTIFACTS_INCLUDE) + r'[^\n]*)$',
                              lambda match: match.group(0) + '\n' + match[1] + include,
                              existing_site)
    else:
        updated_site = existing_site

    if mode == '--stage-apk':
        desired = {IMMUTABLE: stage_routes(IMMUTABLE.read_text(), build[1], apk, proof).encode()}
    else:
        desired = {feed: payload, SNIPPET: config.encode(), site: updated_site.encode()}
    original = {path: (path.read_bytes(), path.stat().st_mode & 0o777)
                for path in desired if path.exists()}
    changes = {path: value for path, value in desired.items()
               if path not in original or original[path][0] != value}
    if not changes:
        print('Android update feed already configured')
        return

    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    for path in changes.keys() & original.keys():
        content, mode = original[path]
        atomic_write(path.with_name(f'{path.name}.before-android-feed-{stamp}'), content, mode)

    try:
        for path, value in changes.items():
            atomic_write(path, value, original[path][1] if path in original else 0o644)
        if any(path in changes for path in (SNIPPET, IMMUTABLE, site)):
            subprocess.run(['nginx', '-t'], check=True)
            subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
    except Exception:
        for path in reversed(list(changes)):
            if path in original:
                atomic_write(path, *original[path])
            else:
                path.unlink(missing_ok=True)
        raise
    print(f'Android {version} {"artifacts staged" if mode == "--stage-apk" else "update feed configured"}. Backup suffix: {stamp}')


if __name__ == '__main__':
    main()
