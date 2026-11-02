param([string]$OldRoot,[string]$CandidateRoot)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable runner required'}
function Worker($directory,$version){
 $setup=Join-Path $directory "g3-OpsLinX-$version-install.exe";$msi=Join-Path $directory "g3-OpsLinX-$version-install.msi"
 $p=Start-Process $setup -ArgumentList @('--g3-install-worker',('"'+$msi+'"')) -WindowStyle Hidden -Wait -PassThru
 if($p.ExitCode -ne 0){throw ('Pinned worker failed: '+$p.ExitCode)}
}
$proof=@{disposableRunnerOnly=$true;finished=$false;candidateSource='9af8ef58a9b6087c6b6c9e46670459ecd95613af';version='1.5.0-g3.50.1'}
try {
 Worker $OldRoot '1.5.0-g3.40.1'
 $exe=Join-Path $env:ProgramFiles 'g3Fernwartung/g3Fernwartung.exe'
 if((Get-FileHash $exe).Hash.ToLowerInvariant() -ne 'd0d5aec9d67550b16a662b3fbebbbb492088d5d0f38894d638e12b7d73e83279'){throw 'Prior frontend baseline differs'}
 $beforeId=(& $exe --get-id|Out-String).Trim();if($beforeId -notmatch '^\d{6,12}$'){throw 'Actual baseline ID missing'}
 $profile='C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\g3Fernwartung\config\g3Fernwartung.toml'
 $beforeText=[IO.File]::ReadAllText($profile)
 Worker $CandidateRoot '1.5.0-g3.50.1'
 $afterId=(& $exe --get-id|Out-String).Trim();$afterText=[IO.File]::ReadAllText($profile)
 $comparison=(@{before=$beforeText;after=$afterText}|ConvertTo-Json -Compress|& $env:G3_PROFILE_PYTHON "$PSScriptRoot/compare-ha-main-profile.py")|ConvertFrom-Json
 if($LASTEXITCODE -ne 0){throw 'Profile parser failed'}
 $proof.profileComparison=$comparison
 $proof.frontendHashVerified=((Get-FileHash $exe).Hash.ToLowerInvariant() -eq 'd2b9e425e078f9384f5d8bfd1ef564e8b22bc64d318e70fb0e9f4d84537235f5')
 $proof.nativeIdPreserved=($afterId -eq $beforeId)
 $proof.mainIdentityCredentialsPreserved=($comparison.protectedFieldsPreserved -and $comparison.validBeforeKeyPair -and $comparison.validAfterKeyPair)
 $proof.knownNetworkMetadataOnly=($comparison.rawMainFileUnchanged -or $comparison.onlyKnownHaServerConfirmationAdded)
 $proof.previousPublishedVersionUpdated=$true
 $proof.passed=($proof.frontendHashVerified -and $proof.nativeIdPreserved -and $proof.mainIdentityCredentialsPreserved -and $proof.knownNetworkMetadataOnly)
 if(!$proof.passed){throw 'Detailed upgrade preservation checks failed'}
}finally{
 $beforeText=$null;$afterText=$null;$proof.finished=$true
 $proof|ConvertTo-Json -Depth 12|Set-Content outputs/ha-upgrade-diagnostic.json
}
