"""Reuse the accepted native macOS core; rebuild current branded Flutter UI."""
from pathlib import Path
import hashlib,json,os,shutil,subprocess,sys,tempfile

root=Path.cwd(); arch=sys.argv[1]
assert arch in ('x86_64','aarch64')
def run(args,**kw): return subprocess.run(args,check=True,**kw)
def git(*args): return subprocess.check_output(['git',*args])
def unsigned_hash(path):
 with tempfile.TemporaryDirectory() as t:
  copy=Path(t)/path.name;shutil.copy2(path,copy)
  subprocess.run(['codesign','--remove-signature',str(copy)],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  return hashlib.sha256(copy.read_bytes()).hexdigest()
review=json.loads((root/'g3-build/macos-native-reuse.json').read_text())
base=review['native_commit']
changed=git('diff','--name-only',base,'HEAD','--','src','libs','Cargo.toml','Cargo.lock','build.rs').decode().splitlines()
allowed=set(review['reviewed_windows_only_diffs'])|{'src/g3_update_gate.rs','src/platform/windows.rs'}
assert set(changed)<=allowed, 'Unreviewed native change; full native rebuild required'
for name,digest in review['reviewed_windows_only_diffs'].items():
 assert hashlib.sha256(git('diff',base,'HEAD','--',name)).hexdigest()==digest, 'Native diff changed: '+name
for name in ('flutter/lib/generated_bridge.dart','src/bridge_generated.rs'):
 if Path(name).exists(): assert git('show',base+':'+name)==Path(name).read_bytes(), 'FFI ABI changed'
records=list((root/'input').glob('platform-provenance-*.json'));assert len(records)==1
native=json.loads(records[0].read_text())
assert native['source_commit']==base and str(native['run_id'])=='39383565494'
assert native['platform']=='macos' and native['arch']==arch and len(native['files'])==1
item=native['files'][0];dmg=root/'input'/item['file']
assert dmg.stat().st_size==item['size'] and hashlib.sha256(dmg.read_bytes()).hexdigest()==item['sha256']
target=root/'target/release';target.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory() as t:
 mount=Path(t)/'mount';mount.mkdir()
 run(['hdiutil','attach',str(dmg),'-readonly','-nobrowse','-mountpoint',str(mount)])
 try:
  apps=list(mount.glob('*.app'));assert len(apps)==1
  lib=apps[0]/'Contents/Frameworks/liblibrustdesk.dylib'
  assert subprocess.check_output(['lipo','-archs',str(lib)],text=True).strip()=={'aarch64':'arm64','x86_64':'x86_64'}[arch]
  shutil.copy2(lib,target/'liblibrustdesk.dylib')
  service=apps[0]/'Contents/MacOS/service'
  if service.exists():shutil.copy2(service,target/'service')
 finally:run(['hdiutil','detach',str(mount)])
native_hash=hashlib.sha256((target/'liblibrustdesk.dylib').read_bytes()).hexdigest()
native_unsigned=unsigned_hash(target/'liblibrustdesk.dylib')
run(['flutter','pub','get'],cwd=root/'flutter')
env=dict(os.environ,FLUTTER_XCODE_ARCHS={'aarch64':'arm64','x86_64':'x86_64'}[arch],FLUTTER_XCODE_ONLY_ACTIVE_ARCH='YES')
run(['flutter','build','macos','--release'],cwd=root/'flutter',env=env)
app=root/'flutter/build/macos/Build/Products/Release/g3Fernwartung.app'
assert app.exists()
if (target/'service').exists():shutil.copy2(target/'service',app/'Contents/MacOS/service')
assert unsigned_hash(app/'Contents/Frameworks/liblibrustdesk.dylib')==native_unsigned, 'Native core changed beyond ad-hoc signature'
run(['codesign','--force','--deep','--sign','-',str(app)])
version=os.environ['VERSION'];out=root/f'g3-Fernwartung-{version}-macos-{arch}.dmg'
with tempfile.TemporaryDirectory() as t:
 stage=Path(t);run(['ditto',str(app),str(stage/app.name)]);(stage/'Applications').symlink_to('/Applications')
 run(['hdiutil','create','-volname','g3 Fernwartung','-srcfolder',str(stage),'-ov','-format','UDZO',str(out)])
(root/'g3-native-source.json').write_text(json.dumps(dict(native,library_sha256=native_hash,unsigned_library_sha256=native_unsigned,reviewed_windows_only_diffs=review['reviewed_windows_only_diffs']),indent=2))
run([sys.executable,'g3-build/platform-provenance.py','macos',arch])
