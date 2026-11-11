param([Parameter(Mandatory)][string]$BuildOutput)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo
$release = Get-Content g3-build/local-addressbook-release.json -Raw | ConvertFrom-Json
$version = $release.version
$thumbprint = '2B29AA03DE164FFF1081D924A2BF4F73BBE63453'
$signer = Get-Item "Cert:\CurrentUser\My\$thumbprint"
if (!$signer.HasPrivateKey) { throw 'OpsLinX signing key is unavailable.' }

$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
if (!$sdk) { throw 'Windows SDK SignTool missing.' }

function Sign-File([string]$Path) {
    & $sdk.FullName sign /sha1 $thumbprint /s My /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $Path
    if ($LASTEXITCODE) { throw "Signing failed for $Path" }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $thumbprint -or !$signature.TimeStamperCertificate) {
        throw "Signature verification failed for $Path with status $($signature.Status)"
    }
}

$provenance = Get-Content (Join-Path $BuildOutput 'g361-release-provenance.json') -Raw | ConvertFrom-Json
if ($provenance.version -ne $version -or $provenance.source_commit -ne $env:GITHUB_SHA) {
    throw 'Unexpected build provenance.'
}
$runtime = 'flutter/build/windows/x64/runner/Release'
Expand-Archive -LiteralPath (Join-Path $BuildOutput 'g361-runtime-payload.zip') -DestinationPath $runtime
if ((Get-FileHash (Join-Path $runtime 'librustdesk.dll')).Hash -ne $provenance.native_sha256) {
    throw 'Runtime does not match the approved build.'
}

New-Item -ItemType Directory -Path outputs -Force | Out-Null
$names = @("g3-OpsLinX-$version-install", "g3-OpsLinX-Host-$version-host-install")
Copy-Item -LiteralPath (Join-Path $BuildOutput 'g3Host.exe') -Destination outputs
$hashes = Get-Content (Join-Path $BuildOutput 'g36-package-hashes.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path g3-build/msi/windows,g3-build/msi/host -Force | Out-Null
foreach ($name in $names) {
    $msi = Join-Path $BuildOutput "$name.msi"
    if ((Get-FileHash -LiteralPath $msi).Hash -ne $hashes."$name.msi".sha256) { throw "MSI hash mismatch: $name" }
    Copy-Item -LiteralPath $msi -Destination outputs
    Sign-File "outputs/$name.msi"
}
python g3-build/build-setup-launchers.py --version $version
if ($LASTEXITCODE) { throw 'Web installer build failed.' }
foreach ($name in $names) { Sign-File "outputs/$name.exe" }

$portable = Join-Path $env:RUNNER_TEMP 'opslinx-soforthilfe'
python g3-build/package-adhoc.py --payload $runtime --stage $portable
if ($LASTEXITCODE) { throw 'Soforthilfe staging failed.' }
$adhocExe = Join-Path $portable 'payload/g3soforthilfe.exe'
Sign-File $adhocExe
Sign-File (Join-Path $portable 'payload/librustdesk.dll')
$packer = Join-Path $portable 'libs/portable'
python (Join-Path $packer 'generate.py') -f (Join-Path $portable 'payload') -o $packer -e $adhocExe -l 5
if ($LASTEXITCODE) { throw 'Soforthilfe build failed.' }
cargo test --manifest-path (Join-Path $packer 'Cargo.toml') --locked --release
if ($LASTEXITCODE) { throw 'Soforthilfe tests failed.' }
$adhoc = "outputs/g3-Soforthilfe-$version-adhoc.exe"
Copy-Item -LiteralPath (Join-Path $packer 'target/release/rustdesk-portable-packer.exe') -Destination $adhoc
Sign-File $adhoc

$packages = @($adhoc)
foreach ($name in $names) { $packages += @("outputs/$name.msi", "outputs/$name.exe") }
foreach ($path in $packages) {
    $file = Get-Item -LiteralPath $path
    $digest = (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    $identity = [Text.Encoding]::ASCII.GetBytes("opslinx-release-v1`n$($file.Name)`n$digest`n")
    $content = [Security.Cryptography.Pkcs.ContentInfo]::new($identity)
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new($content, $true)
    $packageSigner = [Security.Cryptography.Pkcs.CmsSigner]::new($signer)
    $packageSigner.IncludeOption = 'EndCertOnly'
    $packageSigner.DigestAlgorithm = [Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.2.1')
    $cms.ComputeSignature($packageSigner, $true)
    $proof = $cms.Encode()
    if ($proof.Length -gt 4096) { throw "OpsLinX signature is too large for $path" }
    [IO.File]::WriteAllBytes($file.FullName + '.p7s', $proof)
}
$packages | ForEach-Object {
    $file = Get-Item -LiteralPath $_
    [ordered]@{
        file = $file.Name
        size = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        signer = $thumbprint
        timestamped = $true
    }
} | ConvertTo-Json | Set-Content -LiteralPath outputs/opslinx-signatures.json -Encoding utf8
