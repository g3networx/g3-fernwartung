$ErrorActionPreference='Stop'
function Check { if ($LASTEXITCODE -ne 0) { throw "Build command failed: $LASTEXITCODE" } }
$source=(Resolve-Path "$PSScriptRoot/..").Path
$tools=Join-Path $env:RUNNER_TEMP 'g3-tools'
New-Item -ItemType Directory -Path $tools -Force | Out-Null
$vs=& "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
Import-Module "$vs/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
Set-Location $source
git -C libs/hbb_common apply --check "$PSScriptRoot/hbb-common.patch"; Check
git -C libs/hbb_common apply "$PSScriptRoot/hbb-common.patch"; Check
rustup toolchain install 1.75.0 --profile minimal; Check
$env:RUSTUP_TOOLCHAIN='1.75.0'
$env:CARGO_BUILD_JOBS='2'
$env:VCPKG_MAX_CONCURRENCY='2'
$env:FLUTTER_SUPPRESS_ANALYTICS='true'
python -m pip install Brotli==1.2.0; Check
git clone --depth 1 --branch 3.24.5 https://github.com/flutter/flutter.git "$tools/flutter"; Check
if ((git -C "$tools/flutter" rev-parse HEAD) -ne 'dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668') { throw 'Unexpected Flutter source' }
git -C "$tools/flutter" apply "$source/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"; Check
$env:Path="$tools/flutter/bin;"+$env:Path
flutter config --no-analytics; Check
flutter precache --windows; Check
$engine=Get-Content "$source/engine-provenance.json" -Raw | ConvertFrom-Json
Invoke-WebRequest $engine.browser_download_url -OutFile "$tools/engine.zip"
if ((Get-FileHash "$tools/engine.zip").Hash.ToLowerInvariant() -ne $engine.sha256) { throw 'Engine SHA256 mismatch' }
Expand-Archive "$tools/engine.zip" "$tools/engine"
Copy-Item "$tools/engine/*" "$tools/flutter/bin/cache/artifacts/engine/windows-x64-release" -Recurse -Force
git clone https://github.com/microsoft/vcpkg.git "$tools/vcpkg"; Check
git -C "$tools/vcpkg" checkout 9e593bb18ea69cc5095e012465dcd675a822ed0d; Check
& "$tools/vcpkg/bootstrap-vcpkg.bat" -disableMetrics; Check
$env:VCPKG_ROOT="$tools/vcpkg"
& "$tools/vcpkg/vcpkg.exe" install --triplet x64-windows-static --host-triplet x64-windows-static "--x-install-root=$tools/vcpkg/installed"; Check
python build.py --portable --flutter --skip-portable-pack --hwcodec --vram; Check
Push-Location flutter
flutter test --no-pub test/g3_legal_notices_test.dart; Check
flutter test --no-pub test/g3_update_paths_test.dart; Check
Pop-Location
cargo test --locked --release --lib --features flutter,hwcodec,vram ipc::g3_identity_tests; Check
cargo test --locked --release --lib --features flutter,hwcodec,vram g3_file_transfer::tests; Check
New-Item -ItemType Directory -Path outputs,g3-build/msi -Force | Out-Null
Invoke-WebRequest 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip' -OutFile "$tools/wix.zip"
if ((Get-FileHash "$tools/wix.zip").Hash -ne '6AC824E1642D6F7277D0ED7EA09411A508F6116BA6FAE0AA5F2C7DAA2FF43D31') { throw 'WiX SHA256 mismatch' }
Expand-Archive "$tools/wix.zip" "$tools/wix/bin"
$env:WIX="$tools/wix"
$payload="$source/flutter/build/windows/x64/runner/Release"
Copy-Item LICENCE "$payload/LICENCE"
Set-Content "$payload/SOURCE.txt" "https://github.com/g3networx/g3-fernwartung/tree/$env:GITHUB_SHA" -Encoding utf8
python g3-build/package-msi.py; Check
python g3-build/build-setup-launchers.py; Check
python g3-build/test-update-session-gate.py; Check
& "$PSScriptRoot/test-windows-update.ps1"
python g3-build/test-download-bootstrap.py; Check
Compress-Archive "$payload/*" outputs/g3-windows-unsigned.zip
$provenance=@{source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;rust=(rustc --version);flutter_commit='dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668';vcpkg_commit='9e593bb18ea69cc5095e012465dcd675a822ed0d';engine_sha256=$engine.sha256;publicly_trusted_signature=$false}
$provenance|ConvertTo-Json|Set-Content outputs/build-provenance.json -Encoding utf8
Get-ChildItem outputs -File | Get-FileHash -Algorithm SHA256 | Select-Object @{n='file';e={Split-Path $_.Path -Leaf}},Hash | ConvertTo-Json | Set-Content outputs/SHA256.json -Encoding utf8
