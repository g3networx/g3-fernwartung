$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable runner required'}
$pins=Get-Content outputs/g3501-package-hashes.json -Raw|ConvertFrom-Json
$full=Join-Path (Get-Location) 'outputs/g3-OpsLinX-1.5.0-g3.50.1-install.msi'
if((Get-FileHash $full).Hash.ToLowerInvariant() -ne '0c12b4a65a4b02499629cb26818b7802bd436a23549dcb1b53ece4aad57deadb'){throw 'Immutable Full MSI differs'}
$extract=Join-Path $env:RUNNER_TEMP 'g3501-read-payload'
$process=Start-Process msiexec.exe -ArgumentList @('/a',('"'+$full+'"'),'/qn',('TARGETDIR="'+$extract+'"')) -Wait -PassThru
if($process.ExitCode -ne 0){throw 'Administrative payload extraction failed'}
$frontends=@(Get-ChildItem $extract -Recurse -File -Filter g3Fernwartung.exe)
if($frontends.Count -ne 1 -or (Get-FileHash $frontends[0].FullName).Hash.ToLowerInvariant() -ne 'd2b9e425e078f9384f5d8bfd1ef564e8b22bc64d318e70fb0e9f4d84537235f5'){throw 'Pinned frontend required'}
$payload=Join-Path (Get-Location) 'flutter/build/windows/x64/runner/Release'
New-Item -ItemType Directory -Path $payload -Force|Out-Null
Copy-Item (Join-Path $frontends[0].DirectoryName '*') $payload -Recurse
Rename-Item -LiteralPath (Join-Path $payload 'g3Fernwartung.exe') -NewName rustdesk.exe
foreach($kind in @('windows','host')){New-Item -ItemType Directory -Path "g3-build/msi/$kind" -Force|Out-Null}
python g3-build/build-setup-launchers.py --version 1.5.0-g3.50.1
if($LASTEXITCODE -ne 0){throw 'Bootstrap-only compilation failed'}
$items=@{}
foreach($kind in @('windows','host')){
 $name=if($kind -eq 'windows'){'g3-OpsLinX-1.5.0-g3.50.1-install'}else{'g3-OpsLinX-Host-1.5.0-g3.50.1-host-install'}
 $msi=Join-Path outputs ($name+'.msi')
 if((Get-FileHash $msi).Hash.ToLowerInvariant() -ne $pins.($name+'.msi').sha256){throw 'MSI changed during bootstrap build'}
 $file=$name+'-r1.exe';Copy-Item -LiteralPath (Join-Path outputs ($name+'.exe')) -Destination (Join-Path outputs $file)
 $items[$kind]=@{file=$file;sha256=(Get-FileHash (Join-Path outputs $file)).Hash.ToLowerInvariant();size=(Get-Item (Join-Path outputs $file)).Length}
}
@{installerRevision='r1';version='1.5.0-g3.50.1';runtimeSource='9af8ef58a9b6087c6b6c9e46670459ecd95613af';bootstrapSource=$env:GITHUB_SHA;nativeAndFrontendRebuilt=$false;msiUnchanged=$true;items=$items}|ConvertTo-Json -Depth 8|Set-Content outputs/bootstrap-r1-hashes.json
python g3-build/test-process-inspection.py
if($LASTEXITCODE -ne 0){throw 'Process inspection regression failed'}
python g3-build/test-setup-progress.py
if($LASTEXITCODE -ne 0){throw 'Progress regression failed'}
