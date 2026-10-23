"""Create an independently named g3 Debian package without rebuilding binaries."""
from pathlib import Path
import subprocess,tempfile,os,re,sys
version=os.environ.get('VERSION','1.5.0-g3.26')
assert re.fullmatch(r'[0-9][A-Za-z0-9.+:~-]*',version),'Invalid Debian version'
packages=[Path(p) for p in sys.argv[1:]] or list(Path('.').glob('rustdesk-*.deb'))
assert packages,'No Debian input package'
for package in packages:
 arch=subprocess.check_output(['dpkg-deb','-f',str(package),'Architecture'],text=True).strip()
 assert arch in ('amd64','arm64'),'Unsupported package architecture'
 with tempfile.TemporaryDirectory(prefix='g3-package-') as temp:
  root=Path(temp);subprocess.run(['dpkg-deb','-R',str(package),str(root)],check=True)
  for path in sorted(root.rglob('*'),key=lambda x:len(x.parts),reverse=True):
   if path.name=='rustdesk' or path.name.startswith('rustdesk.') or path.name.startswith('rustdesk-') or (path.suffix in ['.desktop','.service','.policy','.png','.svg'] and 'rustdesk' in path.name):
    path.rename(path.with_name(path.name.replace('rustdesk','g3fernwartung',1)))
  for path in root.rglob('*'):
   if path.is_symlink():
    target=os.readlink(path)
    fixed=target.replace('/usr/share/rustdesk/','/usr/share/g3fernwartung/').replace('/rustdesk','/g3fernwartung')
    if target!=fixed:path.unlink();path.symlink_to(fixed)
   elif path.is_file() and (path.parent.name=='DEBIAN' or path.suffix in ['.desktop','.service','.policy'] or path.name=='polkit'):
    try:s=path.read_text(encoding='utf-8')
    except UnicodeDecodeError:continue
    path.write_text(s.replace('rustdesk','g3fernwartung').replace('Name=RustDesk','Name=g3 OpsLinX'),encoding='utf-8')
  control=root/'DEBIAN/control';s=control.read_text(encoding='utf-8')
  fields={'Package':'g3fernwartung','Version':version,'Description':'g3 OpsLinX remote desktop and support client','Maintainer':'g3 NetworX UG & Co. KG <info@g3networx.de>','Homepage':'https://www.g3networx.de'}
  for key,value in fields.items():
   s=re.sub(r'^'+key+r':.*$',key+': '+value,s,flags=re.M) if re.search(r'^'+key+':',s,re.M) else s.rstrip()+'\n'+key+': '+value+'\n'
  control.write_text(s,encoding='utf-8');(root/'DEBIAN/md5sums').unlink(missing_ok=True)
  dest=Path('g3-OpsLinX-'+version+'-linux-'+{'amd64':'x86_64','arm64':'aarch64'}[arch]+'.deb')
  subprocess.run(['dpkg-deb','--root-owner-group','-b',str(root),str(dest)],check=True)
  print(dest)
