"""Disposable process regression; no installed product or service is changed."""
from pathlib import Path
import os, subprocess, json

root = Path(__file__).resolve().parents[1]
folder = root / 'work/process-inspection-test'
folder.mkdir(parents=True, exist_ok=True)
if os.environ.get('GITHUB_ACTIONS') != 'true':
    raise RuntimeError('Disposable GitHub runner required for process ACL fixture')
csc = str(Path(os.environ['SystemRoot']) / 'Microsoft.NET/Framework64/v4.0.30319/csc.exe')
(folder/'Child.cs').write_text('class Child { static void Main(){System.Console.WriteLine("READY");System.Console.ReadLine();}}')
subprocess.run([csc, '/nologo', '/target:exe', '/out:'+str(folder/'g3Fernwartung.exe'), str(folder/'Child.cs')], check=True)
(folder/'Harness.cs').write_text(r'''
using System;using System.Diagnostics;using System.IO;using System.Reflection;using System.Runtime.InteropServices;
class ProcessInspectionAcceptance {
 [DllImport("advapi32.dll",SetLastError=true)]static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(string s,uint revision,out IntPtr descriptor,out uint size);
 [DllImport("advapi32.dll",SetLastError=true)]static extern bool SetKernelObjectSecurity(IntPtr handle,uint information,IntPtr descriptor);
 [DllImport("kernel32.dll")]static extern IntPtr LocalFree(IntPtr p);
 static bool Busy(){return (bool)typeof(SetupForm).GetMethod("OwnProcessesRemain",BindingFlags.Static|BindingFlags.NonPublic).Invoke(null,null);}
 static void Main(string[] args){
  if(Busy())throw new Exception("Fixture requires no installed client processes");
  var start=new ProcessStartInfo(args[0]){UseShellExecute=false,CreateNoWindow=true,RedirectStandardInput=true,RedirectStandardOutput=true};
  using(var child=Process.Start(start)){
   try{
    if(child.StandardOutput.ReadLine()!="READY")throw new Exception("Fixture start failed");
    var handle=child.Handle;IntPtr descriptor;uint length;
    if(!ConvertStringSecurityDescriptorToSecurityDescriptor("D:(D;;0x001FFFFF;;;WD)",1,out descriptor,out length))throw new Exception("Fixture descriptor failed");
    try{if(!SetKernelObjectSecurity(handle,4,descriptor))throw new Exception("Fixture ACL failed");}finally{LocalFree(descriptor);}
    bool denied=false;
    using(var query=Process.GetProcessById(child.Id)){try{var exited=query.HasExited;}catch(System.ComponentModel.Win32Exception e){denied=e.NativeErrorCode==5;}}
    if(!denied)throw new Exception("Did not reproduce Framework HasExited access denied");
    if(!Busy())throw new Exception("Protected running process was ignored");
    if(child.HasExited)throw new Exception("Read-only inspection interrupted fixture");
   }finally{child.StandardInput.WriteLine("");if(!child.WaitForExit(10000))throw new Exception("Fixture failed to exit voluntarily");}
  }
  if(Busy())throw new Exception("Gracefully exited fixture still blocks update");
  Console.WriteLine("PASS protected process defers without privileged queries; graceful exit clears deferral");
 }
}
''', encoding='utf-8')
(folder/'payload.tsv').write_text('')
exe=folder/'Acceptance.exe'
subprocess.run([csc,'/nologo','/target:exe','/main:ProcessInspectionAcceptance','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.ServiceProcess.dll','/resource:'+str(folder/'payload.tsv')+',g3.payload','/out:'+str(exe),str(root/'g3-build/SetupBootstrap.cs'),str(folder/'Harness.cs')],check=True)
subprocess.run([str(exe),str(folder/'g3Fernwartung.exe')],check=True)
(root/'outputs/process-inspection-acceptance.json').write_text(json.dumps({'protected_process_defers_without_access_denied':True,'running_process_not_ignored':True,'fixture_exits_voluntarily':True,'exited_process_no_longer_blocks':True,'installed_products_touched':False},indent=2))
