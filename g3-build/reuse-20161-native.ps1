$ErrorActionPreference = 'Stop'
$baseline = 'dc4aeef8b0b6bc21f2671150efb96f12952ac2ee'
$native = 'e5efef83e6618a542d3ea9537f18696aa3b71c22ae64ec5e19f48fa488686b06'
$allowed = @(
    '.github/workflows/g3-local-addressbook-build.yml',
    'flutter/test/g3_local_addressbook_test.dart',
    'g3-build/package-local-addressbook.py',
    'g3-build/reuse-20161-native.ps1',
    'g3-build/verify-local-addressbook-msi.py'
)
$changed = git diff --name-only $baseline HEAD
if ($LASTEXITCODE -or !$changed -or ($changed | Where-Object { $_ -cnotin $allowed })) {
    throw 'The native source has changed since build 20161 was compiled.'
}
$release = Get-Content g3-build/local-addressbook-release.json -Raw | ConvertFrom-Json
if ($release.version -ne '1.5.3-g3.70.20161') { throw 'The native runtime pin is specific to build 20161.' }

$archive = Join-Path $env:RUNNER_TEMP 'native-20161.zip'
$headers = @{Authorization="Bearer $env:GH_TOKEN"; Accept='application/vnd.github+json'}
Invoke-WebRequest 'https://api.github.com/repos/g3networx/g3-fernwartung/actions/artifacts/15001547540/zip' -Headers $headers -OutFile $archive
if ((Get-FileHash -LiteralPath $archive).Hash -ine '22488aef7684c0624844d1fd586c1a4c90946488db45d68e61e5d92cce65cc7e') {
    throw 'The approved native artifact digest changed.'
}
$stage = Join-Path $env:RUNNER_TEMP 'approved-native-20161'
Expand-Archive -LiteralPath $archive -DestinationPath $stage
$payload = @(Get-ChildItem $stage -Filter upn-native-candidate.zip -File -Recurse)
if ($payload.Count -ne 1) { throw 'The approved native artifact has an unexpected layout.' }
$runtime = Join-Path $stage 'runtime'
Expand-Archive -LiteralPath $payload[0].FullName -DestinationPath $runtime
$prior = Get-Content (Join-Path $runtime 'upn-core-provenance.json') -Raw | ConvertFrom-Json
if ($prior.source_commit -ne $baseline -or $prior.native_sha256 -ne $native -or !$prior.native_rebuilt -or $prior.run_id -ne '45562171803') {
    throw 'The approved native artifact provenance differs.'
}
if ((Get-FileHash -LiteralPath (Join-Path $runtime 'librustdesk.dll')).Hash -ine $native -or
    (Get-FileHash -LiteralPath (Join-Path $runtime 'dylib_virtual_display.dll')).Hash -ine 'f9d8b701177e708e64effe79ffe669ff04a04eb15456983ec7f44d98c79d26c9') {
    throw 'A native runtime payload differs from the verified candidate.'
}
New-Item -ItemType Directory -Force target/release/deps,outputs | Out-Null
Copy-Item -LiteralPath (Join-Path $runtime 'librustdesk.dll') -Destination target/release/
Copy-Item -LiteralPath (Join-Path $runtime 'dylib_virtual_display.dll') -Destination target/release/deps/
@{
    source_commit=$env:GITHUB_SHA; native_sha256=$native; native_rebuilt=$false
    native_source_commit=$baseline; native_reuse_run=$prior.run_id
    windows_logon_parser_tests_passed=$prior.windows_logon_parser_tests_passed; run_id=$env:GITHUB_RUN_ID
} | ConvertTo-Json | Set-Content outputs/upn-core-provenance.json

$environment = Get-Content g3-build/build.ps1 -Raw
$boundary = $environment.IndexOf('git clone https://github.com/microsoft/vcpkg.git')
if ($boundary -lt 0) { throw 'Could not locate the native build setup boundary.' }
$setup = $environment.Substring(0,$boundary).Replace('$source=(Resolve-Path "$PSScriptRoot/..").Path','$source=(Get-Location).Path')
$setup = $setup.Replace('$PSScriptRoot','$source/g3-build')
$env:G3_BUILD_VERSION = '1.5.0-g3.40'
& ([scriptblock]::Create($setup))
"$env:RUNNER_TEMP/g3-tools/flutter/bin" | Out-File $env:GITHUB_PATH -Append -Encoding utf8
