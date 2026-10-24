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
 if(!(Test-Path (Join-Path ([Environment]::GetFolderPath('CommonStartup')) 'g3 OpsLinX Host Status.lnk'))){throw 'Host tray startup shortcut missing'}
 foreach($item in $proof.payload.PSObject.Properties){$f=Join-Path $root $item.Name;if(!(Test-Path $f)){throw 'Payload missing'};if($item.Name -ne 'g3-update-session.lock' -and (Get-FileHash $f).Hash.ToLowerInvariant() -ne $item.Value){throw 'Payload changed'}}
 if(Test-Path (Join-Path $root 'flutter_windows.dll')){throw 'Unexpected Flutter dependency'}
}
$code=Worker;if($code -notin @(0,3010)){throw "Clean install failed: $code"};Ready
$version=(& $exe --version | Out-String).Trim();if($version -ne $coreVersion){throw "Native CLI version failed: expected Cargo package $coreVersion, got $version"}
$id=(& $exe --get-id | Out-String).Trim();if($id -notmatch '^\d{6,12}$'){throw 'Native service identity unavailable'}
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
if((& $exe --get-id | Out-String).Trim() -ne $id){throw 'Identity changed across repair'}
$remove=Start-Process msiexec.exe -ArgumentList ('/x "'+$msi+'" /qn REBOOT=ReallySuppress /norestart') -WindowStyle Hidden -Wait -PassThru
if($remove.ExitCode -notin @(0,3010)){throw 'Disposable removal failed'}
if(Get-Service g3Host -ErrorAction SilentlyContinue){throw 'Service not removed'}
if((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -ne $boot){throw 'Runner rebooted'}
@{version=$proof.version;native_core_version=$version;clean_install=$true;native_cli=$true;active_lease_deferred=$true;service_pid_unchanged_while_busy=$true;idle_repair=$true;identity_preserved=$true;uninstall=$true;no_reboot=$true;actual_server_core_runtime='requires separate target preflight';scope='disposable GitHub-hosted Windows runner'} | ConvertTo-Json | Set-Content (Join-Path $PackageDirectory 'core-installation-acceptance.json') -Encoding utf8
