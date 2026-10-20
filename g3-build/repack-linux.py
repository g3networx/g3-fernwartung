"""Isolate the g3 package from existing upstream installations."""
from pathlib import Path
import subprocess,tempfile,shutil
for package in Path('.').glob('rustdesk-*.deb'):
 with tempfile.TemporaryDirectory(prefix='g3-package-') as temp:
  root=Path(temp);subprocess.run(['dpkg-deb','-R',str(package),str(root)],check=True)
  for path in sorted(root.rglob('*'),key=lambda x:len(x.parts),reverse=True):
   if path.name=='rustdesk' or path.name.startswith('rustdesk.') or path.name.startswith('rustdesk-') or (path.suffix in ['.desktop','.service','.policy','.png','.svg'] and 'rustdesk' in path.name):
    path.rename(path.with_name(path.name.replace('rustdesk','g3fernwartung',1)))
  for path in root.rglob('*'):
   if path.is_file() and (path.parent.name=='DEBIAN' or path.suffix in ['.desktop','.service','.policy'] or path.name=='polkit'):
    try:s=path.read_text()
    except UnicodeDecodeError:continue
    path.write_text(s.replace('rustdesk','g3fernwartung').replace('Name=RustDesk','Name=g3 Fernwartung'))
  control=root/'DEBIAN/control';s=control.read_text();s=s.replace('Maintainer: RustDesk','Maintainer: g3 NetworX');control.write_text(s)
  (root/'DEBIAN/md5sums').unlink(missing_ok=True)
  dest=Path('g3-Fernwartung-'+package.name.removeprefix('rustdesk-').replace('1.5.0-','1.5.0-g3.16-',1))
  subprocess.run(['dpkg-deb','--root-owner-group','-b',str(root),str(dest)],check=True)
