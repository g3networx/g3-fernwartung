"""Rebuild wrappers only; retain exact accepted g3.40.1 MSIs and runtime."""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, zipfile

root=Path.cwd(); out=root/'outputs';out.mkdir(exist_ok=True)
archive=Path(os.environ['G3_POWERSHELL_ACCEPTED_ARCHIVE'])
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='c38db1b31ddf02b24abad88efb15a18809803c4623f696d949611ab0d8053a36'
with zipfile.ZipFile(archive) as z:
 metadata=json.loads(z.read('g3401-package-hashes.json'))
 provenance=json.loads(z.read('g3401-release-provenance.json'))
 for name,item in metadata.items():
  data=z.read(name);assert len(data)==item['size'] and hashlib.sha256(data).hexdigest()==item['sha256'];(out/name).write_bytes(data)
 (out/'g3Host.exe').write_bytes(z.read('g3Host.exe'))
msi=out/'g3-OpsLinX-1.5.0-g3.40.1-install.msi'
image=Path(os.environ['RUNNER_TEMP'])/'g3401-accepted-admin-image';image.mkdir()
assert os.environ.get('GITHUB_ACTIONS')=='true' and os.environ.get('RUNNER_ENVIRONMENT')=='github-hosted'
subprocess.run(['msiexec.exe','/a',str(msi),'/qn','TARGETDIR='+str(image),'REBOOT=ReallySuppress'],check=True)
executables=list(image.rglob('g3Fernwartung.exe'));assert len(executables)==1
payload=root/'flutter/build/windows/x64/runner/Release'
shutil.copytree(executables[0].parent,payload)
(payload/'g3Fernwartung.exe').rename(payload/'rustdesk.exe')
assert hashlib.sha256((payload/'rustdesk.exe').read_bytes()).hexdigest()=='358c0093c2b45c3e20f2bd1b4e2684866e93d6e0a57391beb3c6cf79798bf236'
assert hashlib.sha256((payload/'librustdesk.dll').read_bytes()).hexdigest()=='ce2b6fef64620cb3ee2918d7245259edd758059dadf8f6437a2d47b72426fbec'
assert hashlib.sha256((out/'g3Host.exe').read_bytes()).hexdigest()=='32b98ed09a141e92ac2f2d602401c5e417a1511c7f494824424fe90ff78c03d0'
for kind in ('windows','host'):(root/'g3-build/msi'/kind).mkdir(parents=True,exist_ok=True)
subprocess.run(['python','g3-build/build-setup-launchers.py','--version','1.5.0-g3.40.1'],check=True)
for name,item in metadata.items():
 if name.endswith('.msi'):assert hashlib.sha256((out/name).read_bytes()).hexdigest()==item['sha256']
provenance.update(packaging_source_commit=os.environ['GITHUB_SHA'],packaging_run=os.environ['GITHUB_RUN_ID'],frontend_source_commit='4ade098007b00d17187dc0ff8ca13afc7c8b14cb',native_rebuilt=False,frontends_rebuilt=False,msi_rebuilt=False,bootstrap_only=True,accepted_baseline_run=41243021537)
(out/'g3401-release-provenance.json').write_text(json.dumps(provenance,indent=2))
items={p.name:dict(file=p.name,size=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()) for p in out.glob('g3-OpsLinX-*') if p.suffix in ('.exe','.msi')}
assert len(items)==4
(out/'g3401-package-hashes.json').write_text(json.dumps(items,indent=2))
