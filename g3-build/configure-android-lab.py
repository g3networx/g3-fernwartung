"""Prepare the isolated OpsLinX Android test APK from the upstream app."""
from pathlib import Path
from xml.etree import ElementTree as ET

root = Path(__file__).resolve().parents[1]
android = root / 'flutter/android/app'

def replace_once(path, old, new):
    text = path.read_text(encoding='utf-8')
    if text.count(old) != 1:
        raise RuntimeError(f'Unexpected source layout: {path}')
    path.write_text(text.replace(old, new), encoding='utf-8')

# Keep the configured OpsLinX servers and require local approval for every
# incoming Android session, including on phones updated from an older build.
config = root / 'libs/hbb_common/src/config.rs'
replace_once(
    config,
    'if is_g3_adhoc(){ settings.insert("approve-mode".to_owned(),"click".to_owned());',
    'if is_g3_adhoc() || cfg!(target_os = "android"){ settings.insert("approve-mode".to_owned(),"click".to_owned());',
)
replace_once(android / 'build.gradle', 'applicationId "com.carriez.flutter_hbb"',
             'applicationId "net.g3nx.opslinx.lab"')

manifest = android / 'src/main/AndroidManifest.xml'
ns = '{http://schemas.android.com/apk/res/android}'
ET.register_namespace('android', 'http://schemas.android.com/apk/res/android')
ET.register_namespace('tools', 'http://schemas.android.com/tools')
tree = ET.parse(manifest)
app = tree.getroot().find('application')
if app is None:
    raise RuntimeError('Android application manifest is missing')
for node in list(app):
    if node.get(ns + 'name') == '.BootReceiver':
        app.remove(node)
    if node.get(ns + 'name') == '.InputService':
        node.set(ns + 'label', 'g3 OpsLinX Steuerung')
    if node.get(ns + 'name') == '.MainActivity':
        for intent in list(node.findall('intent-filter')):
            if any(data.get(ns + 'scheme') == 'rustdesk' for data in intent.findall('data')):
                node.remove(intent)
for permission in tree.getroot().findall('uses-permission'):
    if permission.get(ns + 'name') == 'android.permission.RECEIVE_BOOT_COMPLETED':
        tree.getroot().remove(permission)
tree.write(manifest, encoding='utf-8', xml_declaration=True)
