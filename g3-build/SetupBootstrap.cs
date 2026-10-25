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

[assembly:AssemblyVersion("1.5.29.0")]

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
 readonly Label detail=new Label(),stepLabel=new Label();readonly Timer progressTimer=new Timer();readonly Stopwatch elapsed=new Stopwatch();
 int step;DateTime workerStarted;string workerLog;static Action<int> verifiedFileProgress;

 public SetupForm(int pid) {

  previous=pid;Text=ProductTitle+" – "+(pid>0?"aktualisieren":"Installation");Width=760;Height=350;StartPosition=FormStartPosition.CenterScreen;FormBorderStyle=FormBorderStyle.FixedDialog;MaximizeBox=false;

  BackColor=Color.FromArgb(4,25,37);ForeColor=Color.White;Font=new Font("Segoe UI",11);Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);

  status.SetBounds(25,25,690,85);status.Text=Kind=="host_msi"?"Geprüftes Paket für das Host-Modul laden. Der Windows-Dienst wird gestartet; ein Windows-Neustart wird nicht ausgelöst.":"Geprüftes Installationspaket laden und den Client anschließend automatisch öffnen. Ein Windows-Neustart wird nicht ausgelöst.";

  detail.SetBounds(25,115,690,45);detail.ForeColor=Color.FromArgb(165,195,210);
  progress.SetBounds(25,170,690,22);stepLabel.SetBounds(25,200,690,30);
  start.SetBounds(465,245,250,35);start.Text="Installation starten";start.BackColor=Color.FromArgb(0,180,215);start.ForeColor=BackColor;start.Click+=async(s,e)=>await Install();Controls.AddRange(new Control[]{status,detail,progress,stepLabel,start});
  progressTimer.Interval=1000;progressTimer.Tick+=(s,e)=>RefreshProgress();FormClosed+=(s,e)=>progressTimer.Dispose();

  FormClosing+=(s,e)=>{if(working)e.Cancel=true;};if(pid>0)Shown+=async(s,e)=>await Install();

 }

 static string PackageName(string source){var m=Regex.Match(Path.GetFileName(source),@"kunde_([A-Za-z0-9_-]{32})(?:-host)?-install",RegexOptions.IgnoreCase);return m.Success?(Kind=="host_msi"?"g3-OpsLinX-Host-kunde_":"g3-OpsLinX-kunde_")+m.Groups[1].Value+(Kind=="host_msi"?"-host-install.msi":"-install.msi"):FileName;}

 static string Quote(string s){if(s.IndexOf('"')>=0)throw new InvalidDataException();return "\""+s+"\"";}

 void ShowStep(int number,string message,bool measurable){step=number;status.Text=message;progress.Style=measurable?ProgressBarStyle.Blocks:ProgressBarStyle.Marquee;progress.Value=0;stepLabel.Text="Schritt "+number+" von 5";RefreshProgress();}
 void ShowPercent(int percent,string description){percent=Math.Max(0,Math.Min(100,percent));progress.Value=percent;stepLabel.Text="Schritt "+step+" von 5 · "+percent+" % · "+description;}
 void RefreshProgress(){
  if(!working)return;
  detail.Text="Laufzeit: "+elapsed.Elapsed.ToString(@"mm\:ss");
  if(step!=3||workerLog==null)return;
  string phase=SetupProgress.ReadPhase(workerLog,workerStarted);
  if(phase!=null)status.Text=phase;
  if(elapsed.Elapsed.TotalSeconds>=60)detail.Text+="\nWindows kann für die Prüfung vorhandener Dateien mehrere Minuten benötigen.";
 }
 string HashDownloadedPackage(string path){using(var hash=SHA256.Create())using(var file=File.OpenRead(path)){
  var buffer=new byte[256*1024];long done=0,total=file.Length;int count,last=-1;
  while((count=file.Read(buffer,0,buffer.Length))>0){hash.TransformBlock(buffer,0,count,buffer,0);done+=count;int percent=total==0?100:(int)(done*100/total);if(percent!=last){last=percent;int value=percent;BeginInvoke((Action)(()=>ShowPercent(value,"Paketprüfung")));}}
  hash.TransformFinalBlock(new byte[0],0,0);return BitConverter.ToString(hash.Hash).Replace("-","").ToLowerInvariant();
 }}

 static string Digest(string f){using(var h=SHA256.Create())using(var s=File.OpenRead(f))return BitConverter.ToString(h.ComputeHash(s)).Replace("-","").ToLowerInvariant();}

 static bool VerifiedInstallation(bool checkService=true){try{
  string folder=Path.GetDirectoryName(InstalledExe)+Path.DirectorySeparatorChar;int count=0;
  using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("g3.payload"))using(var reader=new StreamReader(stream)){
   // The coordination file cannot be read while our exclusive lease is held.
   string line;while((line=reader.ReadLine())!=null){var item=line.Split('\t');if(item.Length!=2)return false;string file=Path.GetFullPath(Path.Combine(folder,item[0].Replace('/',Path.DirectorySeparatorChar)));if(!file.StartsWith(folder,StringComparison.OrdinalIgnoreCase)||!File.Exists(file))return false;if(item[0]!="g3-update-session.lock"&&Digest(file)!=item[1])return false;count++;if(verifiedFileProgress!=null)verifiedFileProgress(count);}
  }
  using(var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager")){var moves=key==null?null:key.GetValue("PendingFileRenameOperations") as string[];if(moves!=null)foreach(string move in moves)if(move.IndexOf(folder,StringComparison.OrdinalIgnoreCase)>=0)return false;}
  if(checkService)using(var svc=new ServiceController(AppName)){if(svc.Status!=ServiceControllerStatus.Running)return false;}
  return count>0;
 }catch{return false;}}
 static void OpenClient(){if(File.Exists(InstalledExe))Process.Start(new ProcessStartInfo(InstalledExe){UseShellExecute=true});}

 async Task Install(){if(working)return;working=true;start.Enabled=false;start.Text="Installation läuft …";workerLog=null;elapsed.Restart();progressTimer.Start();string previousHash=null;try {

  RequireCompanionProtocol();

  if(File.Exists(InstalledExe))previousHash=Digest(InstalledExe);

  var dir=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"g3NetworX","Fernwartung","Downloads","setup-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);var msi=Path.Combine(dir,PackageName(Application.ExecutablePath));

  ShowStep(1,"Installationspaket wird heruntergeladen …",true);ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;

  using(var c=new WebClient()){c.DownloadProgressChanged+=(s,e)=>ShowPercent(e.ProgressPercentage,"Download · "+(e.BytesReceived/1048576.0).ToString("0.0")+" / "+(e.TotalBytesToReceive/1048576.0).ToString("0.0")+" MB");await c.DownloadFileTaskAsync(new Uri("https://rust.g3nx.net/client/releases/"+Version+"/"+Kind),msi);}

  ShowStep(2,"Heruntergeladenes Paket wird auf Vollständigkeit und Unversehrtheit geprüft …",true);
  if(await Task.Run(()=>HashDownloadedPackage(msi))!=Hash)throw new InvalidDataException("Paketprüfung fehlgeschlagen.");

  ShowStep(3,"Windows-Berechtigung bestätigen. Danach wird die Installation vorbereitet …",false);

  var info=new ProcessStartInfo(Application.ExecutablePath,"--g3-install-worker "+Quote(msi)){UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden};

  // The running GUI remains alive until the worker owns the exclusive session gate.

  workerStarted=DateTime.UtcNow;
  using(var p=Process.Start(info)) {

   workerLog=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"g3-NetworX-Setup-"+AppName+"-"+Version,"install.log");
   status.Text="Windows bereitet die Installation vor und wartet auf das sichere Sitzungsende …";

   await Task.Run(()=>p.WaitForExit());if(p.ExitCode==1618)throw new UpdateBusyException();if(p.ExitCode!=0&&p.ExitCode!=3010)throw new InvalidOperationException("Installationsfehler "+p.ExitCode+". Protokoll: ProgramData\\g3-NetworX-Setup-"+AppName+"-"+Version+".");

  }

  workerLog=null;ShowStep(4,"Installierte Programmdateien und Dienst werden abschließend geprüft …",true);
  int files=0;using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("g3.payload"))using(var reader=new StreamReader(stream)){while(reader.ReadLine()!=null)files++;}
  int total=files,lastPercent=-1;verifiedFileProgress=count=>{int percent=total==0?0:count*100/total;if(percent!=lastPercent){lastPercent=percent;BeginInvoke((Action)(()=>ShowPercent(percent,"Dateien "+count+" / "+total)));}};
  bool verified;try{verified=await Task.Run(()=>VerifiedInstallation());}finally{verifiedFileProgress=null;}
  if(!verified)throw new InvalidDataException("Installierte Programmdatei stimmt nicht mit dem geprüften Paket überein.");
  ShowStep(5,"Installation abgeschlossen. Der Client wird geöffnet …",true);ShowPercent(100,"Abgeschlossen");OpenClient();working=false;progressTimer.Stop();Close();

 }catch(Exception ex){working=false;progressTimer.Stop();workerLog=null;progress.Style=ProgressBarStyle.Blocks;status.Text="Update nicht abgeschlossen. "+ex.Message;detail.Text="Laufzeit: "+elapsed.Elapsed.ToString(@"mm\:ss");start.Enabled=true;start.Text="Erneut versuchen";if(previous>0&&previousHash!=null)try{if(File.Exists(InstalledExe)&&Digest(InstalledExe)==previousHash&&!PreviousRunning())OpenClient();}catch{}}}

 bool PreviousRunning(){try{using(var p=Process.GetProcessById(previous))return !p.HasExited;}catch(ArgumentException){return false;}}
 static void RequireCompanionProtocol(){
  if(Kind!="host_msi")return;
  using(var key=Registry.LocalMachine.OpenSubKey(@"Software\g3Fernwartung\InstallState\g3Fernwartung")){
   if(key!=null&&Convert.ToInt32(key.GetValue("WindowsInstaller",0))==1&&Convert.ToInt32(key.GetValue("SharedDeviceIdentityProtocol",0))!=1)
    throw new InvalidOperationException("Bitte zuerst den FullClient auf die Version mit gemeinsamer Geräte-ID aktualisieren. Die vorhandene Host-ID bleibt erhalten.");
  }
 }
 sealed class Companion:IDisposable {
  readonly UpdateSessionGate gate;readonly string exe;bool stopped;
  public Companion(){
   if(Kind!="host_msi")return;
   RequireCompanionProtocol();
   using(var key=Registry.LocalMachine.OpenSubKey(@"Software\g3Fernwartung\InstallState\g3Fernwartung")){
    if(key==null||Convert.ToInt32(key.GetValue("WindowsInstaller",0))!=1)return;
    exe=Path.Combine(Convert.ToString(key.GetValue("InstallLocation")),"g3Fernwartung.exe");
    string root=Path.GetDirectoryName(exe),native=Path.Combine(root,"librustdesk.dll");
    if((File.GetAttributes(root)&FileAttributes.ReparsePoint)!=0||!File.Exists(native)||Array.IndexOf(GateDllHashes.Split(';'),Digest(native))<0)throw new UpdateBusyException();
    gate=new UpdateSessionGate(Path.Combine(root,"g3-update-session.lock"));
   }
  }
  public void Suspend(){
   if(gate==null)return;
   using(var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\g3Fernwartung")){
    if(key==null||!Convert.ToString(key.GetValue("ImagePath")).StartsWith(Quote(exe),StringComparison.OrdinalIgnoreCase))throw new InvalidDataException("FullClient-Dienstpfad stimmt nicht mit der geprüften Installation überein.");
   }
   using(var service=new ServiceController("g3Fernwartung")){if(service.Status!=ServiceControllerStatus.Stopped){service.Stop();stopped=true;service.WaitForStatus(ServiceControllerStatus.Stopped,TimeSpan.FromSeconds(40));}}
   var deadline=DateTime.UtcNow.AddSeconds(40);while(Remains()&&DateTime.UtcNow<deadline)System.Threading.Thread.Sleep(250);
   if(Remains())throw new UpdateBusyException();
  }
  bool Remains(){foreach(var process in Process.GetProcessesByName("g3Fernwartung"))using(process){if(!process.HasExited&&String.Equals(process.MainModule.FileName,exe,StringComparison.OrdinalIgnoreCase))return true;}return false;}
  public void Restore(){if(!stopped)return;using(var service=new ServiceController("g3Fernwartung")){if(service.Status==ServiceControllerStatus.Stopped)service.Start();service.WaitForStatus(ServiceControllerStatus.Running,TimeSpan.FromSeconds(40));stopped=false;}}
  public void Dispose(){try{Restore();}finally{if(gate!=null)gate.Dispose();}}
 }
 static bool OwnProcessesRemain(){foreach(string name in Kind=="host_msi"?new[]{AppName,"g3Host-ui"}:new[]{AppName})foreach(var p in Process.GetProcessesByName(name))using(p){if(p.HasExited)continue;string expected=name==AppName?InstalledExe:Path.Combine(Path.GetDirectoryName(InstalledExe),"g3Host-ui.exe");if(String.Equals(p.MainModule.FileName,expected,StringComparison.OrdinalIgnoreCase))return true;}return false;}
 static int Worker(string source){var root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"g3-NetworX-Setup-"+AppName+"-"+Version);UpdateSessionGate gate=null;Companion companion=null;bool stoppedByUs=false;try {

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
  companion=new Companion();companion.Suspend();
  // Native GUI/tray processes exit voluntarily only while this exclusive
  // lease is held. Incoming/outgoing session acquisition is now blocked.
  using(var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\"+AppName)){if(key!=null){if(!Convert.ToString(key.GetValue("ImagePath")).StartsWith(Quote(InstalledExe),StringComparison.OrdinalIgnoreCase))return 13;using(var svc=new ServiceController(AppName)){if(svc.Status!=ServiceControllerStatus.Stopped){svc.Stop();stoppedByUs=true;svc.WaitForStatus(ServiceControllerStatus.Stopped,TimeSpan.FromSeconds(40));}}}}
  var deadline=DateTime.UtcNow.AddSeconds(40);while(OwnProcessesRemain()&&DateTime.UtcNow<deadline)System.Threading.Thread.Sleep(250);
  if(OwnProcessesRemain())throw new UpdateBusyException();

  bool repair=String.Equals(Convert.ToString(Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\"+AppName+@"\InstallState\"+AppName,"MsiProductCode",null)),ProductCode,StringComparison.OrdinalIgnoreCase);
  var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"msiexec.exe"),"/i "+Quote(msi)+" /qn "+(repair?"REINSTALL=ALL ":"")+"REBOOT=ReallySuppress /norestart MSIRESTARTMANAGERCONTROL=Disable G3_BOOTSTRAP_CLOSED=1 /l*vx! "+Quote(Path.Combine(root,"install.log"))){UseShellExecute=false,CreateNoWindow=true};using(var p=Process.Start(info)){p.WaitForExit();int code=p.ExitCode;bool ready=false;if((code==0||code==3010)&&VerifiedInstallation(false)){using(var svc=new ServiceController(AppName)){if(svc.Status==ServiceControllerStatus.Stopped)svc.Start();svc.WaitForStatus(ServiceControllerStatus.Running,TimeSpan.FromSeconds(40));}ready=VerifiedInstallation();}companion.Restore();File.WriteAllText(Path.Combine(root,"result.txt"),"msi_exit="+code+";product_ready="+ready);return ready?code:1603;}

 }catch(UpdateBusyException ex){try{File.WriteAllText(Path.Combine(root,"result.txt"),"deferred_active_session: "+ex.Message);}catch{}return 1618;}catch(Exception ex){try{File.WriteAllText(Path.Combine(root,"update-error.txt"),ex.ToString());}catch{}return 1603;}finally{if(stoppedByUs)try{using(var svc=new ServiceController(AppName)){if(svc.Status==ServiceControllerStatus.Stopped)svc.Start();}}catch{}try{if(companion!=null)companion.Dispose();}catch(Exception ex){try{File.WriteAllText(Path.Combine(root,"companion-restore-error.txt"),ex.ToString());}catch{}}if(gate!=null)gate.Dispose();}}

 [STAThread]static int Main(string[] args){if(args.Length==2&&args[0]=="--g3-install-worker")return Worker(args[1]);int pid=0;if(args.Length==2&&args[0]=="--g3-wait-pid")int.TryParse(args[1],out pid);Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new SetupForm(pid));return 0;}

}

internal static class SetupProgress {
 public static string Phase(string text){
  string result=null;
  foreach(Match match in Regex.Matches(text,@"(?m)^(?:Aktion gestartet um|Action start) \d\d:\d\d:\d\d: ([A-Za-z0-9_]+)\.")){
   switch(match.Groups[1].Value){
    case "FindRelatedProducts":case "AppSearch":case "LaunchConditions":result="Windows prüft die vorhandene Installation und die Voraussetzungen …";break;
    case "CostInitialize":case "FileCost":case "CostFinalize":result="Windows prüft Speicherplatz und benötigte Programmdateien …";break;
    case "InstallValidate":result="Windows prüft vorhandene Dateien und deren Verwendung. Dieser Schritt kann mehrere Minuten dauern …";break;
    case "RemoveExistingProducts":case "RemoveFiles":result="Die bisherige Programmversion wird geordnet ersetzt …";break;
    case "InstallInitialize":case "ProcessComponents":result="Windows bereitet die Programmdateien vor …";break;
    case "InstallFiles":result="Neue Programmdateien werden kopiert …";break;
    case "WriteRegistryValues":case "RegisterProduct":case "PublishFeatures":case "PublishProduct":result="Windows registriert die neue Programmversion …";break;
    case "InstallServices":case "ExecServiceConfig":result="Der Client-Dienst wird eingerichtet …";break;
    case "StartServices":result="Der Client-Dienst wird gestartet …";break;
    case "InstallFinalize":result="Windows schließt die Installation ab und bestätigt die Änderungen …";break;
   }
  }
  return result;
 }
 public static string ReadPhase(string path,DateTime started){try{
  string folder=Path.GetDirectoryName(path);
  if(!Directory.Exists(folder)||(File.GetAttributes(folder)&FileAttributes.ReparsePoint)!=0||!File.Exists(path)||File.GetLastWriteTimeUtc(path)<started)return null;
  using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)){
   int first=file.ReadByte(),second=file.ReadByte();bool unicode=first==255&&second==254;
   long offset=Math.Max(unicode?2:0,file.Length-65536);if(unicode&&offset%2!=0)offset++;
   file.Position=offset;var bytes=new byte[(int)Math.Max(0,file.Length-offset)];int length=0,count;
   while(length<bytes.Length&&(count=file.Read(bytes,length,bytes.Length-length))>0)length+=count;
   string text=(unicode?System.Text.Encoding.Unicode:System.Text.Encoding.UTF8).GetString(bytes,0,length);
   if(offset>(unicode?2:0)){int newline=text.IndexOf('\n');if(newline>=0)text=text.Substring(newline+1);}
   return Phase(text);
  }
 }catch(IOException){return null;}catch(UnauthorizedAccessException){return null;}}
}

