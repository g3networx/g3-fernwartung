"""Disposable runner only: exercise the production download/install form against a local package fixture.
The fixture changes only the compiled download URL and entry point, never the shipped launcher.
"""
import hashlib, http.server, json, os, pathlib, subprocess, threading

assert os.environ.get('GITHUB_ACTIONS') == 'true', 'Disposable GitHub runner required'
root = pathlib.Path(__file__).resolve().parents[1]
folder = root/'work/download-acceptance'
folder.mkdir(parents=True, exist_ok=True)
version = '1.5.0-g3.28'
msi = root/'outputs'/f'g3-OpsLinX-{version}-install.msi'
payload = msi.read_bytes()
class Handler(http.server.BaseHTTPRequestHandler):
    corrupt = False
    def do_GET(self):
        data = b'corrupt package fixture' if self.corrupt else payload
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
source = (root/'g3-build/msi/windows/SetupBootstrap.cs').read_text(encoding='utf-8')
needle = '"https://rust.g3nx.net/client/releases/"+Version+"/"+Kind'
assert source.count(needle) == 1
source = source.replace(needle, '"http://127.0.0.1:'+str(server.server_port)+'/candidate.msi"')
(folder/'SetupBootstrap.cs').write_text(source, encoding='utf-8')
(folder/'Harness.cs').write_text('''using System;using System.IO;using System.Reflection;using System.Threading.Tasks;using System.Windows.Forms;
class DownloadAcceptance {
 [STAThread] static int Main(string[] args) {
  var flags=BindingFlags.Static|BindingFlags.NonPublic;
  if(args.Length>0)return (int)typeof(SetupForm).GetMethod("Main",flags).Invoke(null,new object[]{args});
  int code=1;Application.EnableVisualStyles();var form=new SetupForm(0);
  form.Shown+=async(s,e)=>{try {
   await (Task)typeof(SetupForm).GetMethod("Install",BindingFlags.Instance|BindingFlags.NonPublic).Invoke(form,null);
   var label=(Label)typeof(SetupForm).GetField("status",BindingFlags.Instance|BindingFlags.NonPublic).GetValue(form);
   bool bad=Environment.GetEnvironmentVariable("G3_FIXTURE_CORRUPT")=="1";
   bool ready=(bool)typeof(SetupForm).GetMethod("VerifiedInstallation",flags).Invoke(null,new object[]{true});
   code=bad?(label.Text.Contains("Paketprüfung fehlgeschlagen")?0:2):(ready&&!label.Text.Contains("Update nicht abgeschlossen")?0:3);
  }catch(Exception ex){Console.Error.WriteLine(ex);code=4;}finally{form.Close();}};
  Application.Run(form);return code;
 }
}''', encoding='utf-8')
exe = folder/'DownloadAcceptance.exe'
subprocess.run(['C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe', '/nologo', '/target:exe',
 '/main:DownloadAcceptance', '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll',
 '/reference:System.ServiceProcess.dll', '/resource:'+str(root/'g3-build/msi/windows/expected-payload.tsv')+',g3.payload',
 '/out:'+str(exe), str(folder/'SetupBootstrap.cs'), str(folder/'Harness.cs')], check=True)
cache = pathlib.Path(os.environ['LOCALAPPDATA'])/'g3NetworX/Fernwartung/Downloads'
before = set(cache.glob('setup-*/*.msi'))
try:
    for bad in (True, False):
        Handler.corrupt = bad
        env = dict(os.environ, G3_FIXTURE_CORRUPT='1' if bad else '0')
        subprocess.run([str(exe)], check=True, timeout=240, env=env)
    created = set(cache.glob('setup-*/*.msi'))-before
    assert len(created) == 2
    hashes = {hashlib.sha256(p.read_bytes()).hexdigest() for p in created}
    assert hashlib.sha256(payload).hexdigest() in hashes
    assert hashlib.sha256(b'corrupt package fixture').hexdigest() in hashes
    proof = {'version':version, 'fixed_download_root':r'%LOCALAPPDATA%\g3NetworX\Fernwartung\Downloads',
      'download_and_idle_install':True, 'corrupt_download_rejected':True,
      'unique_download_folders':True, 'fixture_scope':'Local HTTP fixture on disposable runner; production form, hash verification and elevated worker; only URL and test entry point differ'}
    (root/'outputs/windows-download-path-test.json').write_text(json.dumps(proof,indent=2),encoding='utf-8')
finally:
    server.shutdown()
