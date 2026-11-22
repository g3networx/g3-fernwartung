param(
    [Parameter(Mandatory)][string]$OpsLinXRelease,
    [Parameter(Mandatory)][string]$OpsTalXMsi,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][string]$Build,
    [ValidateRange(40,255)][int]$ReleaseTrain = 62,
    [Parameter(Mandatory)][version]$OpsTalXVersion,
    [Parameter(Mandatory)][string]$SignTool,
    [Parameter(Mandatory)][string]$SignerThumbprint
)

$ErrorActionPreference = 'Stop'
$csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$icon = (Resolve-Path (Join-Path $PSScriptRoot '../../flutter/windows/runner/resources/app_icon.ico')).Path
$manifest = Join-Path $PSScriptRoot 'ConferenceBundle.manifest'
$source = Join-Path $PSScriptRoot 'ConferenceBundle.cs'
$linxRelease = (Resolve-Path $OpsLinXRelease).Path
$talxMsi = (Resolve-Path $OpsTalXMsi).Path
$outputPath = (New-Item -ItemType Directory -Path $Output -Force).FullName
$checksums = Get-Content -Raw (Join-Path $linxRelease 'opslinx-signatures.json') | ConvertFrom-Json

function Get-VerifiedHash([string]$File) {
    $signature = Get-AuthenticodeSignature -LiteralPath $File
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $SignerThumbprint -or
        $null -eq $signature.TimeStamperCertificate) {
        throw "Invalid signature or timestamp on $File"
    }
    (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
}

$talxHash = Get-VerifiedHash $talxMsi
$metadata = [IO.Path]::GetTempFileName()
try {
    foreach ($variant in @(
        @{ Label = 'Vollclient'; Product = 'g3Fernwartung'; Prefix = 'g3-OpsLinX'; Installer = 'install' },
        @{ Label = 'Host'; Product = 'g3Host'; Prefix = 'g3-OpsLinX-Host'; Installer = 'host-install' }
    )) {
        $stem = "$($variant.Prefix)-1.5.3-g3.$ReleaseTrain.$Build-$($variant.Installer)"
        $linxExe = Join-Path $linxRelease "$stem.exe"
        $linxMsi = Join-Path $linxRelease "$stem.msi"
        $exeHash = Get-VerifiedHash $linxExe
        $msiHash = Get-VerifiedHash $linxMsi
        if ($exeHash -ne ($checksums | Where-Object file -eq "$stem.exe").sha256 -or
            $msiHash -ne ($checksums | Where-Object file -eq "$stem.msi").sha256) {
            throw "OpsLinX release hashes do not match $stem"
        }
        @($variant.Product, "1.$ReleaseTrain.$Build", "$OpsTalXVersion", $exeHash, $msiHash, $talxHash) |
            Set-Content -LiteralPath $metadata -Encoding ASCII
        $file = Join-Path $outputPath "OpsLinX-$($variant.Label)-$Build-OpsTalX-$OpsTalXVersion-Sammelinstaller.exe"
        $compilerArgs = @(
            '/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001', '/reference:System.Windows.Forms.dll',
            "/win32manifest:$manifest", "/win32icon:$icon", "/resource:$metadata,bundle.metadata",
            "/resource:$linxExe,bundle.linx.exe", "/resource:$linxMsi,bundle.linx.msi", "/resource:$talxMsi,bundle.talx.msi",
            "/out:$file", $source
        )
        & $csc @compilerArgs
        if ($LASTEXITCODE -ne 0) { throw "Bundle compilation failed for $($variant.Label)" }
        & $SignTool sign /s My /sha1 $SignerThumbprint /fd SHA256 /tr http://time.certum.pl /td SHA256 $file
        if ($LASTEXITCODE -ne 0) { throw "Bundle signing failed for $($variant.Label)" }
        & $SignTool verify /pa /all /tw $file
        if ($LASTEXITCODE -ne 0) { throw "Bundle signature verification failed for $($variant.Label)" }
        $hash = Get-VerifiedHash $file
        Write-Output "$hash  $file"
    }
} finally {
    Remove-Item -LiteralPath $metadata -Force
}
