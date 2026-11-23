$ErrorActionPreference = 'Stop'
$baseline = 'a21c0d303c861d25a1ce43ee95525f75d609040b'
$native = 'e71c5f259f28d2bdcc4bd38b6cbc4aa32d958a362f079ab440a7cfd2a2b3dc53'
$allowed = @(
    '.github/workflows/g3-host-transition-lab.yml',
    '.github/workflows/g3-local-addressbook-build.yml',
    'g3-build/codesigning/ManagedOpsLinXUpdate.cs',
    'g3-build/local-addressbook-release.json',
    'g3-build/package-local-addressbook.py',
    'g3-build/reuse-20144-native.ps1',
    'g3-build/test-host-20060-to-20144.ps1',
    'g3-build/update-gate-native-hashes.txt',
    'g3-build/verify-local-addressbook-msi.py'
)
$changed = git diff --name-only $baseline HEAD
if ($LASTEXITCODE -or !$changed -or ($changed | Where-Object { $_ -cnotin $allowed })) {
    throw 'The native source or its inputs differ from build 20144.'
}
$release = Get-Content g3-build/local-addressbook-release.json -Raw | ConvertFrom-Json
if ($release.version -ne '1.5.3-g3.70.20145') { throw 'The native reuse approval is specific to 20145.' }

$archive = Join-Path $env:RUNNER_TEMP 'accepted-native-20144.zip'
$headers = @{Authorization="Bearer $env:GH_TOKEN"; Accept='application/vnd.github+json'}
Invoke-WebRequest 'https://api.github.com/repos/g3networx/g3-fernwartung/actions/artifacts/14848825611/zip' -Headers $headers -OutFile $archive
if ((Get-FileHash -LiteralPath $archive).Hash -ine 'dd8de6bc333da2f044b2475d6a9883fe062f570552fc22e0a474772def35cd7c') {
    throw 'The approved 20144 artifact digest changed.'
}
$stage = Join-Path $env:RUNNER_TEMP 'accepted-native-20144'
Expand-Archive -LiteralPath $archive -DestinationPath $stage
$prior = Get-Content (Join-Path $stage 'g361-release-provenance.json') -Raw | ConvertFrom-Json
if ($prior.source_commit -ne $baseline -or $prior.native_sha256 -ne $native -or !$prior.native_rebuilt -or $prior.run_id -ne '45221958577') {
    throw 'The reused native provenance differs from 20144.'
}
$runtime = Join-Path $stage 'runtime'
Expand-Archive -LiteralPath (Join-Path $stage 'g361-runtime-payload.zip') -DestinationPath $runtime
if ((Get-FileHash -LiteralPath (Join-Path $runtime 'librustdesk.dll')).Hash -ine $native) {
    throw 'Reused native runtime hash differs.'
}
$proof = Get-Content (Join-Path $stage 'g361-msi-readonly-verification.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath (Join-Path $runtime 'dylib_virtual_display.dll')).Hash -ine $proof.host.sha256.'dylib_virtual_display.dll') {
    throw 'Reused virtual display runtime hash differs.'
}
New-Item -ItemType Directory -Force target/release/deps | Out-Null
Copy-Item -LiteralPath (Join-Path $runtime 'librustdesk.dll') -Destination target/release/
Copy-Item -LiteralPath (Join-Path $runtime 'dylib_virtual_display.dll') -Destination target/release/deps/
@{
    source_commit=$env:GITHUB_SHA; native_sha256=$native; native_rebuilt=$false
    native_source_commit=$baseline; native_reuse_run='45221958577'
    windows_logon_parser_tests_passed=$prior.windows_logon_parser_tests_passed; run_id=$env:GITHUB_RUN_ID
} | ConvertTo-Json | Set-Content outputs/upn-core-provenance.json

# Configure the same pinned Flutter and Windows engine as the normal build.
$environment = Get-Content g3-build/build.ps1 -Raw
$boundary = $environment.IndexOf('git clone https://github.com/microsoft/vcpkg.git')
if ($boundary -lt 0) { throw 'Could not locate the native-only setup boundary.' }
$setup = $environment.Substring(0,$boundary).Replace('$source=(Resolve-Path "$PSScriptRoot/..").Path','$source=(Get-Location).Path')
$setup = $setup.Replace('$PSScriptRoot','$source/g3-build')
$env:G3_BUILD_VERSION = '1.5.0-g3.40'
& ([scriptblock]::Create($setup))
$tools = Join-Path $env:RUNNER_TEMP 'g3-tools'
"$tools/flutter/bin" | Out-File $env:GITHUB_PATH -Append -Encoding utf8
