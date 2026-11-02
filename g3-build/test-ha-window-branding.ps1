$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable runner required'}
$exe=Join-Path $env:ProgramFiles 'g3Fernwartung/g3Fernwartung.exe'
Start-Process $exe|Out-Null
$windows=@()
for($attempt=0;$attempt -lt 40;$attempt++){
 Start-Sleep -Milliseconds 500
 $windows=@(Get-Process g3Fernwartung -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $exe -and $_.MainWindowTitle -eq 'g3 OpsLinX'})
 if($windows.Count -eq 1){break}
}
if($windows.Count -ne 1){throw 'Visible OpsLinX main window missing or duplicated'}
$originalWindow=$windows[0].MainWindowHandle
# An invalid, non-secret handoff exercises dispatch without opening a remote session.
$dispatch=Start-Process $exe -ArgumentList 'g3fernwartung://g3-session/short' -PassThru
if(!$dispatch.WaitForExit(10000)){throw 'Warm URI dispatch did not return'}
Start-Sleep -Seconds 2
$after=@(Get-Process g3Fernwartung -ErrorAction SilentlyContinue|Where-Object {$_.Path -eq $exe -and $_.MainWindowTitle -eq 'g3 OpsLinX'})
if($after.Count -ne 1 -or $after[0].MainWindowHandle -ne $originalWindow){throw 'Warm dispatch duplicated or replaced the main window'}
@{visibleProductNameVerified=$true;warmUriUsesExistingWindow=$true;remoteSessionOpened=$false}|ConvertTo-Json|Set-Content outputs/ha-window-branding-acceptance.json
