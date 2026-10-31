"""Build g3.34 UI packages with the unchanged accepted wallpaper native core."""
from pathlib import Path
import hashlib, io, json, os, shutil, subprocess, sys, zipfile

root=Path.cwd(); out=root/'outputs';out.mkdir(exist_ok=True)
archive=Path(os.environ['G3_WALLPAPER_ACCEPTED_ARCHIVE'])
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='a329b203fa8735110068172981a49bb293ec8e57077dce2a67c2ee5bbcd35df3'
assert not subprocess.check_output(['git','diff','8d39c46438df0d06cbc186897767f713769dbd6a','HEAD','--','src','libs','Cargo.toml','Cargo.lock']).strip()
with zipfile.ZipFile(archive) as z:
 provenance=json.loads(z.read('corrected-core-provenance.json'))
 with zipfile.ZipFile(io.BytesIO(z.read('g3-wallpaper-corrected-native-test-payload.zip'))) as binaries:
  if sys.argv[1]=='prepare':
   native=root/'target/release';native.mkdir(parents=True,exist_ok=True)
   (native/'librustdesk.dll').write_bytes(binaries.read('librustdesk.dll'))
   (out/'g3Host.exe').write_bytes(binaries.read('g3Host.exe'))
   assert hashlib.sha256((native/'librustdesk.dll').read_bytes()).hexdigest()==provenance['native_sha256']
   sys.exit(0)
payload=root/'flutter/build/windows/x64/runner/Release'
assert hashlib.sha256((payload/'librustdesk.dll').read_bytes()).hexdigest()==provenance['native_sha256']
shutil.copy2(root/'LICENCE',payload/'LICENCE')
(payload/'SOURCE.txt').write_text('https://github.com/g3networx/g3-fernwartung/tree/'+os.environ['GITHUB_SHA']+'\n')
(root/'src/version.rs').write_text('pub const BUILD_DATE: &str = "2026-10-31";\n')
subprocess.run(['python','g3-build/package-msi.py','--version','1.5.0-g3.34'],check=True)
subprocess.run(['python','g3-build/build-setup-launchers.py','--version','1.5.0-g3.34'],check=True)
provenance.update(version='1.5.0-g3.34',packaging_source_commit=os.environ['GITHUB_SHA'],frontend_source_commit=os.environ['GITHUB_SHA'],packaging_run=os.environ['GITHUB_RUN_ID'],native_build_run=41065143187,native_rebuilt=False,frontends_rebuilt=True,practical_tests_waived_by_user=True,practical_tests_verified=False)
(out/'g334-release-provenance.json').write_text(json.dumps(provenance,indent=2))
items={p.name:dict(file=p.name,size=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in out.glob('g3-OpsLinX-*') if p.suffix in ('.exe','.msi')}
assert len(items)==4
(out/'g334-package-hashes.json').write_text(json.dumps(items,indent=2))
