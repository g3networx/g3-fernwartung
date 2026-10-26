"""Recompile only setup wrappers around the immutable accepted g3.32 payload."""
from pathlib import Path
import hashlib, zipfile, io, subprocess, shutil, json, os

root=Path.cwd(); archive=Path(os.environ['G3_ACCEPTED_ARCHIVE'])
assert hashlib.sha256(archive.read_bytes()).hexdigest()=='7c5146c80f5f20912bf2f275d747271f3e3605c426aee3251f80ede61f6b7621'
out=root/'outputs';out.mkdir(exist_ok=True)
payload=root/'flutter/build/windows/x64/runner/Release';payload.mkdir(parents=True,exist_ok=True)
for kind in ('windows','host'):(root/'g3-build/msi'/kind).mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(archive) as z:
 for name in ('g3-OpsLinX-1.5.0-g3.32-install.msi','g3-OpsLinX-Host-1.5.0-g3.32-host-install.msi','g3Host.exe','g3-windows-unsigned.zip'):
  (out/name).write_bytes(z.read(name))
 with zipfile.ZipFile(io.BytesIO(z.read('g3-windows-unsigned.zip'))) as native:
  native.extractall(payload)
assert hashlib.sha256((payload/'librustdesk.dll').read_bytes()).hexdigest()=='ad10a1fce5bebbf0e834c0362ae19a24977c4c3b92ecd14fc9b463f1346d3385'
subprocess.run(['python','g3-build/build-setup-launchers.py','--version','1.5.0-g3.32'],check=True)
(out/'bootstrap-only-provenance.json').write_text(json.dumps({'bootstrap_source_commit':os.environ['GITHUB_SHA'],'native_source_commit':'f680ca3fb6a7fc1d16d495559f54ea4887f57e83','accepted_baseline_run':40189469079,'native_rebuilt':False,'msi_rebuilt':False,'original_public_artifacts_replaced':False},indent=2))
