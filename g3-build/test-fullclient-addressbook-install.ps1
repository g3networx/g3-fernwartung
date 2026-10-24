param([Parameter(Mandatory=$true)][string]$PackageDirectory)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable GitHub-hosted runner required'}
$package=(Resolve-Path $PackageDirectory).Path
$proof=Get-Content (Join-Path $package 'candidate.json') -Raw|ConvertFrom-Json
foreach($item in $proof.packages){$file=Join-Path $package $item.file;if((Get-Item $file).Length -ne $item.size -or (Get-FileHash $file).Hash.ToLowerInvariant() -ne $item.sha256){throw 'Pinned package mismatch'}}
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$root=Join-Path $env:ProgramFiles 'g3Fernwartung';$exe=Join-Path $root 'g3Fernwartung.exe'
$setup=Join-Path $package 'g3-OpsLinX-1.5.0-g3.30-install.exe';$msi=Join-Path $package 'g3-OpsLinX-1.5.0-g3.30-install.msi'
$baselineSetup=Join-Path $package 'g3-OpsLinX-1.5.0-g3.29-install.exe';$baselineMsi=Join-Path $package 'g3-OpsLinX-1.5.0-g3.29-install.msi'
function Worker([string]$launcher=$setup,[string]$database=$msi){
 $p=Start-Process $launcher -ArgumentList @('--g3-install-worker',('"'+$database+'"')) -WindowStyle Hidden -Wait -PassThru
 return $p.ExitCode
}
function Ready {
 if((Get-Service g3Fernwartung).Status -ne 'Running'){throw 'FullClient service not running'}
 if((Get-Service g3Fernwartung).StartType -ne 'Automatic'){throw 'FullClient autostart missing'}
 $product=Get-ItemProperty ('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\'+$proof.product_code)
 if($product.DisplayVersion -ne '1.5.30'){throw 'Incorrect installed product version'}
 if((Get-FileHash (Join-Path $root 'librustdesk.dll')).Hash.ToLowerInvariant() -ne $proof.native_sha256){throw 'Accepted native core differs'}
 $recovery=(& sc.exe qfailure g3Fernwartung|Out-String)
 if([regex]::Matches($recovery,'RESTART\s+--\s+Delay = 60000 milliseconds').Count -ne 3 -or $recovery -notmatch '86400'){throw 'Service recovery differs'}
 if((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run').g3FernwartungTray -ne ('"'+$exe+'" --tray')){throw 'Tray autostart differs'}
 if(Get-Service g3Host -ErrorAction SilentlyContinue){throw 'FullClient unexpectedly installed Host'}
}
function Identity { $id=(& $exe --get-id|Out-String).Trim();if($id -notmatch '^\d{6,12}$'){throw 'Native identity unavailable'};return $id }
function RemoveNew {
 $p=Start-Process msiexec.exe -ArgumentList @('/x',('"'+$msi+'"'),'/qn','REBOOT=ReallySuppress','/norestart') -WindowStyle Hidden -Wait -PassThru
 if($p.ExitCode -notin @(0,3010)){throw 'Disposable uninstall failed'}
}
if((Worker) -notin @(0,3010)){throw 'Clean install failed'}
Ready;$id=Identity
Start-Process $exe | Out-Null
$deadline=(Get-Date).AddSeconds(45)
do {Start-Sleep -Milliseconds 500;$gui=Get-Process g3Fernwartung -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $exe -and $_.MainWindowHandle -ne 0}|Select-Object -First 1}while(!$gui -and (Get-Date) -lt $deadline)
if(!$gui){throw 'Installed FullClient window missing'}
Add-Type -AssemblyName Accessibility
Add-Type -ReferencedAssemblies @(([Accessibility.IAccessible].Assembly.Location),(Join-Path $PSHOME 'ref/System.Collections.dll')) -CompilerOptions '/nowarn:1701' -TypeDefinition @'
using System;using System.Runtime.InteropServices;using System.Collections.Generic;
public static class FullClientAccessibility {
 [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr w,uint id,ref Guid iid,[MarshalAs(UnmanagedType.Interface)]out object a);
 public delegate bool EnumChild(IntPtr child,IntPtr state);
 [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr w,EnumChild cb,IntPtr state);
 static void Fields(Accessibility.IAccessible n,object child,List<string> text){try{var v=n.get_accName(child);if(!String.IsNullOrEmpty(v))text.Add(v);}catch(COMException){}try{var v=n.get_accDescription(child);if(!String.IsNullOrEmpty(v))text.Add(v);}catch(COMException){}try{var v=n.get_accValue(child);if(!String.IsNullOrEmpty(v))text.Add(v);}catch(COMException){}try{var v=n.get_accHelp(child);if(!String.IsNullOrEmpty(v))text.Add(v);}catch(COMException){}}
 static void Read(Accessibility.IAccessible n,List<string> text,int depth){if(depth>64||text.Count>2000)return;Fields(n,0,text);int count=0;try{count=n.accChildCount;}catch(COMException){return;}for(int i=1;i<=count;i++){object child=null;try{child=n.get_accChild(i);}catch(COMException){}if(child is Accessibility.IAccessible)Read((Accessibility.IAccessible)child,text,depth+1);else Fields(n,i,text);}}
 public static int ChildCount(IntPtr window){int count=0;EnumChildWindows(window,(child,state)=>{count++;return true;},IntPtr.Zero);return count;}
 public static string[] Labels(IntPtr window){var text=new List<string>();object outer;var outerIid=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");AccessibleObjectFromWindow(window,4294967292,ref outerIid,out outer);EnumChildWindows(window,(child,state)=>{object a;var iid=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");if(AccessibleObjectFromWindow(child,4294967292,ref iid,out a)==0&&a is Accessibility.IAccessible)Read((Accessibility.IAccessible)a,text,0);return true;},IntPtr.Zero);return text.ToArray();}
}
'@
$deadline=(Get-Date).AddSeconds(45)
do {
 Start-Sleep -Milliseconds 500
 $labels=[FullClientAccessibility]::Labels($gui.MainWindowHandle)
 $versionPresent=[bool]($labels -match '1\.5\.0-g3\.30')
 $addressbookPresent=[bool]($labels -match 'g3-Adressbuch')
 $loginPresent=[bool]($labels -match 'Mit g3 anmelden')
}while((!$versionPresent -or !$addressbookPresent -or !$loginPresent) -and (Get-Date) -lt $deadline)
if(!$versionPresent -or !$addressbookPresent -or !$loginPresent){
 @{versionPresent=$versionPresent;addressbookPresent=$addressbookPresent;loginPresent=$loginPresent;labelCount=$labels.Count;embeddedWindows=[FullClientAccessibility]::ChildCount($gui.MainWindowHandle);mainTitleMatches=($gui.MainWindowTitle -eq 'g3Fernwartung')}|ConvertTo-Json|Set-Content (Join-Path $package 'ui-diagnostic.json') -Encoding utf8
 throw ('Installed UI flags: version='+$versionPresent+'; addressbook='+$addressbookPresent+'; login='+$loginPresent+'; labels='+$labels.Count+'; children='+[FullClientAccessibility]::ChildCount($gui.MainWindowHandle))
}
$sessionExe=Join-Path $root 'g3-gate-regression.exe';Copy-Item (Join-Path $PSScriptRoot '../work/session-gate-test/session.exe') $sessionExe
$psi=[Diagnostics.ProcessStartInfo]::new($sessionExe,'session');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true
$session=[Diagnostics.Process]::Start($psi)
try {
 if($session.StandardOutput.ReadLine() -ne 'READY'){throw 'Session lease unavailable'}
 $servicePID=(Get-CimInstance Win32_Service -Filter "Name='g3Fernwartung'").ProcessId
 if((Worker) -ne 1618){throw 'Active session not deferred'}
 if($session.HasExited -or (Get-CimInstance Win32_Service -Filter "Name='g3Fernwartung'").ProcessId -ne $servicePID){throw 'Busy update interrupted service/session'}
 $gui.Refresh();if($gui.HasExited){throw 'Busy update closed UI'}
}finally{if(!$session.HasExited){$session.StandardInput.WriteLine('');if(!$session.WaitForExit(10000)){throw 'Fixture lease not released'}};$session.Dispose()}
Set-Content (Join-Path $root 'SOURCE.txt') 'disposable repair fixture' -Encoding utf8
if((Worker) -notin @(0,3010)){throw 'Repair failed'}
Ready;if((Identity) -ne $id){throw 'Repair changed identity'}
$gui.Refresh();if(!$gui.HasExited){throw 'Idle native GUI did not voluntarily exit during repair'}
RemoveNew
if((Worker $baselineSetup $baselineMsi) -notin @(0,3010)){throw 'Accepted g3.29 baseline failed'}
$oldID=Identity
if((Worker) -notin @(0,3010)){throw 'g3.29 to g3.30 upgrade failed'}
Ready;if((Identity) -ne $oldID){throw 'Upgrade changed identity'}
RemoveNew
if(Get-Service g3Fernwartung -ErrorAction SilentlyContinue){throw 'Uninstall retained service'}
if((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -ne $boot){throw 'Operating system rebooted'}
@{version='1.5.0-g3.30';clean_install=$true;installed_addressbook_and_login_displayed=$true;installed_version_displayed=$true;active_session_deferred_1618=$true;service_pid_unchanged_while_busy=$true;idle_gui_exit_voluntary=$true;repair_identity_preserved=$true;upgrade_from_g329_identity_preserved=$true;uninstall=$true;no_os_reboot=$true;host_not_installed=$true;source_commit=$proof.source_commit;validator_commit=$env:GITHUB_SHA;scope='disposable GitHub-hosted Windows runner';real_user_login_and_connection='not claimed by fixture'}|ConvertTo-Json|Set-Content (Join-Path $package 'acceptance.json') -Encoding utf8
