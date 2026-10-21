"""Inspect accepted DMG dependencies on a disposable native runner; no changes."""
from pathlib import Path
import subprocess,tempfile,plistlib,json,os,time
root=Path.cwd();image=next((root/'input').glob('*.dmg'));rows=[]
with tempfile.TemporaryDirectory() as t:
 mount=Path(t)/'mount';mount.mkdir()
 subprocess.run(['hdiutil','attach',str(image),'-readonly','-nobrowse','-mountpoint',str(mount)],check=True)
 try:
  app=next(mount.glob('*.app'))
  for file in app.rglob('*'):
   if not file.is_file() or file.is_symlink():continue
   with file.open('rb') as stream:magic=stream.read(4)
   if magic not in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):continue
   row={'file':str(file.relative_to(app)),'slices':subprocess.check_output(['lipo','-archs',str(file)],text=True).strip(),'dependencies':subprocess.check_output(['otool','-L',str(file)],text=True).splitlines()[1:]}
   rows.append(row)
  info=plistlib.loads((app/'Contents/Info.plist').read_bytes());exe=app/'Contents/MacOS'/info['CFBundleExecutable']
  log=Path(t)/'loaded.log'
  with log.open('w') as out:
   process=subprocess.Popen([str(exe)],env=dict(os.environ,DYLD_PRINT_LIBRARIES='1'),stdout=out,stderr=out)
   try:
    time.sleep(10);alive=process.poll() is None
   finally:
    if process.poll() is None:process.terminate();process.wait(timeout=15)
  loaded=[line for line in log.read_text(errors='replace').splitlines() if line.startswith('dyld[') and ('/libswift' in line or '/Swift' in line)]
  result={'files':rows,'gui_alive_10s':alive,'loaded_swift_libraries':loaded}
  print(json.dumps(result,indent=2))
 finally:subprocess.run(['hdiutil','detach',str(mount)],check=True)
