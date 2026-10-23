$ErrorActionPreference='Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Installation test may run only on a disposable GitHub Windows runner.' }
$root=(Resolve-Path "$PSScriptRoot/..").Path
$version='1.5.0-g3.24'
$setup=Join-Path $root "outputs/g3-Fernwartung-$version-install.exe"
$msi=Join-Path $root "outputs/g3-Fernwartung-$version-install.msi"
$install=Join-Path $env:ProgramFiles 'g3Fernwartung'
function Worker {
    $p=Start-Process -FilePath $setup -ArgumentList @('--g3-install-worker',('"'+$msi+'"')) -PassThru -Wait -WindowStyle Hidden
    if ($p.ExitCode -notin @(0,3010,1618)) {
        $diag=Join-Path $env:ProgramData "g3-NetworX-Setup-g3Fernwartung-$version"
        $target=Join-Path $root 'outputs/windows-installer-diagnostics'
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        foreach ($name in @('result.txt','update-error.txt','install.log')) {
            $file=Join-Path $diag $name
            if (Test-Path $file) { Copy-Item $file $target -Force;Write-Host "Installer diagnostic: $name";Get-Content $file -Tail 80 | Out-Host }
        }
    }
    return $p.ExitCode
}
function Ready {
    $result=Get-Content (Join-Path $env:ProgramData "g3-NetworX-Setup-g3Fernwartung-$version/result.txt") -Raw
    if ($result -notmatch 'product_ready=True') { throw "Installer did not verify the product: $result" }
    if ((Get-Service g3Fernwartung).Status -ne 'Running') { throw 'FullClient service is not running.' }
    if (Get-Service g3Host -ErrorAction SilentlyContinue) { throw 'FullClient test unexpectedly installed Host.' }
}
$code=Worker
if ($code -notin @(0,3010)) { throw "Clean install failed: $code" }
Ready
$sessionExe=Join-Path $install 'g3-gate-regression.exe'
Copy-Item "$root/work/session-gate-test/session.exe" $sessionExe
$psi=[System.Diagnostics.ProcessStartInfo]::new($sessionExe,'session')
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true
$session=[System.Diagnostics.Process]::Start($psi)
try {
    if ($session.StandardOutput.ReadLine() -ne 'READY') { throw 'Session did not acquire the actual installed gate.' }
    $serviceBefore=Get-CimInstance Win32_Service -Filter "Name='g3Fernwartung'"
    $before=(Get-FileHash "$install/g3Fernwartung.exe").Hash
    $code=Worker
    if ($code -ne 1618) { throw "Active session did not defer update: $code" }
    $serviceAfter=Get-CimInstance Win32_Service -Filter "Name='g3Fernwartung'"
    if ($session.HasExited -or $serviceBefore.ProcessId -ne $serviceAfter.ProcessId -or $serviceAfter.State -ne 'Running') { throw 'Busy update interrupted a process or service.' }
    if ((Get-FileHash "$install/g3Fernwartung.exe").Hash -ne $before) { throw 'Busy update changed the client.' }
} finally {
    if (!$session.HasExited) { $session.StandardInput.WriteLine('');if (!$session.WaitForExit(10000)) { throw 'Disposable session failed to release its lease.' } }
    $session.Dispose()
}
Set-Content (Join-Path $install 'SOURCE.txt') 'deliberately altered disposable repair fixture' -Encoding utf8
$code=Worker
if ($code -notin @(0,3010)) { throw "Idle repair failed: $code" }
Ready
if (!$env:G3_ACCEPTED_BASE) { throw 'Accepted baseline package location is required.' }
$remove=Start-Process msiexec.exe -ArgumentList @('/x',('"'+$msi+'"'),'/qn','REBOOT=ReallySuppress','/norestart') -PassThru -Wait -WindowStyle Hidden
if ($remove.ExitCode -notin @(0,3010)) { throw "Disposable removal failed: $($remove.ExitCode)" }
$baselineSetup=Join-Path $env:G3_ACCEPTED_BASE 'g3-Fernwartung-1.5.0-g3.21-install.exe'
$baselineMsi=Join-Path $env:G3_ACCEPTED_BASE 'g3-Fernwartung-1.5.0-g3.21-install.msi'
$baseline=Start-Process $baselineSetup -ArgumentList @('--g3-install-worker',('"'+$baselineMsi+'"')) -PassThru -Wait -WindowStyle Hidden
if ($baseline.ExitCode -notin @(0,3010)) { throw "Accepted baseline install failed: $($baseline.ExitCode)" }
$code=Worker
if ($code -notin @(0,3010)) { throw "Baseline upgrade failed: $code" }
Ready
@{version=$version;clean_install=$true;active_session_deferred=$true;service_pid_unchanged_while_busy=$true;idle_repair=$true;baseline_upgrade=$true;baseline_version='1.5.0-g3.21';fullclient_only=$true;scope='disposable GitHub Windows runner'} | ConvertTo-Json | Set-Content "$root/outputs/windows-update-installation-test.json" -Encoding utf8
