param([Parameter(Mandatory=$true)][string]$PackageDirectory)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable GitHub-hosted runner required'}
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$setup=(Get-ChildItem $PackageDirectory -Filter '*.exe').FullName
$msi=(Get-ChildItem $PackageDirectory -Filter '*.msi').FullName
$proof=Get-Content (Join-Path $PackageDirectory 'package.json') -Raw | ConvertFrom-Json
foreach($item in $proof.packages.PSObject.Properties){if((Get-FileHash (Join-Path $PackageDirectory $item.Name)).Hash.ToLowerInvariant() -ne $item.Value){throw 'Candidate hash mismatch'}}
$root=Join-Path $env:ProgramFiles 'g3Host';$exe=Join-Path $root 'g3Host.exe'
$cargo=Get-Content (Join-Path $PSScriptRoot '../Cargo.toml') -Raw
$packageSection=[regex]::Match($cargo,'(?ms)^\[package\]\s*(.*?)(?=^\[|\z)').Groups[1].Value
$coreVersion=[regex]::Match($packageSection,'(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
if(!$coreVersion){throw 'Native core version missing from Cargo package metadata'}
function Worker {
 $p=Start-Process $setup -ArgumentList ('--g3-install-worker "'+$msi+'"') -WindowStyle Hidden -Wait -PassThru
 return $p.ExitCode
}
function Ready {
 if((Get-Service g3Host).Status -ne 'Running'){throw 'Core Host service not running'}
 $recovery=(& sc.exe qfailure g3Host | Out-String)
 if($LASTEXITCODE -ne 0 -or @([regex]::Matches($recovery,'RESTART\s+--\s+Delay = 60000 milliseconds')).Count -ne 3 -or $recovery -notmatch '86400'){throw 'Host recovery actions must restart after 60 seconds for all failures and reset after one day'}
 if((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run').g3HostTray -ne ('"'+$exe+'" --tray')){throw 'Host machine-wide tray logon registration missing or incorrect'}
 foreach($item in $proof.payload.PSObject.Properties){$f=Join-Path $root $item.Name;if(!(Test-Path $f)){throw 'Payload missing'};if($item.Name -ne 'g3-update-session.lock' -and (Get-FileHash $f).Hash.ToLowerInvariant() -ne $item.Value){throw 'Payload changed'}}
 foreach($file in @('g3Host-ui.exe','flutter_windows.dll','data/app.so')){if(!(Test-Path (Join-Path $root $file))){throw "Host interface payload missing: $file"}}
 $identityPins=Get-ItemProperty 'HKLM:\SOFTWARE\g3Host\InstallState\g3Host'
 if($identityPins.HostCoreSha256 -ne (Get-FileHash $exe).Hash.ToLowerInvariant() -or $identityPins.HostUiSha256 -ne (Get-FileHash (Join-Path $root 'g3Host-ui.exe')).Hash.ToLowerInvariant()){throw 'Host IPC identity pins do not match the installed pair'}
}
$code=Worker;if($code -notin @(0,3010)){throw "Clean install failed: $code"};Ready
$engine=Join-Path $root 'flutter_windows.dll'
Move-Item -LiteralPath $engine -Destination ($engine+'.core-test')
try {$version=(& $exe --version | Out-String).Trim();if($version -ne $coreVersion){throw "Native CLI version failed without GUI engine: expected Cargo package $coreVersion, got $version"}}finally{Move-Item -LiteralPath ($engine+'.core-test') -Destination $engine}
$id=(& $exe --get-id | Out-String).Trim();if($id -notmatch '^\d{6,12}$'){throw 'Native service identity unavailable'}
$tray=Start-Process $exe -PassThru
$deadline=(Get-Date).AddSeconds(40);$gui=$null
do {
 Start-Sleep -Milliseconds 500
 $gui=Get-Process -Name 'g3Host-ui' -ErrorAction SilentlyContinue | Where-Object {$_.MainWindowHandle -ne 0} | Select-Object -First 1
}while(!$gui -and (Get-Date) -lt $deadline)
if(!$gui){throw 'Host interface did not open from the installed native launcher'}
if($gui.Path -ne (Join-Path $root 'g3Host-ui.exe')){throw 'Host interface launched outside the installed payload'}
Add-Type -AssemblyName Accessibility
Add-Type -ReferencedAssemblies @(([Accessibility.IAccessible].Assembly.Location),(Join-Path $PSHOME 'ref/System.Collections.dll')) -CompilerOptions '/nowarn:1701' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HostAccessibility {
 [DllImport("oleacc.dll")] public static extern int AccessibleObjectFromWindow(IntPtr window,uint id,ref Guid iid,[MarshalAs(UnmanagedType.Interface)] out object accessible);
 public delegate bool EnumChild(IntPtr child,IntPtr state);
 [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr window,EnumChild callback,IntPtr state);
 public static IntPtr[] Children(IntPtr window) {
  var handles=new System.Collections.Generic.List<IntPtr>();
  EnumChildWindows(window,(child,state)=>{handles.Add(child);return true;},IntPtr.Zero);
  return handles.ToArray();
 }
 static void Fields(Accessibility.IAccessible node,int child,System.Collections.Generic.List<string> labels) {
  labels.Add(node.get_accName(child)??"");
  labels.Add(node.get_accDescription(child)??"");
  try {labels.Add(node.get_accValue(child)??"");}catch(COMException){}
  try {labels.Add(node.get_accHelp(child)??"");}catch(COMException){}
 }
 static void Read(Accessibility.IAccessible node,System.Collections.Generic.List<string> labels,int depth) {
  if(depth>64 || labels.Count>2000)return;
  Fields(node,0,labels);
  int count=Math.Min(node.accChildCount,500);
  for(int i=1;i<=count;i++) {
   object child=node.get_accChild(i);
   if(child is Accessibility.IAccessible)Read((Accessibility.IAccessible)child,labels,depth+1);
   else Fields(node,i,labels);
  }
 }
 public static string[] Labels(IntPtr window) {
  var labels=new System.Collections.Generic.List<string>();object accessible;
  Guid iid=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
  if(AccessibleObjectFromWindow(window,4294967292,ref iid,out accessible)==0 && accessible is Accessibility.IAccessible)
   Read((Accessibility.IAccessible)accessible,labels,0);
  return labels.ToArray();
 }
 static void Nodes(Accessibility.IAccessible node,System.Collections.Generic.List<Accessibility.IAccessible> nodes,int depth) {
  if(depth>64 || nodes.Count>2000)return;nodes.Add(node);
  for(int i=1;i<=Math.Min(node.accChildCount,500);i++) {
   var child=node.get_accChild(i) as Accessibility.IAccessible;if(child!=null)Nodes(child,nodes,depth+1);
  }
 }
 public static bool OpenSettings(IntPtr window) {
  object accessible;Guid iid=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
  if(AccessibleObjectFromWindow(window,4294967292,ref iid,out accessible)!=0)return false;
  var nodes=new System.Collections.Generic.List<Accessibility.IAccessible>();
  Nodes((Accessibility.IAccessible)accessible,nodes,0);
  Accessibility.IAccessible anchor=null;
  foreach(var node in nodes)if(node.get_accName(0)=="ID"){if(anchor!=null)return false;anchor=node;}
  if(anchor==null)return false;
  int x,y,w,h;anchor.accLocation(out x,out y,out w,out h,0);
  Accessibility.IAccessible button=null;
  foreach(var node in nodes) {
   if(String.IsNullOrEmpty(node.get_accDefaultAction(0)))continue;
   int bx,by,bw,bh;node.accLocation(out bx,out by,out bw,out bh,0);
   if(bx>x+w && Math.Abs(by-y)<=24 && bw>=10 && bw<=60 && bh>=10 && bh<=60) {
    if(button!=null)return false;button=node;
   }
  }
  if(button==null)return false;button.accDoDefaultAction(0);return true;
 }
}
'@
$childWindows=@([HostAccessibility]::Children($gui.MainWindowHandle))
$deadline=(Get-Date).AddSeconds(30);$interfaceReady=$false
$initialId=$id
do {
 $id=(& $exe --get-id | Out-String).Trim()
 if($id -notmatch '^\d{6,12}$'){throw 'Native identity unavailable during interface check'}
 $labels=@(foreach($child in $childWindows){[HostAccessibility]::Labels($child)})
 $plain=($labels -join ' ') -replace '\s',''
 $interfaceReady=$plain.Contains($id) -and ($labels -match 'One-time Password|Einmalpasswort') -and ($labels -contains 'Updates')
 if(!$interfaceReady){Start-Sleep -Milliseconds 500}
}while(!$interfaceReady -and (Get-Date) -lt $deadline)
if(!$interfaceReady){
 $aliasId=(& (Join-Path $root 'g3Host-ui.exe') --get-id | Out-String).Trim()
 @{labelCount=$labels.Count;embeddedWindows=$childWindows.Count;idChangedDuringView=($id -ne $initialId);aliasCliMatchesService=($aliasId -eq $id);idPresent=$plain.Contains($id);numericFieldLengths=@($labels | Where-Object {($_ -replace '\s','') -match '^\d{6,12}$'} | ForEach-Object {($_ -replace '\s','').Length});passwordBoardPresent=[bool]($labels -match 'One-time Password|Einmalpasswort');updatesPresent=($labels -contains 'Updates');settingsPresent=[bool]($labels -match '\bSettings\b|\bEinstellungen\b')} | ConvertTo-Json -Compress | Write-Output
 throw 'Host accessibility tree lacks native ID, one-time-password board, Updates or Settings'
}
$settingsOpened=$false
foreach($child in $childWindows){if([HostAccessibility]::OpenSettings($child)){$settingsOpened=$true;break}}
if(!$settingsOpened){throw 'Unique Host Settings action beside the ID board was not accessible'}
$deadline=(Get-Date).AddSeconds(15);$settingsReady=$false
do {
 $settingsLabels=@(foreach($child in $childWindows){[HostAccessibility]::Labels($child)})
 $settingsReady=[bool]($settingsLabels -match '\bGeneral\b|\bAllgemein\b') -and [bool]($settingsLabels -match '\bSecurity\b|\bSicherheit\b')
 if(!$settingsReady){Start-Sleep -Milliseconds 500}
}while(!$settingsReady -and (Get-Date) -lt $deadline)
if(!$settingsReady){throw 'Host Settings did not display General and Security after its normal accessible action'}
$gate=(Join-Path $PSScriptRoot '../src/g3_update_gate.rs').Replace('\','/')
$fixture=@"
extern crate self as hbb_common;
pub mod log {pub use std::eprintln as error;}
#[path="$gate"] mod gate;
fn main(){let _lease=gate::session().unwrap().unwrap();println!("READY");let mut line=String::new();std::io::stdin().read_line(&mut line).unwrap();}
"@
$source=Join-Path $PackageDirectory 'session.rs';$fixture | Set-Content $source -Encoding utf8
$sessionExe=Join-Path $root 'g3-core-session-fixture.exe'
rustc --edition=2021 $source -o $sessionExe
if($LASTEXITCODE){throw 'Native lease fixture failed to compile'}
$psi=[Diagnostics.ProcessStartInfo]::new($sessionExe);$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true
$session=[Diagnostics.Process]::Start($psi)
try {
 if($session.StandardOutput.ReadLine() -ne 'READY'){throw 'Native session lease not held'}
 $before=(Get-CimInstance Win32_Service -Filter "Name='g3Host'").ProcessId
 $code=Worker;if($code -ne 1618){throw "Busy install was not deferred: $code"}
 if($session.HasExited -or (Get-Service g3Host).Status -ne 'Running' -or (Get-CimInstance Win32_Service -Filter "Name='g3Host'").ProcessId -ne $before){throw 'Busy install interrupted service/session'}
}finally{if(!$session.HasExited){$session.StandardInput.WriteLine('');if(!$session.WaitForExit(10000)){throw 'Lease fixture did not exit voluntarily'}};$session.Dispose()}
Set-Content (Join-Path $root 'SOURCE.txt') 'Deliberately changed disposable fixture'
$code=Worker;if($code -notin @(0,3010)){throw "Idle repair failed: $code"};Ready
if(!$tray.WaitForExit(10000) -or !$gui.WaitForExit(10000)){throw 'Idle Host interface/tray did not exit voluntarily for repair'}
if((& $exe --get-id | Out-String).Trim() -ne $id){throw 'Identity changed across repair'}
$remove=Start-Process msiexec.exe -ArgumentList ('/x "'+$msi+'" /qn REBOOT=ReallySuppress /norestart') -WindowStyle Hidden -Wait -PassThru
if($remove.ExitCode -notin @(0,3010)){throw 'Disposable removal failed'}
if(Get-Service g3Host -ErrorAction SilentlyContinue){throw 'Service not removed'}
if((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -ne $boot){throw 'Runner rebooted'}
@{version=$proof.version;native_core_version=$version;clean_install=$true;native_cli=$true;host_interface_opened=$true;host_interface_id_otp_updates_settings=$true;active_lease_deferred=$true;service_pid_unchanged_while_busy=$true;idle_repair=$true;identity_preserved=$true;uninstall=$true;no_reboot=$true;actual_server_core_runtime='requires separate target preflight';scope='disposable GitHub-hosted Windows runner'} | ConvertTo-Json | Set-Content (Join-Path $PackageDirectory 'core-installation-acceptance.json') -Encoding utf8
