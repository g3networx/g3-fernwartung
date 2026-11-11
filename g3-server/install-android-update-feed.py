"""Install the public Android version feed without publishing the APK."""

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from tempfile import NamedTemporaryFile


FEED = Path('/opt/rustdesk-client/android-update.json')
SNIPPET = Path('/etc/nginx/snippets/opslinx-android-update.conf')
ARTIFACTS_INCLUDE = 'include /etc/nginx/snippets/opslinx-immutable-artifacts.conf;'
CONFIG = f'''location = /client/android/update.json {{
    alias {FEED};
    types {{}}
    default_type application/json;
    add_header Cache-Control "no-store" always;
}}
'''


def atomic_write(path, content, mode):
    with NamedTemporaryFile(dir=path.parent, delete=False) as file:
        pending = Path(file.name)
        try:
            file.write(content)
            file.flush()
            os.fchmod(file.fileno(), mode)
            os.replace(pending, path)
        finally:
            pending.unlink(missing_ok=True)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in {'rustdesk', 'opslinx02', 'opslinx03'}:
        raise SystemExit('Usage: install-android-update-feed.py SITE < release.json')
    site_name = sys.argv[1]
    site = Path('/etc/nginx/sites-enabled', site_name).resolve(strict=True)
    if site.parent != Path('/etc/nginx/sites-available'):
        raise SystemExit('Unexpected nginx site path')

    metadata = json.load(sys.stdin)
    version, digest, size = (metadata[key] for key in ('version', 'sha256', 'size'))
    if (not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+-g3\.\d+(?:\.\d+)?', version)
            or not isinstance(digest, str) or not re.fullmatch(r'[a-f0-9]{64}', digest)
            or type(size) is not int or not 0 < size <= 150_000_000):
        raise SystemExit('Invalid Android release metadata')
    payload = (json.dumps(dict(version=version, sha256=digest, size=size)) + '\n').encode()

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

    desired = {FEED: payload, SNIPPET: CONFIG.encode(), site: updated_site.encode()}
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
        if SNIPPET in changes or site in changes:
            subprocess.run(['nginx', '-t'], check=True)
            subprocess.run(['systemctl', 'reload', 'nginx'], check=True)
    except Exception:
        for path in reversed(list(changes)):
            if path in original:
                atomic_write(path, *original[path])
            else:
                path.unlink(missing_ok=True)
        raise
    print(f'Android update feed configured for {version}. Backup suffix: {stamp}')


if __name__ == '__main__':
    main()
