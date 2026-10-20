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

[assembly:AssemblyTitle("g3 NetworX Installation")]

[assembly:AssemblyCompany("g3 NetworX UG & Co. KG")]

[assembly:AssemblyVersion("1.5.20.0")]

internal sealed class SetupForm:Form {

 const string Kind="@KIND@", Hash="@HASH@", FileName="@FILE@", Version="@VERSION@", ExeHash="@EXEHASH@";

 static string AppName {get{return Kind=="host_msi"?"g3Host":"g3Fernwartung";}}

 static string InstalledExe {get{return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),AppName,AppName+".exe");}}

 readonly Label status=new Label(); readonly Button start=new Button(); readonly ProgressBar progress=new ProgressBar();readonly int previous;bool working;

 public SetupForm(int pid) {

  previous=pid;Text="g3 NetworX – "+(pid>0?"Client aktualisieren":"Installation");Width=700;Height=280;StartPosition=FormStartPosition.CenterScreen;FormBorderStyle=FormBorderStyle.FixedDialog;MaximizeBox=false;

  BackColor=Color.FromArgb(4,25,37);ForeColor=Color.White;Font=new Font("Segoe UI",11);Icon=Icon.ExtractAssociatedIcon(Application.ExecutablePath);

  status.SetBounds(25,25,630,115);status.Text="Geprüftes Installationspaket laden und den Client anschließend automatisch öffnen. Ein Windows-Neustart wird nicht ausgelöst.";

  progress.SetBounds(25,150,630,22);start.SetBounds(405,190,250,35);start.Text="Installation starten";start.BackColor=Color.FromArgb(0,180,215);start.ForeColor=BackColor;start.Click+=async(s,e)=>await Install();Controls.AddRange(new Control[]{status,progress,start});

  FormClosing+=(s,e)=>{if(working)e.Cancel=true;};if(pid>0)Shown+=async(s,e)=>await Install();

 }

 static string PackageName(string source){var m=Regex.Match(Path.GetFileName(source),@"kunde_([A-Za-z0-9_-]{32})(?:-host)?-install",RegexOptions.IgnoreCase);return m.Success?(Kind=="host_msi"?"g3-Host-kunde_":"g3-Fernwartung-kunde_")+m.Groups[1].Value+(Kind=="host_msi"?"-host-install.msi":"-install.msi"):FileName;}

 static string Quote(string s){if(s.IndexOf('"')>=0)throw new InvalidDataException();return "\""+s+"\"";}

 static string Digest(string f){using(var h=SHA256.Create())using(var s=File.OpenRead(f))return BitConverter.ToString(h.ComputeHash(s)).Replace("-","").ToLowerInvariant();}

 static bool VerifiedInstallation(bool checkService=true){try{
  string folder=Path.GetDirectoryName(InstalledExe)+Path.DirectorySeparatorChar;int count=0;
  using(var stream=Assembly.GetExecutingAssembly().GetManifestResourceStream("g3.payload"))using(var reader=new StreamReader(stream)){
   string line;while((line=reader.ReadLine())!=null){var item=line.Split('\t');if(item.Length!=2)return false;string file=Path.GetFullPath(Path.Combine(folder,item[0].Replace('/',Path.DirectorySeparatorChar)));if(!file.StartsWith(folder,StringComparison.OrdinalIgnoreCase)||!File.Exists(file)||Digest(file)!=item[1])return false;count++;}
  }
  using(var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Control\Session Manager")){var moves=key==null?null:key.GetValue("PendingFileRenameOperations") as string[];if(moves!=null)foreach(string move in moves)if(move.IndexOf(folder,StringComparison.OrdinalIgnoreCase)>=0)return false;}
  if(checkService)using(var svc=new ServiceController(AppName)){if(svc.Status!=ServiceControllerStatus.Running)return false;}
  return count>0;
 }catch{return false;}}
 static void OpenClient(){if(File.Exists(InstalledExe))Process.Start(new ProcessStartInfo(InstalledExe){UseShellExecute=true});}

 async Task Install(){working=true;start.Enabled=false;string previousHash=null;try {

  if(File.Exists(InstalledExe))previousHash=Digest(InstalledExe);

  var dir=Path.Combine(Path.GetTempPath(),"g3-setup-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(dir);var msi=Path.Combine(dir,PackageName(Application.ExecutablePath));

  status.Text="Update wird heruntergeladen und vollständig geprüft …";ServicePointManager.SecurityProtocol=SecurityProtocolType.Tls12;

  using(var c=new WebClient()){c.DownloadProgressChanged+=(s,e)=>progress.Value=Math.Max(0,Math.Min(100,e.ProgressPercentage));await c.DownloadFileTaskAsync(new Uri("https://rust.g3nx.net/client/releases/"+Version+"/"+Kind),msi);}

  if(Digest(msi)!=Hash)throw new InvalidDataException("Paketprüfung fehlgeschlagen.");

  status.Text="Windows-Berechtigung bestätigen. Anschließend wird ausschließlich dieser Client aktualisiert.";

  var info=new ProcessStartInfo(Application.ExecutablePath,"--g3-install-worker "+Quote(msi)){UseShellExecute=true,Verb="runas",WindowStyle=ProcessWindowStyle.Hidden};

  if(previous>0)await Task.Run(()=>{try{using(var old=Process.GetProcessById(previous)){if(!old.WaitForExit(30000))throw new InvalidOperationException("Der bisherige Client ist noch aktiv.");}}catch(ArgumentException){}});

  using(var p=Process.Start(info)) {

   progress.Style=ProgressBarStyle.Marquee;status.Text="Installation läuft. Die Windows-Dateiprüfung kann mehrere Minuten dauern. Der Client wird anschließend automatisch geöffnet.";

   await Task.Run(()=>p.WaitForExit());if(p.ExitCode!=0&&p.ExitCode!=3010)throw new InvalidOperationException("Installationsfehler "+p.ExitCode+". Protokoll: ProgramData\\g3-NetworX-Setup-"+AppName+"-"+Version+".");

  }

  if(!VerifiedInstallation())throw new InvalidDataException("Installierte Programmdatei stimmt nicht mit dem geprüften Paket überein.");OpenClient();working=false;Close();

 }catch(Exception ex){working=false;progress.Style=ProgressBarStyle.Blocks;status.Text="Update nicht abgeschlossen. "+ex.Message;start.Enabled=true;start.Text="Erneut versuchen";if(previous>0&&previousHash!=null)try{if(File.Exists(InstalledExe)&&Digest(InstalledExe)==previousHash)OpenClient();}catch{}}}

 static int Worker(string source){var root=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"g3-NetworX-Setup-"+AppName+"-"+Version);try {

  if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))return 740;

  if(Directory.Exists(root)&&(File.GetAttributes(root)&FileAttributes.ReparsePoint)!=0)return 13;Directory.CreateDirectory(root);var acl=new DirectorySecurity();acl.SetAccessRuleProtection(true,false);acl.SetOwner(new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid,null));

  foreach(var id in new[]{WellKnownSidType.LocalSystemSid,WellKnownSidType.BuiltinAdministratorsSid})acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(id,null),FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));

  acl.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid,null),FileSystemRights.ReadAndExecute,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));Directory.SetAccessControl(root,acl);

  var msi=Path.Combine(root,PackageName(source));string staged=Path.Combine(root,"candidate-"+Guid.NewGuid().ToString("N")+".msi");File.Copy(source,staged,false);if(Digest(staged)!=Hash){File.Delete(staged);return 13;}if(File.Exists(msi))File.Replace(staged,msi,null);else File.Move(staged,msi);

  using(var key=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services\"+AppName)){if(key!=null){if(!Convert.ToString(key.GetValue("ImagePath")).StartsWith(Quote(InstalledExe),StringComparison.OrdinalIgnoreCase))return 13;using(var svc=new ServiceController(AppName)){if(svc.Status!=ServiceControllerStatus.Stopped){svc.Stop();svc.WaitForStatus(ServiceControllerStatus.Stopped,TimeSpan.FromSeconds(40));}}}}

  // Before MSI validation, release every instance of this product in this session.

  foreach(var old in Process.GetProcessesByName(AppName))using(old){if(old.HasExited)continue;if(!String.Equals(old.MainModule.FileName,InstalledExe,StringComparison.OrdinalIgnoreCase))continue;if(old.SessionId!=Process.GetCurrentProcess().SessionId)throw new InvalidOperationException("Dieser Client wird noch in einer anderen Windows-Sitzung verwendet.");old.CloseMainWindow();if(!old.WaitForExit(5000)){old.Kill();if(!old.WaitForExit(10000))throw new InvalidOperationException("Client konnte nicht beendet werden.");}}

  var info=new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"msiexec.exe"),"/i "+Quote(msi)+" /qn REBOOT=ReallySuppress /norestart MSIRESTARTMANAGERCONTROL=Disable G3_BOOTSTRAP_CLOSED=1 /l*vx! "+Quote(Path.Combine(root,"install.log"))){UseShellExecute=false,CreateNoWindow=true};using(var p=Process.Start(info)){p.WaitForExit();int code=p.ExitCode;bool ready=false;if((code==0||code==3010)&&VerifiedInstallation(false)){using(var svc=new ServiceController(AppName)){if(svc.Status==ServiceControllerStatus.Stopped)svc.Start();svc.WaitForStatus(ServiceControllerStatus.Running,TimeSpan.FromSeconds(40));}ready=VerifiedInstallation();}File.WriteAllText(Path.Combine(root,"result.txt"),"msi_exit="+code+";product_ready="+ready);return ready?code:1603;}

 }catch(Exception ex){try{File.WriteAllText(Path.Combine(root,"update-error.txt"),ex.ToString());}catch{}return 1603;}finally{try{using(var svc=new ServiceController(AppName)){if(svc.Status==ServiceControllerStatus.Stopped)svc.Start();}}catch{}}}

 [STAThread]static int Main(string[] args){if(args.Length==2&&args[0]=="--g3-install-worker")return Worker(args[1]);int pid=0;if(args.Length==2&&args[0]=="--g3-wait-pid")int.TryParse(args[1],out pid);Application.EnableVisualStyles();Application.SetCompatibleTextRenderingDefault(false);Application.Run(new SetupForm(pid));return 0;}

}

