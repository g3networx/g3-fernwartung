import pathlib,json,hashlib,subprocess,uuid

root=pathlib.Path.cwd();out=root/'outputs';items={}

for kind,name in [('windows','g3-Fernwartung-1.5.0-g3.23-install'),('host','g3-Host-1.5.0-g3.23-host-install')]:

 msi=out/(name+'.msi');digest=hashlib.sha256(msi.read_bytes()).hexdigest();items[kind+'_msi']={'file':msi.name,'sha256':digest,'size':msi.stat().st_size}

 source=(root/'g3-build/SetupBootstrap.cs').read_text(encoding='utf-8').replace('@GATE_DLL_HASHES@',hashlib.sha256((root/'flutter/build/windows/x64/runner/Release/librustdesk.dll').read_bytes()).hexdigest()+(';'+(root/'g3-build/update-gate-native-hashes.txt').read_text(encoding='utf-8').strip().replace('\n',';') if (root/'g3-build/update-gate-native-hashes.txt').exists() else '')).replace('@PRODUCTCODE@','{'+str(uuid.uuid5(uuid.NAMESPACE_URL,'https://g3networx.de/fernwartung/msi/'+kind+'/1.5.0-g3.23')).upper()+'}').replace('@KIND@',kind+'_msi').replace('@HASH@',digest).replace('@FILE@',msi.name).replace('@VERSION@','1.5.0-g3.23').replace('@EXEHASH@',hashlib.sha256((root/'flutter/build/windows/x64/runner/Release/rustdesk.exe').read_bytes()).hexdigest());code=root/'g3-build/msi'/kind/'SetupBootstrap.cs';code.write_text(source,encoding='utf-8')

 payload=(root/'flutter/build/windows/x64/runner/Release')
 entries=[]
 for file in sorted(payload.rglob('*')):
  if not file.is_file() or file.suffix.lower() in ('.pdb','.exp','.lib') or file.name=='meta.toml':continue
  rel=file.relative_to(payload).as_posix()
  if rel=='rustdesk.exe':rel=('g3Host' if kind=='host' else 'g3Fernwartung')+'.exe'
  entries.append(rel+'\t'+hashlib.sha256(file.read_bytes()).hexdigest())
 expected=root/'g3-build/msi'/kind/'expected-payload.tsv';expected.write_text('\n'.join(entries),encoding='utf-8')
 subprocess.run(['C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe','/nologo','/target:winexe','/platform:x64','/optimize+','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.ServiceProcess.dll','/resource:'+str(expected)+',g3.payload','/resource:'+str(root/'res/g3-brand-original.png')+',g3.brand','/win32icon:flutter/windows/runner/resources/app_icon.ico','/out:'+str(out/(name+'.exe')),str(code)],check=True)

(out/'msi-items.json').write_text(json.dumps(items,indent=2),encoding='utf-8');print('Visible setup launchers compiled; MSI metadata saved.')

