from pathlib import Path
import datetime,json,runpy,subprocess
m=json.loads(Path('g3-build/password-release.json').read_text(encoding='utf-8'))
d=datetime.date.fromisoformat(m['buildDate'])
berlin=subprocess.check_output(['powershell','-NoProfile','-Command',"[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow,'W. Europe Standard Time').ToString('yyyy-MM-dd')"],text=True).strip()
assert berlin==d.isoformat(),'Build date must match actual Berlin date'
assert m['displayVersion']=='g3.6 Build '+d.strftime('%d%m%y')
assert runpy.run_path('g3-build/package-version.py')['windows_version'](m['version'])==m['windowsVersion']
assert m['windowsVersion']==f"1.60.{(d-datetime.date(2020,1,1)).days*8+m['dailyInternalSequence']}"
assert 0<=m['dailyInternalSequence']<8
assert tuple(map(int,m['windowsVersion'].split('.')))>(1,50,2)
for name in ('src/g3_bootstrap.rs','src/g3_passwords.rs','src/core_main.rs','src/g3_registry_password.rs','src/ipc.rs','src/lib.rs','src/flutter_ffi.rs','src/ui_interface.rs','flutter/lib/g3_password_parameters.dart','flutter/lib/g3_password_probe.dart'):
 Path(name).read_bytes().decode('utf-8')
print('Password source encoding and g3.6 display/internal version checks passed')
