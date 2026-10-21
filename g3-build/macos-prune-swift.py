"""Remove only proven, unreferenced Intel Swift back-deployment shims from ARM bundles."""
from pathlib import Path
import subprocess,hashlib
ALLOWED={'libswiftAVFoundation.dylib', 'libswiftCoreGraphics.dylib', 'libswiftXPC.dylib', 'libswiftCoreFoundation.dylib', 'libswiftFoundation.dylib', 'libswiftAppKit.dylib', 'libswiftCoreAudio.dylib', 'libswiftCore.dylib', 'libswiftDispatch.dylib', 'libswiftIOKit.dylib', 'libswiftCoreData.dylib', 'libswiftos.dylib', 'libswiftMetal.dylib', 'libswiftCoreImage.dylib', 'libswiftsimd.dylib', 'libswiftCoreMedia.dylib', 'libswiftQuartzCore.dylib', 'libswiftDarwin.dylib', 'libswiftObjectiveC.dylib'}
def prune(app,arch):
 if arch!='aarch64':return []
 native=[];remove=[]
 for file in app.rglob('*'):
  if not file.is_file() or file.is_symlink():continue
  with file.open('rb') as stream:magic=stream.read(4)
  if magic not in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):continue
  slices=subprocess.check_output(['lipo','-archs',str(file)],text=True).split()
  if 'arm64' in slices or 'arm64e' in slices:native.append(file);continue
  assert file.parent==app/'Contents/Frameworks' and file.name in ALLOWED and slices==['x86_64'], 'Unexpected foreign binary: '+str(file)
  remove.append(file)
 names={f.name for f in remove}
 # Every retained binary must resolve these names from the macOS Swift runtime,
 # never from @rpath, @loader_path, @executable_path or an absolute bundle path.
 for file in native:
  deps=subprocess.check_output(['otool','-L',str(file)],text=True).splitlines()[1:]
  for line in deps:
   dep=line.strip().split(' (')[0]
   if Path(dep).name in names:assert dep=='/usr/lib/swift/'+Path(dep).name, 'Bundled Swift dependency still required: '+dep
 records=[{'file':str(f.relative_to(app)),'architecture':'x86_64','sha256':hashlib.sha256(f.read_bytes()).hexdigest(),'reason':'Unreferenced Intel back-deployment shim; ARM binaries use /usr/lib/swift'} for f in remove]
 for file in remove:file.unlink()
 return records
