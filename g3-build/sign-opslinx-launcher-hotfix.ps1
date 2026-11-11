param(
    [Parameter(Mandatory)][string]$BuildOutput,
    [Parameter(Mandatory)][string]$SignedOutput
)

$ErrorActionPreference = 'Stop'
$version = '1.5.0-g3.62.20051'
$source = '47e7e8a1a410f8434f6ccbcff7fbea7c1c88c614'
$thumbprint = '2B29AA03DE164FFF1081D924A2BF4F73BBE63453'
$runtime = 'flutter/build/windows/x64/runner/Release'
$provenance = Get-Content (Join-Path $BuildOutput 'g361-release-provenance.json') -Raw | ConvertFrom-Json
if ($provenance.version -ne $version -or $provenance.source_commit -ne $source) {
    throw 'Unexpected native build provenance.'
}
Expand-Archive -LiteralPath (Join-Path $BuildOutput 'g361-runtime-payload.zip') -DestinationPath $runtime
if ((Get-FileHash (Join-Path $runtime 'librustdesk.dll')).Hash -ne $provenance.native_sha256) {
    throw 'Unexpected native runtime.'
}

$names = @("g3-OpsLinX-$version-install", "g3-OpsLinX-Host-$version-host-install")
$existing = Get-Content (Join-Path $SignedOutput 'opslinx-signatures.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path outputs,g3-build/msi/windows,g3-build/msi/host -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $BuildOutput 'g3Host.exe') -Destination outputs
foreach ($name in $names) {
    $record = @($existing | Where-Object file -EQ "$name.msi")
    $msi = Join-Path $SignedOutput "$name.msi"
    if ($record.Count -ne 1 -or (Get-FileHash -LiteralPath $msi).Hash -ne $record[0].sha256) {
        throw "Signed MSI hash mismatch: $name"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $thumbprint) {
        throw "Signed MSI certificate mismatch: $name"
    }
    Copy-Item -LiteralPath $msi -Destination outputs
}
python g3-build/build-setup-launchers.py --version $version
if ($LASTEXITCODE) { throw 'Could not build the corrected Windows launchers.' }

$sdk = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
if (!$sdk) { throw 'Windows SDK SignTool missing.' }
$signer = Get-Item "Cert:\CurrentUser\My\$thumbprint"
$manifest = foreach ($name in $names) {
    $newName = $name -replace '-install$', '-update-install.exe'
    Rename-Item -LiteralPath "outputs/$name.exe" -NewName $newName
    $file = Get-Item -LiteralPath "outputs/$newName"
    & $sdk.FullName sign /sha1 $thumbprint /s My /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 $file.FullName | Out-Host
    if ($LASTEXITCODE) { throw "Signing failed for $newName" }
    $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $thumbprint -or !$signature.TimeStamperCertificate) {
        throw "Signature verification failed for $newName"
    }
    $digest = (Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()
    $identity = [Text.Encoding]::ASCII.GetBytes("opslinx-release-v1`n$newName`n$digest`n")
    $content = [Security.Cryptography.Pkcs.ContentInfo]::new($identity)
    $cms = [Security.Cryptography.Pkcs.SignedCms]::new($content, $true)
    $packageSigner = [Security.Cryptography.Pkcs.CmsSigner]::new($signer)
    $packageSigner.IncludeOption = 'EndCertOnly'
    $packageSigner.DigestAlgorithm = [Security.Cryptography.Oid]::new('2.16.840.1.101.3.4.2.1')
    $cms.ComputeSignature($packageSigner, $true)
    $proof = $cms.Encode()
    if ($proof.Length -gt 4096) { throw "Package proof too large for $newName" }
    [IO.File]::WriteAllBytes($file.FullName + '.p7s', $proof)
    [ordered]@{file=$newName; size=$file.Length; sha256=$digest; signer=$thumbprint; timestamped=$true}
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath outputs/opslinx-launcher-signatures.json -Encoding utf8
