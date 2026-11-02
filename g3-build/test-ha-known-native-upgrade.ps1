param([ValidateSet('g332-full','g3402-host')][string]$Scenario)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable runner required'}
$hostCase=$Scenario -eq 'g3402-host';$app=if($hostCase){'g3Host'}else{'g3Fernwartung'}
$version=if($hostCase){'1.5.0-g3.40.2'}else{'1.5.0-g3.32'}
$setupKind=if($hostCase){'host'}else{'windows'};$msiKind=$setupKind+'_msi'
$pins=if($hostCase){@('5f2711dce896bfda897fa0f4584170aa58e0c9cd4091406f46df45d7a22ea8f8','8216eb3aa45d3636184492d32474c32f74080a9c3a6f6bf7b02e3618d6b7c513')}else{@('8bf75a3ec7b043797f2ed737cd461b19536b92c5c9b75b3db9e93b07b4b69643','da084eea6f57afaf5ea8567e58aa6de4b0188c5f108c43e929e3c7e1206b152e')}
$oldSetup=Join-Path $env:RUNNER_TEMP 'old.exe';$oldMsi=Join-Path $env:RUNNER_TEMP 'old.msi'
Invoke-WebRequest "https://rust.g3nx.net/client/releases/$version/$setupKind" -OutFile $oldSetup
Invoke-WebRequest "https://rust.g3nx.net/client/releases/$version/$msiKind" -OutFile $oldMsi
if((Get-FileHash $oldSetup).Hash.ToLowerInvariant() -ne $pins[0] -or (Get-FileHash $oldMsi).Hash.ToLowerInvariant() -ne $pins[1]){throw 'Exact accepted prior version required'}
function Worker($setup,$msi){$p=Start-Process $setup -ArgumentList @('--g3-install-worker',('"'+$msi+'"')) -Wait -PassThru -WindowStyle Hidden;return $p.ExitCode}
if((Worker $oldSetup $oldMsi) -ne 0){throw 'Prior version installation failed'}
$root=Join-Path $env:ProgramFiles $app;$exe=Join-Path $root ($app+'.exe')
$before=(& $exe --get-id|Out-String).Trim();if($before -notmatch '^\d{6,12}$'){throw 'Actual prior native ID required'}
$main="C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\$app\config\$app.toml";$beforeText=[IO.File]::ReadAllText($main)
$newBase=if($hostCase){'g3-OpsLinX-Host-1.5.0-g3.50.1-host-install'}else{'g3-OpsLinX-1.5.0-g3.50.1-install'}
$newSetup=Join-Path (Get-Location) ('outputs/'+$newBase+'.exe');$newMsi=Join-Path (Get-Location) ('outputs/'+$newBase+'.msi')
$fixture=Join-Path $root 'g3-gate-regression.exe';Copy-Item work/session-gate-test/session.exe $fixture
$start=[Diagnostics.ProcessStartInfo]::new($fixture,'session');$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true
$lease=[Diagnostics.Process]::Start($start)
try{
 if($lease.StandardOutput.ReadLine() -ne 'READY'){throw 'Native session fixture did not acquire shared lease'}
 $pidBefore=(Get-Service $app).Status
 if((Worker $newSetup $newMsi) -ne 1618){throw 'Active native session was not safely deferred'}
 if((Get-Service $app).Status -ne $pidBefore){throw 'Service changed while session lease held'}
}finally{$lease.StandardInput.WriteLine('');if(!$lease.WaitForExit(10000)){throw 'Owned lease fixture did not close normally'};$lease.Dispose()}
if((Worker $newSetup $newMsi) -ne 0){throw 'Normal known-native upgrade failed after fixture released'}
$after=(& $exe --get-id|Out-String).Trim();$afterText=[IO.File]::ReadAllText($main)
$compare=(@{before=$beforeText;after=$afterText}|ConvertTo-Json -Compress|& $env:G3_PROFILE_PYTHON g3-build/compare-ha-main-profile.py)|ConvertFrom-Json
if(!$compare.protectedFieldsPreserved -or !$compare.validBeforeKeyPair -or !$compare.validAfterKeyPair -or $after -ne $before){throw 'Identity, keys or credentials changed'}
$native=(Get-FileHash (Join-Path $root 'librustdesk.dll')).Hash.ToLowerInvariant()
if($native -ne '5bea3b33ff33a7eeb0b475bd9cf81e45afca58375311ab3d0ac5ae4429aac1d4' -or (Get-Service $app).Status -ne 'Running'){throw 'Accepted runtime not running'}
@{scenario=$Scenario;activeSessionSafelyDeferred=$true;normalUpgradeWithoutForce=$true;actualNativeIdPreserved=$true;protectedCredentialsPreserved=$true;nativeHashVerified=$true;rawMainProfileUnchanged=$compare.rawMainFileUnchanged}|ConvertTo-Json|Set-Content "outputs/known-native-$Scenario-acceptance.json"
$beforeText=$null;$afterText=$null
