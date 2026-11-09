"""Package the accepted Windows runtime as the isolated portable Soforthilfe."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--payload', type=Path, required=True)
parser.add_argument('--stage', type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
release = json.loads((root / 'g3-build/local-addressbook-release.json').read_text())
stage = args.stage.resolve()
stage.mkdir(parents=True, exist_ok=False)
payload = stage / 'payload'
shutil.copytree(args.payload, payload)
for path in payload.rglob('*'):
    if path.is_file() and (path.suffix.lower() in ('.pdb', '.lock') or path.name == 'meta.toml'):
        path.unlink()
native = hashlib.sha256((payload / 'librustdesk.dll').read_bytes()).hexdigest()
frontend = hashlib.sha256((payload / 'rustdesk.exe').read_bytes()).hexdigest()
(payload / 'rustdesk.exe').rename(payload / 'g3soforthilfe.exe')
packer = stage / 'libs/portable'
shutil.copytree(root / 'libs/portable', packer, ignore=shutil.ignore_patterns('target', 'data.bin', 'app_metadata.toml'))
(stage / 'res').mkdir()
shutil.copy2(root / 'flutter/windows/runner/resources/app_icon.ico', stage / 'res/icon.ico')
shutil.copy2(root / 'res/manifest.xml', stage / 'res/manifest.xml')
build = packer / 'build.rs'
build.write_text(build.read_text().replace('g3 OpsLinX Setup', 'g3 OpsLinX Soforthilfe')
                 .replace('.set("ProductName", "g3 OpsLinX")',
                          '.set("ProductName", "g3 OpsLinX")\n'
                          f'            .set("ProductVersion", "{release["windowsVersion"]}")\n'
                          f'            .set("FileVersion", "{release["windowsVersion"]}")'))
(stage / 'provenance.json').write_text(json.dumps(dict(
    version=release['version'], displayVersion=release['displayVersion'],
    nativeInputSha256=native, frontendInputSha256=frontend,
    incomingOnly=True, installationDisabled=True,
    namespace='g3Soforthilfe', payloadExecutable='g3soforthilfe.exe',
    file='g3-Soforthilfe-' + release['version'] + '-adhoc.exe',
), indent=2))
print(json.dumps(dict(stage=str(stage), nativeSha256=native, frontendSha256=frontend)))
