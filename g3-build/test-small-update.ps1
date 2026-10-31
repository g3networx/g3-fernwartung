$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable runner required'}
$old=Join-Path $env:RUNNER_TEMP 'g3401-prior-package';Expand-Archive $env:G3_PRIOR_POWERSHELL_ARCHIVE $old
$expected='395e771abde1ad62ec74f64c4c6cfe806e8a359b1e822fd7b428d28cd1941080'
if((Get-FileHash $env:G3_PRIOR_POWERSHELL_ARCHIVE).Hash.ToLowerInvariant() -ne $expected){throw 'Prior candidate artifact pin mismatch'}
function Worker($directory){
 $setup=Join-Path $directory 'g3-OpsLinX-1.5.0-g3.40.1-install.exe';$msi=Join-Path $directory 'g3-OpsLinX-1.5.0-g3.40.1-install.msi'
 $process=Start-Process $setup -ArgumentList @('--g3-install-worker',('"'+$msi+'"')) -WindowStyle Hidden -Wait -PassThru
 if($process.ExitCode -ne 0){throw ('Pinned worker failed: '+$process.ExitCode)}
}
Worker $old
$exe=Join-Path $env:ProgramFiles 'g3Fernwartung/g3Fernwartung.exe'
if((Get-FileHash $exe).Hash.ToLowerInvariant() -ne '6022d83e9ea9dcaf12606dc1015072d8c75077b4baab2f3a1a155c38b9629447'){throw 'Prior frontend baseline differs'}
$id=(& $exe --get-id|Out-String).Trim();if($id -notmatch '^\d{6,12}$'){throw 'Actual baseline ID missing'}
$profile='C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\g3Fernwartung\config\g3Fernwartung.toml'
$hash=(Get-FileHash $profile).Hash
Worker (Join-Path $PSScriptRoot '../outputs')
$expectedLine=@(Get-Content (Join-Path $PSScriptRoot 'msi/windows/expected-payload.tsv')|Where-Object {$_.StartsWith("g3Fernwartung.exe`t")});if($expectedLine.Count -ne 1){throw 'Expected frontend pin missing'}
$expectedFrontend=($expectedLine[0] -split "`t")[1]
if((Get-FileHash $exe).Hash.ToLowerInvariant() -ne $expectedFrontend -or (& $exe --get-id|Out-String).Trim() -ne $id -or (Get-FileHash $profile).Hash -ne $hash){throw 'Same-version update payload or preservation failed'}
@{differentPackageSameVersionUpdated=$true;frontendHashVerified=$true;nativeIdPreserved=$true;mainIdentityCredentialsPreserved=$true}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot '../outputs/small-update-acceptance.json')
