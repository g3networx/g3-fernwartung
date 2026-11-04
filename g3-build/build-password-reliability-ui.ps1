$ErrorActionPreference='Stop'
function Check {if($LASTEXITCODE -ne 0){throw "Build step failed: $LASTEXITCODE"}}
$source=(Get-Location).Path
$tools=Join-Path $env:RUNNER_TEMP 'g3401-tools'
$vs=& "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
Import-Module "$vs/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
Set-Location $source
Push-Location flutter
flutter test test/g3_password_parameters_test.dart test/g3_version_display_test.dart test/g3_update_paths_test.dart test/g3_update_metadata_test.dart test/g3_update_start_test.dart test/g3_handoff_uri_test.dart test/g3_addressbook_test.dart test/g3_powershell_login_test.dart test/g3_commander_test.dart test/g3_commander_backend_test.dart test/file_model_test.dart;Check
flutter build windows --release --dart-define=G3_CLIENT_VERSION=1.5.0-g3.60.19994 '--dart-define=G3_CLIENT_DISPLAY_VERSION=g3.6 Build 041126';Check
Pop-Location
# Keep the native virtual-display companion used by the existing Windows build.
Copy-Item target/release/deps/dylib_virtual_display.dll flutter/build/windows/x64/runner/Release/dylib_virtual_display.dll
