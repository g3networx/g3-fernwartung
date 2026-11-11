$ErrorActionPreference='Stop'
function Check {if($LASTEXITCODE -ne 0){throw "Build step failed: $LASTEXITCODE"}}
$release=Get-Content (Join-Path $PSScriptRoot 'local-addressbook-release.json') -Raw|ConvertFrom-Json
Push-Location (Join-Path $PSScriptRoot '../flutter')
try {
 flutter test test/g3_local_addressbook_crypto_test.dart test/g3_local_addressbook_test.dart test/g3_addressbook_test.dart test/g3_password_parameters_test.dart test/g3_version_display_test.dart test/g3_update_metadata_test.dart;Check
 flutter build windows --release "--build-name=$($release.windowsVersion)" --build-number=0 "--dart-define=G3_CLIENT_VERSION=$($release.version)" "--dart-define=G3_CLIENT_DISPLAY_VERSION=$($release.displayVersion)";Check
}finally{Pop-Location}
Copy-Item (Join-Path $PSScriptRoot '../target/release/deps/dylib_virtual_display.dll') (Join-Path $PSScriptRoot '../flutter/build/windows/x64/runner/Release/dylib_virtual_display.dll')

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$signing = Join-Path $PSScriptRoot 'codesigning'
$verifier = Join-Path $root 'flutter/build/windows/x64/runner/Release/verify-opslinx-package.exe'
& 'C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe' /nologo /target:exe /platform:x64 /optimize+ /reference:System.Security.dll "/out:$verifier" "/resource:$signing\g3-root-ca.cer,g3.signing.root" "/resource:$signing\g3-device-ca.cer,g3.signing.issuer" "$signing\OpsLinXPackageSignature.cs" "$signing\VerifyOpsLinXPackage.cs"
Check
