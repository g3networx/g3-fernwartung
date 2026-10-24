$ErrorActionPreference='Stop'
$source=(Resolve-Path "$PSScriptRoot/..").Path
$outputRoot=Join-Path $source 'outputs'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$diagnostics=Join-Path $outputRoot 'build-diagnostics.txt'
$script:BuildStage='Initializing'
Start-Transcript -Path $diagnostics -Force | Out-Null
trap {
 $failure=($_ | Out-String).Trim() -replace '[\r\n]+',' '
 $line="Windows build failed during '$script:BuildStage': $failure (native exit=$LASTEXITCODE)"
 Set-Content -Path (Join-Path $outputRoot 'build-failure.txt') -Value $line -Encoding utf8
 $annotation=$line.Replace('%','%25').Replace("`r",'%0D').Replace("`n",'%0A').Replace(':','%3A').Replace(',','%2C')
 [Console]::Out.WriteLine("::error title=Windows build failure::$annotation")
 try { Stop-Transcript | Out-Null } catch {}
 exit 1
}
function Stage([string]$name) { $script:BuildStage=$name; Write-Output "BUILD STAGE: $name" }
function Check { if ($LASTEXITCODE -ne 0) { throw "Native command failed with exit code $LASTEXITCODE during '$script:BuildStage'" } }
Stage 'Prepare and verify native build inputs'
$tools=Join-Path $env:RUNNER_TEMP 'g3-tools'
New-Item -ItemType Directory -Path $tools -Force | Out-Null
$headers=@{Authorization="Bearer $env:GH_TOKEN";Accept='application/vnd.github+json'}
Invoke-WebRequest 'https://api.github.com/repos/g3networx/g3-fernwartung/actions/artifacts/12477693931/zip' -Headers $headers -OutFile "$tools/base.zip"
if ((Get-FileHash "$tools/base.zip").Hash.ToLowerInvariant() -ne 'e6fc1f920c6ca6d129d798dfc1b6b365ce0e2261f8d6eb1e1e52e29a510e6b57') {throw 'Native acceptance artifact digest mismatch'}
Expand-Archive "$tools/base.zip" "$tools/base"
$env:G3_ACCEPTED_BASE="$tools/base"
# Reuse only when the exact native source tree matches the accepted build.
$changed=git -C $source diff c7ec02f0c471d6f88700544552b1e5b81f411551 HEAD -- src libs Cargo.toml Cargo.lock
Check
if ($changed) {
 Write-Output 'Native source changed: selecting the complete native build and acceptance pipeline.'
 & "$PSScriptRoot/build.ps1"
 return
}
Stage 'Install Flutter dependencies and Windows build tools'
$vs=& "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
Import-Module "$vs/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
Set-Location $source
python -m pip install Brotli==1.2.0; Check
git clone --depth 1 --branch 3.24.5 https://github.com/flutter/flutter.git "$tools/flutter"; Check
if ((git -C "$tools/flutter" rev-parse HEAD) -ne 'dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668') { throw 'Unexpected Flutter source' }
git -C "$tools/flutter" apply "$source/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"; Check
Stage 'Fetch pinned Flutter engine and Rust toolchain'
$env:Path="$tools/flutter/bin;"+$env:Path
flutter config --no-analytics; Check
flutter precache --windows; Check
$engine=Get-Content "$source/engine-provenance.json" -Raw | ConvertFrom-Json
Invoke-WebRequest $engine.browser_download_url -OutFile "$tools/engine.zip"
if ((Get-FileHash "$tools/engine.zip").Hash.ToLowerInvariant() -ne $engine.sha256) { throw 'Engine SHA256 mismatch' }
Expand-Archive "$tools/engine.zip" "$tools/engine"
Copy-Item "$tools/engine/*" "$tools/flutter/bin/cache/artifacts/engine/windows-x64-release" -Recurse -Force
rustup toolchain install 1.75.0 --profile minimal; Check
$env:RUSTUP_TOOLCHAIN='1.75.0'
Expand-Archive "$tools/base/g3-windows-unsigned.zip" "$tools/native"
$native=Get-ChildItem "$tools/native" -Recurse -Filter librustdesk.dll
if (@($native).Count -ne 1) {throw 'Unexpected native payload'}
$nativeHash=(Get-FileHash $native.FullName).Hash.ToLowerInvariant()
New-Item -ItemType Directory -Path target/release -Force | Out-Null
Copy-Item $native.FullName target/release/librustdesk.dll
# Packaging reads this normally Rust-generated metadata file; no Rust build runs here.
Set-Content src/version.rs 'pub const BUILD_DATE: &str = "native reused from accepted run 39893124138";' -Encoding utf8
Stage 'Run focused Flutter tests and compile FullClient'
Push-Location flutter
flutter test test/g3_update_paths_test.dart test/g3_update_metadata_test.dart test/g3_update_start_test.dart test/g3_handoff_uri_test.dart; Check
flutter build windows --release; Check
Pop-Location
Stage 'Prepare native OpsLinX Host and MSI packaging tools'
$payload="$source/flutter/build/windows/x64/runner/Release"
if ((Get-FileHash "$payload/librustdesk.dll").Hash.ToLowerInvariant() -ne $nativeHash) {throw 'Native DLL changed'}
New-Item -ItemType Directory -Path outputs,g3-build/msi -Force | Out-Null
Invoke-WebRequest 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' -OutFile "$tools/wix.zip"
if ((Get-FileHash "$tools/wix.zip").Hash -ne '6AC824E1642D6F7277D0ED7EA09411A508F6116BA6FAE0AA5F2C7DAA2FF43D31') { throw 'WiX SHA256 mismatch' }
Expand-Archive "$tools/wix.zip" "$tools/wix/bin"
$env:WIX="$tools/wix"
$payload="$source/flutter/build/windows/x64/runner/Release"
Copy-Item LICENCE "$payload/LICENCE"
Set-Content "$payload/SOURCE.txt" "https://github.com/g3networx/g3-fernwartung/tree/$env:GITHUB_SHA" -Encoding utf8
$rc="$source/g3-build/windows-core-host.rc"
& rc.exe /nologo "/fo$source/outputs/windows-core-host.res" $rc
Check
& cl.exe /nologo /O2 /MT /EHsc /std:c++17 /DUNICODE /D_UNICODE "$source/g3-build/windows-core-host.cpp" /link "$source/outputs/windows-core-host.res" /SUBSYSTEM:WINDOWS /ENTRY:wmainCRTStartup "/OUT:$source/outputs/g3Host.exe"
Check
Stage 'Package FullClient and native Host installers'
python g3-build/package-msi.py; Check
python g3-build/build-setup-launchers.py; Check
Stage 'Run session/update/download acceptance checks'
python g3-build/test-update-session-gate.py; Check
& "$PSScriptRoot/test-windows-update.ps1"
python g3-build/test-download-bootstrap.py; Check
Compress-Archive "$payload/*" outputs/g3-windows-unsigned.zip
$provenance=@{source_commit=$env:GITHUB_SHA;native_source_commit='c7ec02f0c471d6f88700544552b1e5b81f411551';native_artifact_id=12477693931;native_sha256=$nativeHash;run_id=$env:GITHUB_RUN_ID;rust=(rustc --version);flutter_commit='dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668';vcpkg_commit='9e593bb18ea69cc5095e012465dcd675a822ed0d';engine_sha256=$engine.sha256;publicly_trusted_signature=$false}
$provenance|ConvertTo-Json|Set-Content outputs/build-provenance.json -Encoding utf8
Get-ChildItem outputs -File | Where-Object { $_.Name -notin @('build-diagnostics.txt','build-failure.txt') } | Get-FileHash -Algorithm SHA256 | Select-Object @{n='file';e={Split-Path $_.Path -Leaf}},Hash | ConvertTo-Json | Set-Content outputs/SHA256.json -Encoding utf8
Stage 'Windows package build completed'
Stop-Transcript | Out-Null
