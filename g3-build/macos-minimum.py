"""Align bundle metadata with actual Mach-O deployment targets, not runner OS."""
from pathlib import Path
import re,subprocess

def bundle_minimum(app:Path,arch:str):
 machine={'aarch64':'arm64','x86_64':'x86_64'}[arch]
 versions=[]
 for file in app.rglob('*'):
  if not file.is_file() or file.is_symlink():continue
  with file.open('rb') as stream:magic=stream.read(4)
  if magic not in (b'\xcf\xfa\xed\xfe',b'\xfe\xed\xfa\xcf',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca'):continue
  slices=subprocess.check_output(['lipo','-archs',str(file)],text=True).split()
  selected=machine
  if selected not in slices:
   # Apple's bundled Swift compatibility shims may contain the arm64e
   # subtype. Inspect that slice explicitly instead of skipping the library.
   assert machine=='arm64' and 'arm64e' in slices, 'Foreign architecture in bundle: '+str(file)
   selected='arm64e'
  result=subprocess.run(['vtool','-arch',selected,'-show-build',str(file)],check=True,stdout=subprocess.PIPE,text=True)
  legacy=False
  for line in result.stdout.splitlines():
   if re.match(r'\s*cmd\s+',line):legacy='LC_VERSION_MIN_MACOSX' in line
   m=re.match(r'\s*(minos|version)\s+(\d+(?:\.\d+){1,2})\s*$',line)
   if m and (m[1]=='minos' or legacy):versions.append(tuple(map(int,m[2].split('.')))+(0,)*(3-len(m[2].split('.'))))
 assert versions,'No native deployment targets found'
 maximum=max(versions)
 return '.'.join(map(str,maximum[:2] if maximum[2]==0 else maximum))
