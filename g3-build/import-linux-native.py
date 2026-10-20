"""Reuse a verified native core only when its sources are unchanged."""
from pathlib import Path
import json,hashlib,subprocess,tempfile,shutil
record=json.loads(Path('input/validation.json').read_text());package=Path('input')/record['files'][0]['file'];assert hashlib.sha256(package.read_bytes()).hexdigest()==record['files'][0]['sha256']
source=record['source']['source_commit'];subprocess.run(['git','fetch','--no-tags','--depth=1','origin',source],check=True)
subprocess.run(['git','diff','--exit-code',source,'HEAD','--','src','libs','Cargo.toml','Cargo.lock','build.rs','g3-build/hbb-common.patch'],check=True)
with tempfile.TemporaryDirectory() as tmp:
 subprocess.run(['dpkg-deb','-x',str(package),tmp],check=True);lib=Path(tmp)/'usr/share/g3fernwartung/lib/librustdesk.so';assert lib.is_file()
 out=Path('target/release');out.mkdir(parents=True,exist_ok=True);shutil.copy2(lib,out/'liblibrustdesk.so');digest=hashlib.sha256(lib.read_bytes()).hexdigest()
Path('g3-native-source.json').write_text(json.dumps({'source_commit':source,'validation_run':record['finalization_run'],'package_sha256':record['files'][0]['sha256'],'library_sha256':digest},indent=2))
print('Verified native core reused; no Rust recompilation')
