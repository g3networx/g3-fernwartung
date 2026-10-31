$ErrorActionPreference='Stop'
function Check {if($LASTEXITCODE -ne 0){throw "Build step failed: $LASTEXITCODE"}}
$source=(Get-Location).Path
$tools=Join-Path $env:RUNNER_TEMP 'g334-tools'
$vs=& "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
Import-Module "$vs/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
Set-Location $source
git clone --depth 1 --branch 3.24.5 https://github.com/flutter/flutter.git "$tools/flutter";Check
if((git -C "$tools/flutter" rev-parse HEAD) -ne 'dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668'){throw 'Flutter source pin mismatch'}
git -C "$tools/flutter" apply "$source/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff";Check
$env:Path="$tools/flutter/bin;"+$env:Path
flutter config --no-analytics;Check
flutter precache --windows;Check
$engine=Get-Content engine-provenance.json -Raw|ConvertFrom-Json
Invoke-WebRequest $engine.browser_download_url -OutFile "$tools/engine.zip"
if((Get-FileHash "$tools/engine.zip").Hash.ToLowerInvariant() -ne $engine.sha256){throw 'Engine pin mismatch'}
Expand-Archive "$tools/engine.zip" "$tools/engine"
Copy-Item "$tools/engine/*" "$tools/flutter/bin/cache/artifacts/engine/windows-x64-release" -Recurse -Force
Push-Location flutter
flutter test test/g3_update_paths_test.dart test/g3_update_metadata_test.dart test/g3_update_start_test.dart test/g3_handoff_uri_test.dart;Check
flutter build windows --release --dart-define=G3_CLIENT_VERSION=1.5.0-g3.34;Check
Pop-Location
