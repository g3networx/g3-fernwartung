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
websocket = root / 'libs/hbb_common/src/websocket.rs'
replace_once(
    websocket,
    '    #[inline]\n    pub fn set_raw(&mut self) {',
    '''    /// A WSS connection that always verifies the certificate, including on retries.
    #[cfg(target_os = "android")]
    pub async fn new_verified(url: &str, ms_timeout: u64) -> ResultType<Self> {
        if !url.starts_with("wss://") {
            bail!("verified WebSocket requires TLS");
        }
        let proxy = Config::get_socks();
        let (stream, addr) = Self::try_connect(
            url,
            None,
            proxy.as_ref(),
            ms_timeout,
            TlsType::Rustls,
            false,
            Some(false),
            Some(false),
        )
        .await?;
        Ok(Self {
            stream,
            addr,
            encrypt: None,
            send_timeout: ms_timeout,
        })
    }

    #[inline]
    pub fn set_raw(&mut self) {''',
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
app.set(ns + 'label', 'g3 OpsLinX')
tree.getroot().insert(list(tree.getroot()).index(app), ET.Element('uses-permission', {
    ns + 'name': 'android.permission.REQUEST_INSTALL_PACKAGES',
}))
provider = ET.SubElement(app, 'provider', {
    ns + 'name': '.OpsLinxUpdateProvider',
    ns + 'authorities': '${applicationId}.opslinx-updates',
    ns + 'exported': 'false',
    ns + 'grantUriPermissions': 'true',
})
ET.SubElement(provider, 'meta-data', {
    ns + 'name': 'android.support.FILE_PROVIDER_PATHS',
    ns + 'resource': '@xml/opslinx_update_paths',
})
paths = android / 'src/main/res/xml/opslinx_update_paths.xml'
paths.parent.mkdir(parents=True, exist_ok=True)
paths.write_text('<paths><cache-path name="update" path="opslinx-updates/" /></paths>\n', encoding='utf-8')
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
