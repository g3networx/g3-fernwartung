"""Build-only g3.6 packages with additive managed password policy."""
from pathlib import Path
import hashlib, io, json, os, shutil, subprocess, sys, zipfile

root=Path.cwd();out=root/'outputs';out.mkdir(exist_ok=True)
archive=Path(os.environ['G3_WALLPAPER_ACCEPTED_ARCHIVE'])
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='a329b203fa8735110068172981a49bb293ec8e57077dce2a67c2ee5bbcd35df3'
changed=set(subprocess.check_output(['git','diff','--name-only','27a4d29d3958dc3759501f847a69d13a71fb9e9c','HEAD','--','src','libs','Cargo.toml','Cargo.lock'],text=True).splitlines())
assert changed=={'src/platform/windows.rs','src/platform/windows_logon.rs','src/g3_bootstrap.rs','src/g3_sessions.rs','src/tray.rs','src/server/connection.rs','src/g3_passwords.rs','src/core_main.rs'},changed
if sys.argv[1]=='prepare':
 with zipfile.ZipFile(archive) as z:
  with zipfile.ZipFile(io.BytesIO(z.read('g3-wallpaper-corrected-native-test-payload.zip'))) as payload:
   host=payload.read('g3Host.exe')
   assert hashlib.sha256(host).hexdigest()=='32b98ed09a141e92ac2f2d602401c5e417a1511c7f494824424fe90ff78c03d0'
   (out/'g3Host.exe').write_bytes(host)
 sys.exit(0)
provenance=json.loads((out/'upn-core-provenance.json').read_text(encoding='utf-8-sig'))
assert provenance['source_commit']==os.environ['GITHUB_SHA'] and provenance['native_rebuilt']
payload=root/'flutter/build/windows/x64/runner/Release'
assert hashlib.sha256((payload/'librustdesk.dll').read_bytes()).hexdigest()==provenance['native_sha256']
assert (payload/'dylib_virtual_display.dll').is_file()
shutil.copy2(root/'LICENCE',payload/'LICENCE')
(payload/'SOURCE.txt').write_text('https://github.com/g3networx/g3-fernwartung/tree/'+os.environ['GITHUB_SHA']+'\n')
(root/'src/version.rs').write_text('pub const BUILD_DATE: &str = "2026-11-03";\n')
for script in ('package-msi.py','build-setup-launchers.py'):
 subprocess.run(['python','g3-build/'+script,'--version','1.5.0-g3.60.19985'],check=True)
provenance.update(display_version='g3.6 Build 031126',version='1.5.0-g3.60.19985',packaging_source_commit=os.environ['GITHUB_SHA'],frontend_source_commit=os.environ['GITHUB_SHA'],frontends_rebuilt=True,published=False,actual_corrected_client_remote_powershell_tested=False)
(out/'g36-release-provenance.json').write_text(json.dumps(provenance,indent=2))
items={p.name:dict(file=p.name,size=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in out.glob('g3-OpsLinX-*') if p.suffix in ('.exe','.msi')}
assert len(items)==4
(out/'g36-package-hashes.json').write_text(json.dumps(items,indent=2))
