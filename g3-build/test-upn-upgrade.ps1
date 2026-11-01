$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable runner required'}
$old=Join-Path $env:RUNNER_TEMP 'g3401-prior-package';Expand-Archive $env:G3_PRIOR_POWERSHELL_ARCHIVE $old
$expected='d8376ae324be33873816024c4920dcb12a98c38d0abac48f1495cb19b3a7db9d'
if((Get-FileHash $env:G3_PRIOR_POWERSHELL_ARCHIVE).Hash.ToLowerInvariant() -ne $expected){throw 'Prior candidate artifact pin mismatch'}
function Worker($directory,$version){
 $setup=Join-Path $directory "g3-OpsLinX-$version-install.exe";$msi=Join-Path $directory "g3-OpsLinX-$version-install.msi"
 $process=Start-Process $setup -ArgumentList @('--g3-install-worker',('"'+$msi+'"')) -WindowStyle Hidden -Wait -PassThru
 if($process.ExitCode -ne 0){throw ('Pinned worker failed: '+$process.ExitCode)}
}
Worker $old '1.5.0-g3.40.1'
$exe=Join-Path $env:ProgramFiles 'g3Fernwartung/g3Fernwartung.exe'
if((Get-FileHash $exe).Hash.ToLowerInvariant() -ne 'd0d5aec9d67550b16a662b3fbebbbb492088d5d0f38894d638e12b7d73e83279'){throw 'Prior frontend baseline differs'}
$id=(& $exe --get-id|Out-String).Trim();if($id -notmatch '^\d{6,12}$'){throw 'Actual baseline ID missing'}
$profile='C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\g3Fernwartung\config\g3Fernwartung.toml'
$hash=(Get-FileHash $profile).Hash
Worker (Join-Path $PSScriptRoot '../outputs') '1.5.0-g3.40.2'
$expectedLine=@(Get-Content (Join-Path $PSScriptRoot 'msi/windows/expected-payload.tsv')|Where-Object {$_.StartsWith("g3Fernwartung.exe`t")});if($expectedLine.Count -ne 1){throw 'Expected frontend pin missing'}
$expectedFrontend=($expectedLine[0] -split "`t")[1]
if((Get-FileHash $exe).Hash.ToLowerInvariant() -ne $expectedFrontend -or (& $exe --get-id|Out-String).Trim() -ne $id -or (Get-FileHash $profile).Hash -ne $hash){throw 'Published-version upgrade payload or preservation failed'}
@{previousPublishedVersionUpdated=$true;frontendHashVerified=$true;nativeIdPreserved=$true;mainIdentityCredentialsPreserved=$true}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot '../outputs/upn-upgrade-acceptance.json')
