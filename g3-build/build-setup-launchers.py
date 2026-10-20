import pathlib,json,hashlib,subprocess
root=pathlib.Path.cwd();out=root/'outputs';items={}
for kind,name in [('windows','g3-Fernwartung-1.5.0-g3.19-install'),('host','g3-Host-1.5.0-g3.19-host-install')]:
 msi=out/(name+'.msi');digest=hashlib.sha256(msi.read_bytes()).hexdigest();items[kind+'_msi']={'file':msi.name,'sha256':digest,'size':msi.stat().st_size}
 source=(root/'g3-build/SetupBootstrap.cs').read_text(encoding='utf-8').replace('@KIND@',kind+'_msi').replace('@HASH@',digest).replace('@FILE@',msi.name).replace('@VERSION@','1.5.0-g3.19').replace('@EXEHASH@',hashlib.sha256((root/'flutter/build/windows/x64/runner/Release/rustdesk.exe').read_bytes()).hexdigest());code=root/'g3-build/msi'/kind/'SetupBootstrap.cs';code.write_text(source,encoding='utf-8')
 subprocess.run(['C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe','/nologo','/target:winexe','/platform:x64','/optimize+','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.ServiceProcess.dll','/resource:'+str(root/'res/g3-brand-original.png')+',g3.brand','/win32icon:flutter/windows/runner/resources/app_icon.ico','/out:'+str(out/(name+'.exe')),str(code)],check=True)
(out/'msi-items.json').write_text(json.dumps(items,indent=2),encoding='utf-8');print('Visible setup launchers compiled; MSI metadata saved.')
