"""Validate build provenance and finalize platform metadata on native runners."""
from pathlib import Path
import os,sys,json,hashlib,subprocess,shutil,plistlib,tempfile,struct,time,re,platform as pyplatform
kind,arch=sys.argv[1:];version=os.environ.get('VERSION','1.5.0-g3.18');root=Path.cwd();inputs=root/'input';out=root/'verified';out.mkdir(exist_ok=True)
provenance=list(inputs.glob('platform-provenance-*.json'));assert len(provenance)==1,'Exactly one source provenance record required'
source=json.loads(provenance[0].read_text());version=source.get('version',version);assert source['arch']==arch and source['platform']==kind
assert str(source['run_id'])==os.environ['SOURCE_RUN'],'Wrong source run'
for f in source['files']:
 p=inputs/f['file'];assert p.name==f['file'] and p.is_file();assert hashlib.sha256(p.read_bytes()).hexdigest()==f['sha256'],'Source artifact hash mismatch'
checks=[];packaging_adjustments=[]
def run(args,**kw):return subprocess.run(args,check=True,**kw)
if kind=='linux':
 packages=list(inputs.glob('*.deb'));assert len(packages)==1
 run([sys.executable,str(root/'g3-build/repack-linux.py'),str(packages[0])],cwd=out,env=dict(os.environ,VERSION=version))
 package=next(out.glob('*.deb'))
 fields=subprocess.check_output(['dpkg-deb','-f',str(package),'Package','Version','Architecture'],text=True);assert 'g3fernwartung' in fields and version in fields and {'x86_64':'amd64','aarch64':'arm64'}[arch] in fields
 with tempfile.TemporaryDirectory() as temp:
  unpacked=Path(temp);run(['dpkg-deb','-R',str(package),temp]);exe=unpacked/'usr/share/g3fernwartung/g3fernwartung';data=exe.read_bytes();assert data[:4]==b'\x7fELF' and data[4]==2 and struct.unpack('<H',data[18:20])[0]=={'x86_64':62,'aarch64':183}[arch]
  for p in (unpacked/'DEBIAN').iterdir():
   if p.name in ['postinst','prerm','postrm','preinst']:run(['bash','-n',str(p)])
  assert 'g3fernwartung' in (unpacked/'usr/share/applications/g3fernwartung-link.desktop').read_text()
  assert not (unpacked/'usr/share/rustdesk').exists()
 checks+=['Debian metadata/version/architecture','ELF machine architecture','maintainer script syntax','isolated namespace and URI registration']
 # Native container smoke test. This cannot alter a customer or runner host installation.
 cmd="""apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y /packages/*.deb xvfb xauth dbus-x11 imagemagick libegl1-mesa libgles2-mesa
/usr/bin/g3fernwartung --version
mkdir -p /tmp/g3-runtime; chmod 700 /tmp/g3-runtime
export XDG_RUNTIME_DIR=/tmp/g3-runtime LIBGL_ALWAYS_SOFTWARE=1
dbus-run-session -- xvfb-run -a bash -ec '/usr/bin/g3fernwartung > /evidence/gui-smoke.log 2>&1 & client_pid=$!; sleep 10; kill -0 "$client_pid"; import -window root /evidence/client-preview.png; kill "$client_pid"; wait "$client_pid" || true'
"""
 result=subprocess.run(['docker','run','--rm','-v',str(out)+':/packages:ro','-v',str(out)+':/evidence','ubuntu:22.04','bash','-ec',cmd],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (out/'install-smoke.log').write_text(result.stdout);assert result.returncode==0,'Container install/version smoke failed';assert '1.5.0' in result.stdout
 checks+=['Ubuntu 22.04 native container install and executable --version','native GUI stays running for 10 seconds in Xvfb; screenshot captured']
else:
 packages=list(inputs.glob('*.dmg'));assert len(packages)==1
 with tempfile.TemporaryDirectory() as temp:
  mount=Path(temp)/'mount';mount.mkdir();run(['hdiutil','attach',str(packages[0]),'-readonly','-nobrowse','-mountpoint',str(mount)])
  try:
   apps=list(mount.glob('*.app'));assert len(apps)==1
   app=out/'g3Fernwartung.app';run(['ditto',str(apps[0]),str(app)])
  finally:run(['hdiutil','detach',str(mount)])
 info=app/'Contents/Info.plist';data=plistlib.loads(info.read_bytes());data['CFBundleIdentifier']='de.g3networx.fernwartung';data['G3BuildVersion']=version;data['CFBundleURLTypes']=[{'CFBundleTypeRole':'Editor','CFBundleURLName':'de.g3networx.fernwartung','CFBundleURLSchemes':['g3fernwartung']}];info.write_bytes(plistlib.dumps(data))
 from runpy import run_path
 packaging_adjustments=run_path(str(root/'g3-build/macos-prune-swift.py'))['prune'](app,arch)
 minimum=run_path(str(root/'g3-build/macos-minimum.py'))['bundle_minimum'](app,arch)
 if packaging_adjustments:
  assert tuple(map(int,minimum.split('.'))) >= (11,0), 'ARM system Swift runtime baseline required'
  checks+=['Removed only dependency-verified unreferenced x86_64 Swift back-deployment shims from ARM package']
 data['LSMinimumSystemVersion']=minimum;info.write_bytes(plistlib.dumps(data))
 checks+=['Bundle minimum aligned with all Mach-O deployment targets (not an older-OS runtime test)']
 # Compile the menu against the renamed Swift module, not the upstream product name.
 xib=out/'MainMenu.xib';xib.write_text((root/'flutter/macos/Runner/Base.lproj/MainMenu.xib').read_text().replace('customModule="RustDesk"','customModule="g3Fernwartung"'))
 run(['ibtool','--module','g3Fernwartung','--compile',str(app/'Contents/Resources/Base.lproj/MainMenu.nib'),str(xib)]);xib.unlink()
 exe=app/'Contents/MacOS'/data['CFBundleExecutable'];machine=subprocess.check_output(['lipo','-archs',str(exe)],text=True).strip();assert {'x86_64':'x86_64','aarch64':'arm64'}[arch] in machine
 # Verify every committed native wire export used by the generated Dart bridge.
 native=app/'Contents/Frameworks/liblibrustdesk.dylib'
 exports=subprocess.check_output(['nm','-gU',str(native)],text=True)
 expected=re.findall(r'pub extern "C" fn (\w+)\(', (root/'src/bridge_generated.io.rs').read_text())
 assert all('_'+name in exports for name in expected),'Native bridge export missing'
 run(['codesign','--force','--deep','--sign','-',str(app)]);run(['codesign','--verify','--deep','--strict',str(app)])
 result=subprocess.run([str(exe),'--version'],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30);(out/'launch-smoke.log').write_text(result.stdout);assert result.returncode==0 and '1.5.0' in result.stdout,'Native macOS executable smoke failed'
 with (out/'gui-smoke.log').open('w') as log:
  gui=subprocess.Popen([str(exe)],stdout=log,stderr=subprocess.STDOUT)
  try:
   time.sleep(10);assert gui.poll() is None,'macOS GUI exited during startup'
   run(['screencapture','-x',str(out/'client-preview.png')])
  finally:
   if gui.poll() is None:gui.terminate();gui.wait(timeout=15)
 checks+=['native GUI stays running for 10 seconds; screenshot captured','all committed Rust wire symbols exported']
 dmg=out/f'g3-Fernwartung-{version}-macos-{arch}.dmg';stage=out/'dmg-stage';stage.mkdir();run(['ditto',str(app),str(stage/app.name)]);(stage/'Applications').symlink_to('/Applications');run(['hdiutil','create','-volname','g3 Fernwartung','-srcfolder',str(stage),'-ov','-format','UDZO',str(dmg)]);shutil.rmtree(stage);shutil.rmtree(app)
 checks+=['Mach-O native architecture','g3 URL registration','bundle identifier','local ad-hoc integrity signature (not Apple Developer ID/not notarized)','native --version launch']
files=list(out.glob('*.deb' if kind=='linux' else '*.dmg'));assert len(files)==1
record={'version':version,'platform':kind,'arch':arch,'source':source,'finalization_commit':os.environ['GITHUB_SHA'],'finalization_run':os.environ['GITHUB_RUN_ID'],'checks':checks,'packaging_adjustments':packaging_adjustments,'publicly_trusted_signature':False,'interactive_connection_acceptance':False,'tested_os':('Ubuntu 22.04' if kind=='linux' else 'macOS '+pyplatform.mac_ver()[0]),'configured_minimum_os':(data.get('LSMinimumSystemVersion') if kind=='macos' else None),'files':[{'file':p.name,'size':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}for p in files]}
(out/'validation.json').write_text(json.dumps(record,indent=2));(out/'SHA256SUMS').write_text(''.join(f"{f['sha256']}  {f['file']}\n" for f in record['files']))
