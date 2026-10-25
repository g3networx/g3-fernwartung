$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable GitHub-hosted Windows runner required'}
$repo=(Resolve-Path "$PSScriptRoot/..").Path
$version=$env:G3_BUILD_VERSION
if($version -notmatch '^1\.5\.0-g3\.\d{1,3}$'){throw 'Missing exact candidate version'}
$output=Join-Path $repo outputs
$scenario=$env:G3_PAIR_SCENARIO
if($scenario -notin @('fresh','existing-host')){throw 'Exact disposable pairing scenario required'}
$fullRoot=Join-Path $env:ProgramFiles 'g3Fernwartung';$fullExe=Join-Path $fullRoot 'g3Fernwartung.exe'
$hostRoot=Join-Path $env:ProgramFiles 'g3Host';$hostExe=Join-Path $hostRoot 'g3Host.exe'
$fullSetup=Join-Path $output "g3-OpsLinX-$version-install.exe";$fullMsi=Join-Path $output "g3-OpsLinX-$version-install.msi"
$hostSetup=Join-Path $output "g3-OpsLinX-Host-$version-host-install.exe";$hostMsi=Join-Path $output "g3-OpsLinX-Host-$version-host-install.msi"
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
function Worker($setup,$msi){$p=Start-Process $setup -ArgumentList @('--g3-install-worker',('"'+$msi+'"')) -WindowStyle Hidden -Wait -PassThru;return $p.ExitCode}
function Identity($exe){$id=(& $exe --get-id|Out-String).Trim();if($id -notmatch '^\d{6,12}$'){throw 'Native installed identity unavailable'};return $id}
function Fingerprint($app){
 $config=Join-Path "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\$app" config
 $lines=@(Get-ChildItem $config -File -Filter '*.toml'|ForEach-Object {[regex]::Matches([IO.File]::ReadAllText($_.FullName),'(?m)^\s*(?:enc_id|id|password|salt|key_pair)\s*=.*$')|ForEach-Object Value}|Sort-Object)
 if(!$lines.Count){throw 'Credential/identity preservation baseline missing'}
 $sha=[Security.Cryptography.SHA256]::Create();try{[Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines -join "`n")))}finally{$sha.Dispose()}
}
function Session($root,$sibling){
 $fixture=Join-Path $root 'g3-gate-regression.exe';Copy-Item (Join-Path $repo 'work/session-gate-test/session.exe') $fixture -Force
 $start=[Diagnostics.ProcessStartInfo]::new($fixture,'session');$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true
 if($sibling){$start.EnvironmentVariables['G3_GATE_TEST_SIBLING']=Join-Path $sibling 'g3-update-session.lock'}else{$start.EnvironmentVariables.Remove('G3_GATE_TEST_SIBLING')}
 $p=[Diagnostics.Process]::Start($start);if($p.StandardOutput.ReadLine() -ne 'READY'){throw 'Production session lease unavailable'};return $p
}
function Release($p){$p.StandardInput.WriteLine('');if(!$p.WaitForExit(10000)){throw 'Fixture did not release its native lease'};$p.Dispose()}
function Running($app){$s=Get-CimInstance Win32_Service -Filter "Name='$app'";if($s.State -ne 'Running' -or $s.StartMode -ne 'Auto'){throw "$app service not running automatically"};return $s.ProcessId}
if(Get-Service g3Host -ErrorAction SilentlyContinue){throw 'Expected FullClient-only starting state'}
if(!(Get-Service g3Fernwartung -ErrorAction SilentlyContinue)){if((Worker $fullSetup $fullMsi) -notin @(0,3010)){throw 'Initial FullClient install failed'}}
$fullInitial=Identity $fullExe;$fullProfile=Fingerprint g3Fernwartung
$existingHostId=$null
if($scenario -eq 'existing-host'){
 $legacySetup=Join-Path $env:RUNNER_TEMP 'g3-host-g329.exe';$legacyMsi=Join-Path $env:RUNNER_TEMP 'g3-host-g329.msi'
 Invoke-WebRequest 'https://rust.g3nx.net/client/releases/1.5.0-g3.29/host' -OutFile $legacySetup
 Invoke-WebRequest 'https://rust.g3nx.net/client/releases/1.5.0-g3.29/host_msi' -OutFile $legacyMsi
 if((Get-FileHash $legacySetup).Hash.ToLowerInvariant() -ne '95fc603c83db28338b9d58223a87a025315409b2766b360c435ebac432ba8643' -or (Get-FileHash $legacyMsi).Hash.ToLowerInvariant() -ne '9b908b218401ba4af8f7a831b107fdccea13587486bd97630a2b72b8b2d83224'){throw 'Immutable legacy Host pin differs'}
 if((Worker $legacySetup $legacyMsi) -notin @(0,3010)){throw 'Legacy Host baseline install failed'}
 $existingHostId=Identity $hostExe
 $legacyHostProfile=Fingerprint g3Host
 $legacySession=Session $hostRoot $null
 try {
  $legacyPid=Running g3Host
  if((Worker $hostSetup $hostMsi) -ne 1618){throw 'Existing legacy Host session did not defer upgrade'}
  if((Running g3Host) -ne $legacyPid -or $legacySession.HasExited){throw 'Deferred upgrade interrupted legacy Host'}
 }finally{Release $legacySession}
}
$session=Session $fullRoot $null
try {
 $fullPid=Running g3Fernwartung
 if($existingHostId){$beforeHostPid=Running g3Host}
 if((Worker $hostSetup $hostMsi) -ne 1618){throw 'Host install did not defer while Full session was active'}
 if((Running g3Fernwartung) -ne $fullPid -or $session.HasExited){throw 'Deferred Host install interrupted Full'}
 if($existingHostId){if((Running g3Host) -ne $beforeHostPid -or (Identity $hostExe) -ne $existingHostId){throw 'Deferred upgrade changed existing Host'}}
 elseif(Get-Service g3Host -ErrorAction SilentlyContinue){throw 'Deferred Host install changed products'}
}finally{Release $session}
if((Worker $hostSetup $hostMsi) -notin @(0,3010)){throw 'Idle co-installation failed'}
$hostId=Identity $hostExe
if($existingHostId){
 if($hostId -ne $existingHostId -or (Fingerprint g3Host) -ne $legacyHostProfile){throw 'Upgrade changed existing canonical Host identity/credentials'}
}elseif($hostId -ne $fullInitial){throw 'New Host did not retain the existing standalone FullClient identity'}
if((Identity $fullExe) -ne $hostId){throw 'Host and FullClient report different public device identities'}
if((Fingerprint g3Fernwartung) -ne $fullProfile){throw 'Pairing changed the original FullClient service profile'}
$hostPid=Running g3Host
Stop-Service g3Fernwartung;Start-Service g3Fernwartung
if((Running g3Host) -ne $hostPid -or (Identity $fullExe) -ne $hostId){throw 'Full service maintenance changed/stopped the canonical Host'}
Add-Type -AssemblyName Accessibility
$fixtureSource=Get-Content (Join-Path $PSScriptRoot 'test-fullclient-addressbook-install.ps1') -Raw
$helper=[regex]::Match($fixtureSource,"(?s)-TypeDefinition @'\r?\n(.*?)\r?\n'@")
if(!$helper.Success){throw 'Existing accessibility fixture missing'}
Add-Type -ReferencedAssemblies @(([Accessibility.IAccessible].Assembly.Location),(Join-Path $PSHOME 'ref/System.Collections.dll')) -CompilerOptions '/nowarn:1701' -TypeDefinition $helper.Groups[1].Value
Start-Process $fullExe|Out-Null
$fullUiHasHostId=$false
for($attempt=0;$attempt -lt 40;$attempt++){
 Start-Sleep -Milliseconds 500
 $pids=[int[]]@(Get-Process g3Fernwartung -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $fullExe}|ForEach-Object Id)
 foreach($window in [FullClientAccessibility]::FlutterWindows($pids)){
  $labels=[FullClientAccessibility]::Labels($window)
  if((($labels -join ' ') -replace '\s','').Contains($hostId)){$fullUiHasHostId=$true;break}
 }
 if($fullUiHasHostId){break}
}
if(!$fullUiHasHostId){throw 'Installed FullClient UI did not show the canonical Host ID'}
$hostProfile=Fingerprint g3Host
$session=Session $hostRoot $fullRoot
try {
 $hostPid=Running g3Host;$fullPid=Running g3Fernwartung
 if((Worker $fullSetup $fullMsi) -ne 1618 -or (Worker $hostSetup $hostMsi) -ne 1618){throw 'Paired session did not defer both product updates'}
 if((Running g3Host) -ne $hostPid -or (Running g3Fernwartung) -ne $fullPid -or $session.HasExited){throw 'Deferred paired update interrupted a service/session'}
}finally{Release $session}
if((Worker $fullSetup $fullMsi) -notin @(0,3010)){throw 'Idle paired FullClient repair failed'}
if((Running g3Host) -ne $hostPid){throw 'Full repair restarted the Host service'}
if((Identity $fullExe) -ne $hostId -or (Fingerprint g3Host) -ne $hostProfile){throw 'Full repair changed the existing Host identity/credentials'}
if((Worker $hostSetup $hostMsi) -notin @(0,3010)){throw 'Idle paired Host repair failed'}
if((Identity $fullExe) -ne $hostId -or (Identity $hostExe) -ne $hostId){throw 'Repair changed the canonical Host identity'}
if((Fingerprint g3Fernwartung) -ne $fullProfile -or (Fingerprint g3Host) -ne $hostProfile){throw 'Repair modified original service identity/credentials'}
if((Get-CimInstance Win32_OperatingSystem).LastBootUpTime -ne $boot){throw 'Operating system rebooted'}
@{scenario=$scenario;canonical_identity_preserved=$true;rule=if($existingHostId){'Existing Host ID retained'}else{'New Host inherits existing FullClient ID'}}|ConvertTo-Json|Set-Content (Join-Path $output 'shared-device-scenario-acceptance.json') -Encoding utf8
@{version=$version;full_session_defers_host_install=$true;existing_full_service_profile_preserved=$true;canonical_host_id_same_in_both_native_clis=$true;full_ui_displays_host_id=$true;full_service_stop_does_not_stop_host=$true;paired_session_defers_both_updates=$true;service_pids_unchanged_while_deferred=$true;full_repair_preserves_host_service_pid=$true;host_id_and_both_credential_profiles_preserved_after_repairs=$true;no_os_reboot=$true;no_force_or_security_changes=$true;scope='Disposable GitHub-hosted Windows runner; native lease fixture, not an interactive customer remote session'}|ConvertTo-Json|Set-Content (Join-Path $output 'shared-device-acceptance.json') -Encoding utf8
