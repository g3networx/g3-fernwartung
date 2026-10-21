"""Isolated regression: real Rust session locks against the real C# installer gate.
No installed client, service, UI, network or customer system is touched.
"""
from pathlib import Path
import subprocess, json, time, sys, shutil, os, hashlib
repo=Path(__file__).resolve().parents[1]; root=repo; folder=repo/'work/session-gate-test';folder.mkdir(parents=True,exist_ok=True)
(folder/'g3-update-session.lock').write_bytes(b'')
module=(repo/'src/g3_update_gate.rs').as_posix()
(folder/'session.rs').write_text('''extern crate self as hbb_common;
pub mod log {pub use std::eprintln as error;}
#[path="'''+module+'''"] mod gate;
fn main() {
 let mode=std::env::args().nth(1).unwrap_or_default();
 let _lease=if mode=="session" {match gate::session(){Ok(Some(g))=>Some(g),_=>std::process::exit(1618)}} else {gate::watch_idle_process(&[]);None};
 println!("READY");
 let mut line=String::new();std::io::stdin().read_line(&mut line).unwrap();
}
''',encoding='utf-8')
rust=shutil.which('rustc') or 'D:/CodexBuild/g3rd-20261019/cargo/bin/rustc.exe'
subprocess.run([rust,'--edition=2021',str(folder/'session.rs'),'-o',str(folder/'session.exe')],check=True)
source=(repo/'g3-build/SetupBootstrap.cs').read_text(encoding='utf-8')
classes=source[source.index('internal sealed class UpdateBusyException'):source.index('internal sealed class SetupForm')]
(folder/'gate.cs').write_text('''using System;using System.IO;using System.Runtime.InteropServices;using Microsoft.Win32.SafeHandles;
'''+classes+'''class TestGate {
 static int Main(string[] args){try{using(var gate=new UpdateSessionGate(args[0])){Console.WriteLine("READY");if(args.Length>1)Console.ReadLine();return 0;}}catch(UpdateBusyException){return 1618;}}
}
''',encoding='utf-8')
subprocess.run([str(Path(os.environ['SystemRoot'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'),'/nologo','/target:exe','/out:'+str(folder/'gate.exe'),str(folder/'gate.cs')],check=True)
# Exercise the exact production verifier while the installer lease is held.
verification=source[source.index(' static string Digest'):source.index(' static void OpenClient')]
(folder/'payload.txt').write_bytes(b'verified payload')
(folder/'payload.tsv').write_text('g3-update-session.lock\t'+hashlib.sha256(b'').hexdigest()+'\npayload.txt\t'+hashlib.sha256(b'verified payload').hexdigest(),encoding='utf-8')
(folder/'verify.cs').write_text('''using System;using System.IO;using System.Runtime.InteropServices;using Microsoft.Win32.SafeHandles;using System.Security.Cryptography;using System.Reflection;using System.ServiceProcess;using Microsoft.Win32;
'''+classes+'''class TestPayload {
 static string InstalledExe,AppName="unused-fixture-service";
'''+verification+'''
 static int Main(string[] args){InstalledExe=Path.Combine(Path.GetFullPath(args[0]),"fixture.exe");using(var gate=new UpdateSessionGate(Path.Combine(args[0],"g3-update-session.lock"))){if(!VerifiedInstallation(false))return 1;File.WriteAllText(Path.Combine(args[0],"payload.txt"),"tampered");return VerifiedInstallation(false)?2:0;}}
}
''',encoding='utf-8')
subprocess.run([str(Path(os.environ['SystemRoot'])/'Microsoft.NET/Framework64/v4.0.30319/csc.exe'),'/nologo','/target:exe','/reference:System.ServiceProcess.dll','/resource:'+str(folder/'payload.tsv')+',g3.payload','/out:'+str(folder/'verify.exe'),str(folder/'verify.cs')],check=True)
children=[]
def launch(exe,*args):
 p=subprocess.Popen([str(folder/exe),*args],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);children.append(p)
 assert p.stdout.readline().strip()=='READY', 'child did not acquire its lease'
 return p
def stop(p):
 p.communicate('\n',timeout=8);assert p.returncode==0

def probe():return subprocess.run([str(folder/'gate.exe'),str(folder/'g3-update-session.lock')],capture_output=True).returncode
results=[]
try:
 a=launch('session.exe','session');b=launch('session.exe','session')
 assert probe()==1618 and a.poll() is None and b.poll() is None
 stop(a);assert probe()==1618 and b.poll() is None
 stop(b);assert probe()==0
 results.append({'case':'multiple_active_sessions_defer_update_without_closing_either','passed':True})
 gate=launch('gate.exe',str(folder/'g3-update-session.lock'),'hold')
 assert subprocess.run([str(folder/'session.exe'),'session'],capture_output=True).returncode==1618
 stop(gate);subprocess.run([str(folder/'verify.exe'),str(folder)],check=True);a=launch('session.exe','session');stop(a)
 results.append({'case':'exclusive_installation_blocks_sessions_and_verifies_payload_while_locked','passed':True})
 idle=launch('session.exe','idle');active=launch('session.exe','session')
 assert probe()==1618;time.sleep(.6);assert idle.poll() is None and active.poll() is None
 stop(active);gate=launch('gate.exe',str(folder/'g3-update-session.lock'),'hold');assert idle.wait(timeout=5)==0
 assert subprocess.run([str(folder/'session.exe'),'session'],capture_output=True).returncode==1618
 stop(gate);idle=launch('session.exe','idle');stop(idle)
 results.append({'case':'only_idle_process_exits_voluntarily_after_atomic_exclusive_handoff','passed':True})
finally:
 for p in children:
  if p.poll() is None:
   try:p.communicate('\n',timeout=5)
   except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=5)
(root/'outputs').mkdir(exist_ok=True)
proof={'version':'1.5.0-g3.22','scope':'isolated disposable test processes; real Rust/C# production gate code','installed_client_touched':False,'tests':results}
(root/'outputs/FullClient-g3.22-Sitzungssperre-Regression.json').write_text(json.dumps(proof,indent=2),encoding='utf-8')
print(json.dumps(proof))
