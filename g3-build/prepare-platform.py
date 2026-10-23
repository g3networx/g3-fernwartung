"""Build-only platform preparation. No customer credentials or enrollment codes."""
from pathlib import Path
import sys,os,re
p=Path('flutter/lib/g3_update_check.dart');s=p.read_text()
s,n=re.subn(r"const g3ClientVersion = '[^']+';", "const g3ClientVersion = '"+os.environ.get('VERSION','1.5.0-g3.25')+"';",s)
assert n==1, 'Expected exactly one client version declaration'
p.write_text(s)
needle='  Future<void> check() async {\n'
assert needle in s
s=s.replace(needle,needle+"    if (!Platform.isWindows) {\n      setState(() { message = 'Updates für diese Plattform findest du unter https://rust.g3nx.net/client. Lade dort das passende Paket für dein Betriebssystem und deine Prozessorarchitektur herunter.'; busy = false; });\n      return;\n    }\n",1)
p.write_text(s)
if sys.platform=='darwin':
 p=Path('flutter/macos/Runner/Configs/AppInfo.xcconfig');s=p.read_text().replace('PRODUCT_NAME = RustDesk','PRODUCT_NAME = g3Fernwartung').replace('PRODUCT_BUNDLE_IDENTIFIER = com.carriez.flutterHbb','PRODUCT_BUNDLE_IDENTIFIER = de.g3networx.fernwartung');p.write_text(s)
 p=Path('build.py');p.write_text(p.read_text().replace('RustDesk.app','g3Fernwartung.app'))

 p=Path('flutter/macos/Runner/Info.plist');s=p.read_text();s=s.replace('<string>com.carriez.rustdesk</string>','<string>de.g3networx.fernwartung</string>').replace('<string>rustdesk</string>','<string>g3fernwartung</string>');p.write_text(s)

 p=Path('flutter/macos/Runner.xcodeproj/project.pbxproj');p.write_text(p.read_text().replace('PRODUCT_BUNDLE_IDENTIFIER = com.carriez.rustdesk;','PRODUCT_BUNDLE_IDENTIFIER = de.g3networx.fernwartung;'))
