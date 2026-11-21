"""Test the final Debian package's installed menu entry and actual GTK window title."""

from hashlib import sha256
import json
import os
from pathlib import Path
import platform
import re
from shutil import copyfile
from subprocess import DEVNULL, check_output, run
import sys
from tempfile import TemporaryDirectory


ROOT = Path.cwd()
arch = os.environ['PACKAGE_ARCH']
assert platform.machine() == arch
inputs = ROOT / 'input'
source = json.loads((inputs / f'platform-provenance-linux-{arch}.json').read_text())
assert source['platform'] == 'linux' and source['arch'] == arch
assert str(source['run_id']) == os.environ['SOURCE_RUN']
assert re.fullmatch(r'\d+\.\d+\.\d+-g3\.\d+\.\d+', source['version'])
original, = source['files']
original_package = inputs / original['file']
assert original_package.parent == inputs and original_package.name.startswith('g3-OpsLinX-')
assert sha256(original_package.read_bytes()).hexdigest() == original['sha256']

# Preserve the native build and assign an installable Debian revision to the branding fix.
version = source['version'] + '+1'
out = ROOT / 'verified'
out.mkdir(exist_ok=True)
package = out / f'g3-OpsLinX-{version}-linux-{arch}.deb'
run([sys.executable, str(ROOT / 'g3-build/repack-linux.py'), str(original_package)],
    cwd=out, env=dict(os.environ, VERSION=version), check=True)
debian_arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}[arch]
for field, expected in {'Package': 'g3fernwartung', 'Architecture': debian_arch, 'Version': version}.items():
    assert check_output(['dpkg-deb', '-f', package, field], text=True).strip() == expected
run(['dpkg', '--compare-versions', version, 'gt', source['version']], check=True)

with TemporaryDirectory(prefix='opslinx-branding-') as scratch:
    lab = Path(scratch)
    copyfile(package, lab / 'client.deb')
    (lab / 'Dockerfile').write_text('''FROM ubuntu:22.04
COPY client.deb /tmp/client.deb
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/client.deb \\
    xvfb xauth dbus-x11 openbox python3-gi libglib2.0-bin x11-utils xdotool libegl1-mesa libgles2-mesa
COPY check.sh /check.sh
''')
    (lab / 'check.sh').write_text(r'''#!/bin/bash
set -eu
export XDG_RUNTIME_DIR=/tmp/g3-runtime LIBGL_ALWAYS_SOFTWARE=1 XDG_CURRENT_DESKTOP=OPENBOX
install -m 700 -d "$XDG_RUNTIME_DIR"
python3 - <<'PY'
from gi.repository import Gio
matching = [app for app in Gio.AppInfo.get_all() if app.get_id() == 'g3fernwartung.desktop']
entry, = matching
assert entry.should_show() and entry.get_display_name() == 'g3 OpsLinX', entry.get_display_name()
print('Application menu: ' + entry.get_display_name())
PY
dbus-run-session -- xvfb-run -a bash -ec '
  openbox >/tmp/window-manager.log 2>&1 &
  gio launch /usr/share/applications/g3fernwartung.desktop
  window=$(timeout 45s xdotool search --sync --onlyvisible --name "^g3 OpsLinX$" | head -n1)
  test -n "$window"
  sleep 8
  test "$(xdotool getwindowname "$window")" = "g3 OpsLinX"
  printf "Window title: %s\n" "$(xdotool getwindowname "$window")"
'
''')
    image = f'g3-linux-branding:{os.environ["GITHUB_RUN_ID"]}-{debian_arch}'
    try:
        run(['docker', 'build', '-t', image, lab], check=True)
        run(['docker', 'run', '--rm', '--network', 'none', image, 'bash', '/check.sh'], check=True)
    finally:
        run(['docker', 'image', 'rm', image], stdout=DEVNULL, stderr=DEVNULL)

result = {
    'arch': arch, 'version': version, 'source': source, 'tested_os': 'Ubuntu 22.04',
    'validation_run': os.environ['GITHUB_RUN_ID'], 'validation_commit': os.environ['GITHUB_SHA'],
    'window_title': 'g3 OpsLinX', 'application_menu': 'g3 OpsLinX',
    'file': package.name, 'size': package.stat().st_size, 'sha256': sha256(package.read_bytes()).hexdigest(),
}
(out / 'branding.json').write_text(json.dumps(result, indent=2))
