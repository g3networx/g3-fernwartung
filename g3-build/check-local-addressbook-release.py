import datetime,json,runpy
from pathlib import Path

root=Path(__file__).resolve().parents[1]
m=json.loads((root/'g3-build/local-addressbook-release.json').read_text())
d=datetime.date.fromisoformat(m['buildDate'])
assert 0<=m['dailyInternalSequence']<8
counter=(d-datetime.date(2020,1,1)).days*8+m['dailyInternalSequence']
assert m['displayVersion']=='g3.6.2 Build '+d.strftime('%d%m%y')
assert m['version']==f'1.5.3-g3.62.{counter}'
assert m['windowsVersion']==f'1.62.{counter}'
assert runpy.run_path(str(root/'g3-build/package-version.py'))['windows_version'](m['version'])==m['windowsVersion']
for name in ['g3_local_addressbook.dart','g3_local_addressbook_store.dart','g3_local_addressbook_crypto.dart','g3_local_addressbook_password_dialog.dart']:
 (root/'flutter/lib'/name).read_bytes().decode('utf-8')
assert 'cryptography: 2.7.0' in (root/'flutter/pubspec.yaml').read_text()
print('g3.6.2 source encoding, version and crypto dependency verified')
