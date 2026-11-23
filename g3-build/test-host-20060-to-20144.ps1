$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'This migration test requires a disposable GitHub-hosted Windows runner.'
}
if (Get-Service g3Host,g3Fernwartung -ErrorAction SilentlyContinue) {
    throw 'Expected a clean runner.'
}

$root = Join-Path $env:RUNNER_TEMP 'opslinx-host-migration'
New-Item -ItemType Directory -Path $root | Out-Null
$cluster = 'https://linx.g3nx.net/client/releases/'
$native = Join-Path $env:ProgramFiles 'g3Host\librustdesk.dll'
$gate = Join-Path $env:ProgramFiles 'g3Host\g3-update-session.lock'
$baselineHash = '49cf30431548d91424623e7526e35a7e410bf11f8ae4c21ddbfa6f4c96de24b9'
$targetHash = 'e71c5f259f28d2bdcc4bd38b6cbc4aa32d958a362f079ab440a7cfd2a2b3dc53'

function Get-PinnedPackage($route, $name, $hash) {
    $path = Join-Path $root $name
    Invoke-WebRequest ($cluster + $route) -MaximumRedirection 0 -OutFile $path -TimeoutSec 150
    if ((Get-FileHash -LiteralPath $path).Hash -ine $hash) { throw "Package mismatch: $name" }
    $path
}

function Assert-Host($version, $hash) {
    $registered = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
        Where-Object DisplayName -eq 'g3 OpsLinX Host' | Select-Object -ExpandProperty DisplayVersion)
    if ($registered.Count -ne 1 -or $registered[0] -ne $version -or
        (Get-FileHash -LiteralPath $native).Hash -ine $hash -or
        (Get-Service g3Host).Status -ne 'Running') {
        throw "Host $version did not reach the expected state."
    }
}

$setup = Get-PinnedPackage '1.5.3-g3.62.20060/host' 'g3-OpsLinX-Host-1.5.3-g3.62.20060-host-install.exe' '14e5e769cb144ef07ff651995e7df9f23325cf325e8d6778f41dac81f608adae'
$msi = Get-PinnedPackage '1.5.3-g3.62.20060/host_msi' 'g3-OpsLinX-Host-1.5.3-g3.62.20060-host-install.msi' 'e27ac336a9d731a51b7cc3562b385bf75cbbb2d10828d445ec37d91b96334bc1'
$bundle = Get-PinnedPackage '1.5.3-g3.70.20144/host_bundle' 'OpsLinX-Host-20144-OpsTalX-0.2.6-Sammelinstaller.exe' 'a67b6917d6c88188e882622e139bcf211aff10872338e2f96d571893bd19149a'
$signature = Get-AuthenticodeSignature -LiteralPath $bundle
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne '8E84AC698F2E3F7F4ECC11467A456C2AE1C94D74' -or !$signature.TimeStamperCertificate) {
    throw 'Unexpected Certum signature.'
}

$install = Start-Process -FilePath $setup -ArgumentList '--g3-install-worker', ('"' + $msi + '"') -Wait -PassThru
if ($install.ExitCode -notin 0,3010) { throw "Baseline install failed: $($install.ExitCode)" }
Assert-Host '1.62.20060' $baselineHash

$lock = [IO.File]::Open($gate, 'Open', 'ReadWrite', 'ReadWrite')
try {
    $lock.Lock(0, 1)
    $blocked = Start-Process -FilePath $bundle -ArgumentList '--quiet' -Wait -PassThru
    if ($blocked.ExitCode -ne 1618) { throw "Expected the installer to defer: $($blocked.ExitCode)" }
    Assert-Host '1.62.20060' $baselineHash
} finally {
    $lock.Dispose()
}

$update = Start-Process -FilePath $bundle -ArgumentList '--quiet' -Wait -PassThru
if ($update.ExitCode -notin 0,3010) { throw "Transition failed: $($update.ExitCode)" }
Assert-Host '1.70.20144' $targetHash
Write-Host 'Verified exact 20060-to-20144 migration, deferred update under lock and running Host service.'
