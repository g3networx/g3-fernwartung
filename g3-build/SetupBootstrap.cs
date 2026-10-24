using System;

using System.Diagnostics;

using System.IO;

using System.Net;

using System.Security.Cryptography;

using System.Threading.Tasks;

using System.Windows.Forms;

using System.Drawing;

using System.Reflection;

using System.ServiceProcess;

using System.Security.AccessControl;

using System.Security.Principal;

using Microsoft.Win32;

using System.Text.RegularExpressions;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

[assembly:AssemblyTitle("g3 OpsLinX Installation")]

[assembly:AssemblyCompany("g3 NetworX UG & Co. KG")]

[assembly:AssemblyVersion("1.5.27.0")]

internal sealed class UpdateBusyException:Exception {public UpdateBusyException():base("Update zurückgestellt: Eine Fernwartung oder ein anderer Client ist noch aktiv. Bitte nach Sitzungsende erneut versuchen.") {}}
internal sealed class UpdateSessionGate:IDisposable {
 readonly FileStream file;
 [StructLayout(LayoutKind.Sequential)]struct Overlapped {public UIntPtr Internal,InternalHigh;public uint Offset,OffsetHigh;public IntPtr Event;}
 [DllImport("kernel32.dll",SetLastError=true)]static extern bool LockFileEx(SafeFileHandle handle,uint flags,uint reserved,uint low,uint high,ref Overlapped overlapped);
 public UpdateSessionGate(string path){file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite);var overlap=new Overlapped();if(!LockFileEx(file.SafeFileHandle,3,0,1,0,ref overlap)){int error=Marshal.GetLastWin32Error();file.Dispose();if(error==33)throw new UpdateBusyException();throw new System.ComponentModel.Win32Exception(error);}}
 public void Dispose(){file.Dispose();}
}
internal sealed class SetupForm:Form {

 const string Kind="@KIND@", Hash="@HASH@", FileName="@FILE@", Version="@VERSION@", ExeHash="@EXEHASH@", GateDllHashes="@GATE_DLL_HASHES@", ProductCode="@PRODUCTCODE@";

 static string AppName {get{return Kind=="host_msi"?"g3Host":"g3Fernwartung";}}

 static string ProductTitle {get{return Kind=="host_msi"?"g3 OpsLinX Host":"g3 OpsLinX";}}

 static string InstalledExe {get{return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),AppName,AppName+".exe");}}

 readonly Label status=new Label(); readonly Button start=new Button(); readonly ProgressBar progress=new ProgressBar();readonly int previous;bool working;

 public SetupForm(int pid) {

  previous=pid;Text=ProductTitle+" – "+(pid>0?"aktualisieren":"Installation");Width=700;Height=280;StartPosition=FormStartPosition.CenterScreen;FormBorderStyle=FormBorderStyle.FixedDialog;MaximizeBox=false;

  BackColor=Color.FromArgb(4,25,37);ForeColor=Color.White;Font=new Font("Segoe UI",11);Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);

  status.SetBounds(25,25,630,115);status.Text=Kind=="host_msi"?"Geprüftes Paket für das Host-Modul laden. Der Windows-Dienst wird gestartet; ein Windows-Neustart wird nicht ausgelöst.":"Geprüftes Installationspaket laden und den Client anschließend automatisch öffnen. Ein Windows-Neustart wird nicht ausgelöst.";

  progress.SetBounds(25,150,630,22);start.SetBounds(405,190,250,35);start.Text="Installation starten";start.BackColor=Color.FromArgb(0,180,215);start.ForeColor=BackColor;start.Click+=async(s,e)=>await Install();Controls.AddRange(new Control[]{status,progress,start});

  FormClosing+=(s,e)=>{if(working)e.Cancel=true;};if(pid>0)Shown+=async(s,e)=>await Install();

 }

 static string PackageName(string source){var m=Regex.Match(Path.GetFileName(source),@"kunde_([A-Za-z0-9_-]{32})(?:-host)?-install",RegexOptions.IgnoreCase);return m.Success?(Kind=="host_msi"?"g3-OpsLinX-Host-kunde_":"g3-OpsLinX-kunde_")+m.Groups[1].Value+(Kind=="host_msi"?"-host-install.msi":"-install.msi"):FileName;}

 static string Quote(string s){if(s.IndexOf('"')>=0)throw new InvalidDataException();return "\""+s+"\"";}

 static string Digest(string f){using(var h=SHA256.Create())using(var s=File.OpenRead(f))return BitConverter.ToString(h.ComputeHash(s)).Replace("-","").ToLowerInvariant();}

 static bool VerifiedInstallation(bool checkService=true){try{
  string folder=Path.GetDirectoryName(InstalledExe)+Path.DirectorySeparatorChar;int count=0;
  using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("g3.payload"))using(var reader=new StreamReader(stream)){
   // The coordination file cannot be read while our exclusive lease is held.
   string line;while((line=reader.ReadLine())!=null){var item=line.Split('\t');if(item.Length!=2)return false;string file=Path.GetFullPath(Path.Combine(folder,item[0].Replace('/',Path.DirectorySeparatorChar)));if(!file.StartsWith(folder,StringComparison.OrdinalIgnoreCase)||!File.Exists(file))return false;if(item[0]!="g3-update-session.lock"&&Digest(file)!=item[1])return false;count++;}
  }
  using(var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager")){var moves=key==null?null:key.GetValue("PendingFileRenameOperations") as string[];if(moves!=null)foreach(string move in moves)if(move.IndexOf(folder,StringComparison.OrdinalIgnoreCase)>=0)return false;}
  if(checkService)using(var svc=new ServiceController(AppName)){if(svc.Status!=ServiceControllerStatus.Running)return false;}
  return count>0;
 }catch{return false;}}
 static void OpenClient(){if(File.Exists(InstalledExe))Process.Start(new ProcessStartInfo(InstalledExe,Kind=="host_msi"?"--tray":""){UseShellExecute=true});}

 async Task Install(){working=true;start.Enabled=false;string previousHash=null;try {

  if(File.Exists(InstalledExe))previousHash=Digest(InstalledExe);

  var dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"g3NetworX","Fernwartung","Downloads","setup-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);var msi=Path.Combine(dir,PackageName(Application.ExecutablePath));

  status.Text="Update wird heruntergeladen und vollständig geprüft …";ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;

  using(var c=new WebClient()){c.DownloadProgressChanged+=(s,e)=>progress.Value=Math.Max(0,Math.Min(100,e.ProgressPercentage));await c.DownloadFileTaskAsync(new Uri("https://rust.g3nx.net/client/releases/"+Version+"/"+Kind),msi);}

  if(Digest(msi)!=Hash)throw new InvalidDataException("Paketprüfung fehlgeschlagen.");

  status.Text="Windows-Berechtigung bestätigen. Anschließend wird ausschließlich dieser Client aktualisiert.";

  var info=new ProcessStartInfo(Application.ExecutablePath,"--g3-install-worker "+Quote(msi)){UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden};

  // The running GUI remains alive until the worker owns the exclusive session gate.

  using(var p=Process.Start(info)) {

   progress.Style=ProgressBarStyle.Marquee;status.Text="Installation läuft. Die Windows-Dateiprüfung kann mehrere Minuten dauern. Der Client wird anschließend automatisch geöffnet.";

   await Task.Run(()=>p.WaitForExit());if(p.ExitCode==1618)throw new UpdateBusyException();if(p.ExitCode!=0&&p.ExitCode!=3010)throw new InvalidOperationException("Installationsfehler "+p.ExitCode+". Protokoll: ProgramData\\g3-NetworX-Setup-"+AppName+"-"+Version+".");

  }

  if(!VerifiedInstallation())throw new InvalidDataException("Installierte Programmdatei stimmt nicht mit dem geprüften Paket überein.");OpenClient();working=false;Close();

 }catch(Exception ex){working=false;progress.Style=ProgressBarStyle.Blocks;status.Text="Update nicht abgeschlossen. "+ex.Message;start.Enabled=true;start.Text="Erneut versuchen";if(previous>0&&previousHash!=null)try{if(File.Exists(InstalledExe)&&Digest(InstalledExe)==previousHash&&!PreviousRunning())OpenClient();}catch{}}}

 bool PreviousRunning(){try{using(var p=Process.GetProcessById(previous))return !p.HasExited;}catch(ArgumentException){return false;}}
 static bool OwnProcessesRemain(){foreach(var p in Process.GetProcessesByName(AppName))using(p){if(p.HasExited)continue;if(String.Equals(p.MainModule.FileName,InstalledExe,StringComparison.OrdinalIgnoreCase))return true;}return false;}
 static int Worker(string source){var root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"g3-NetworX-Setup-"+AppName+"-"+Version);UpdateSessionGate gate=null;bool stoppedByUs=false;try {

  if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))return 740;

  if(Directory.Exists(root)&&(File.GetAttributes(root)&FileAttributes.ReparsePoint)!=0)return 13;Directory.CreateDirectory(root);var acl=new DirectorySecurity();acl.SetAccessRuleProtection(true,false);acl.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null));

  foreach(var id in new[]{WellKnownSidType.LocalSystemSid,WellKnownSidType.BuiltinAdministratorsSid})acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(id,null),FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));

  acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid,null),FileSystemRights.ReadAndExecute,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));Directory.SetAccessControl(root,acl);

  var msi=Path.Combine(root,PackageName(source));string staged=Path.Combine(root,"candidate-"+Guid.NewGuid().ToString("N")+".msi");File.Copy(source,staged,false);if(Digest(staged)!=Hash){File.Delete(staged);return 13;}if(File.Exists(msi))File.Replace(staged,msi,null);else File.Move(staged,msi);

  string gatePath=Path.Combine(Path.GetDirectoryName(InstalledExe),"g3-update-session.lock");
  string native=Path.Combine(Path.GetDirectoryName(InstalledExe),"librustdesk.dll");
  bool compatible=File.Exists(native)&&Array.IndexOf(GateDllHashes.Split(';'),Digest(native))>=0;
  if((!File.Exists(gatePath)||!compatible)&&OwnProcessesRemain())throw new UpdateBusyException();
  if(!File.Exists(gatePath)){
   // Legacy clients cannot prove absence of sessions. Never shut them down.
   if(OwnProcessesRemain())throw new UpdateBusyException();
   Directory.CreateDirectory(Path.GetDirectoryName(gatePath));
   using(var f=new FileStream(gatePath,FileMode.CreateNew,FileAccess.Write,FileShare.None)){f.Flush();}
  }
  gate=new UpdateSessionGate(gatePath);
  // Native GUI/tray processes exit voluntarily only while this exclusive
  // lease is held. Incoming/outgoing session acquisition is now blocked.
  using(var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\"+AppName)){if(key!=null){if(!Convert.ToString(key.GetValue("ImagePath")).StartsWith(Quote(InstalledExe),StringComparison.OrdinalIgnoreCase))return 13;using(var svc=new ServiceController(AppName)){if(svc.Status!=ServiceControllerStatus.Stopped){svc.Stop();stoppedByUs=true;svc.WaitForStatus(ServiceControllerStatus.Stopped,TimeSpan.FromSeconds(40));}}}}
  var deadline=DateTime.UtcNow.AddSeconds(40);while(OwnProcessesRemain()&&DateTime.UtcNow<deadline)System.Threading.Thread.Sleep(250);
  if(OwnProcessesRemain())throw new UpdateBusyException();

  bool repair=String.Equals(Convert.ToString(Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\"+AppName+@"\InstallState\"+AppName,"MsiProductCode",null)),ProductCode,StringComparison.OrdinalIgnoreCase);
  var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"msiexec.exe"),"/i "+Quote(msi)+" /qn "+(repair?"REINSTALL=ALL ":"")+"REBOOT=ReallySuppress /norestart MSIRESTARTMANAGERCONTROL=Disable G3_BOOTSTRAP_CLOSED=1 /l*vx! "+Quote(Path.Combine(root,"install.log"))){UseShellExecute=false,CreateNoWindow=true};using(var p=Process.Start(info)){p.WaitForExit();int code=p.ExitCode;bool ready=false;if((code==0||code==3010)&&VerifiedInstallation(false)){using(var svc=new ServiceController(AppName)){if(svc.Status==ServiceControllerStatus.Stopped)svc.Start();svc.WaitForStatus(ServiceControllerStatus.Running,TimeSpan.FromSeconds(40));}ready=VerifiedInstallation();}File.WriteAllText(Path.Combine(root,"result.txt"),"msi_exit="+code+";product_ready="+ready);return ready?code:1603;}

 }catch(UpdateBusyException ex){try{File.WriteAllText(Path.Combine(root,"result.txt"),"deferred_active_session: "+ex.Message);}catch{}return 1618;}catch(Exception ex){try{File.WriteAllText(Path.Combine(root,"update-error.txt"),ex.ToString());}catch{}return 1603;}finally{if(stoppedByUs)try{using(var svc=new ServiceController(AppName)){if(svc.Status==ServiceControllerStatus.Stopped)svc.Start();}}catch{}if(gate!=null)gate.Dispose();}}

 [STAThread]static int Main(string[] args){if(args.Length==2&&args[0]=="--g3-install-worker")return Worker(args[1]);int pid=0;if(args.Length==2&&args[0]=="--g3-wait-pid")int.TryParse(args[1],out pid);Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new SetupForm(pid));return 0;}

}

