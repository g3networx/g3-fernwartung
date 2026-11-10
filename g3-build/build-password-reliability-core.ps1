$ErrorActionPreference='Stop'
function Check {if($LASTEXITCODE -ne 0){throw "UPN core build failed: $LASTEXITCODE"}}
$source=(Get-Location).Path
$tools=Join-Path $env:RUNNER_TEMP 'g3-tools'
$buildSource=Get-Content g3-build/build.ps1 -Raw
$boundary=$buildSource.IndexOf("Stage 'Compile native core and Flutter client'")
if($boundary -lt 0){throw 'Native setup boundary changed'}
$setup=$buildSource.Substring(0,$boundary).Replace('$source=(Resolve-Path "$PSScriptRoot/..").Path','$source=(Get-Location).Path').Replace('$PSScriptRoot','$source/g3-build')
# The reused setup validates the historical flat version but does no packaging.
$env:G3_BUILD_VERSION='1.5.0-g3.40'
& ([scriptblock]::Create($setup))
$env:G3_BUILD_VERSION='1.5.0-g3.60.19994'
New-Item -ItemType Directory -Force outputs|Out-Null
$module=(Join-Path $source 'src/platform/windows_logon.rs').Replace('\','/')
('#[path = "'+$module+'"] mod windows_logon;')|Set-Content outputs/windows-logon-tests.rs
rustc --edition 2021 --test outputs/windows-logon-tests.rs -o outputs/windows-logon-tests.exe
Check
& ./outputs/windows-logon-tests.exe|Tee-Object outputs/windows-logon-tests.txt
Check
cargo build --locked --features hwcodec,vram,flutter --lib --release
Check
cargo test --locked --release --lib --features hwcodec,vram,flutter g3_api_policy::tests;Check
cargo test --locked --release --lib --features hwcodec,vram,flutter g3_passwords::tests;Check
cargo test --locked --release --lib --features hwcodec,vram,flutter g3_bootstrap::tests;Check
cargo test --locked --release --lib --features hwcodec,vram,flutter g3_registry_password::tests;Check
cargo test --locked --release --lib --features hwcodec,vram,flutter g3_otp_handoff::tests;Check
cargo test --locked --release --lib --features hwcodec,vram,flutter g3_password_probe_persistence_tests;Check
cargo build --locked --release --package dylib_virtual_display
Check
$hash=(Get-FileHash target/release/librustdesk.dll).Hash.ToLowerInvariant()
if($hash -eq 'ce2b6fef64620cb3ee2918d7245259edd758059dadf8f6437a2d47b72426fbec'){throw 'Native fix was not rebuilt'}
@{source_commit=$env:GITHUB_SHA;native_sha256=$hash;native_rebuilt=$true;windows_logon_parser_tests_passed=3;run_id=$env:GITHUB_RUN_ID}|ConvertTo-Json|Set-Content outputs/upn-core-provenance.json
# Preserve completed native outputs even if a later UI/package step fails.
Compress-Archive target/release/librustdesk.dll,target/release/deps/dylib_virtual_display.dll,outputs/upn-core-provenance.json outputs/upn-native-candidate.zip
"$tools/flutter/bin"|Out-File $env:GITHUB_PATH -Append -Encoding utf8
