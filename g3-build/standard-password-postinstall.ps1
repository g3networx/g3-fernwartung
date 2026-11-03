function Complete-G3FreshInstallPassword {
 [CmdletBinding()]
 param(
  [Parameter(Mandatory)]$Session,
  [Parameter(Mandatory)][securestring]$StandardPassword,
  [Parameter(Mandatory)][ValidateSet('g3Host','g3Fernwartung')][string]$App,
  [Parameter(Mandatory)][string]$ExpectedComputer,
  [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedNativeSha256,
  [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedExecutableSha256,
  [Parameter(Mandatory)]$InstallResult,
  [string]$ReceiptDirectory=(Join-Path $PSScriptRoot '../../outputs')
 )
 $proof=@{status='not-attempted-installation-not-ready';changeAttempted=$false}
 if($InstallResult.exit -in @(0,3010) -and $InstallResult.checks.newNativeIdVerified -eq $true -and $InstallResult.newDeviceId -match '^\d{6,12}$') {
  try {
   $proof=Invoke-Command -Session $Session -ArgumentList $StandardPassword,$InstallResult.newDeviceId,$ExpectedComputer,$App,$ExpectedNativeSha256,$ExpectedExecutableSha256 -ScriptBlock {
   param([securestring]$secret,[string]$expectedId,[string]$expectedComputer,[string]$app,[string]$expectedNative,[string]$expectedExe)
   $ErrorActionPreference='Stop'
   if($env:COMPUTERNAME -ne $expectedComputer){throw 'Computer identity mismatch'}
   $root=Join-Path $env:ProgramFiles $app;$exe=Join-Path $root ($app+'.exe')
   $service=Get-CimInstance Win32_Service -Filter "Name='$app'"
   if(!$service -or $service.State -ne 'Running' -or !(Test-Path $exe)){return @{status='deferred-host-not-running';changeAttempted=$false}}
   $native=(Get-FileHash (Join-Path $root 'librustdesk.dll')).Hash.ToLowerInvariant()
   if($native -ne $expectedNative){return @{status='deferred-unverified-native';changeAttempted=$false}}
   if((Get-FileHash $exe).Hash.ToLowerInvariant() -ne $expectedExe){throw 'Full executable pin mismatch'}
   function HashText([string]$s){$h=[Security.Cryptography.SHA256]::Create();try{[Convert]::ToBase64String($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))}finally{$h.Dispose()}}
   function RunNative([string]$arguments,[string]$inputText){
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe;$start.Arguments=$arguments;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start;$null=$process.Start()
    if($null -ne $inputText){$process.StandardInput.WriteLine($inputText)};$process.StandardInput.Close()
    $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
    if(!$process.WaitForExit(20000)){return @{timeout=$true;exit=-1;output='';processId=$process.Id}}
    @{timeout=$false;exit=$process.ExitCode;output=$outTask.GetAwaiter().GetResult().Trim()}
   }
   $identity=RunNative '--get-id' $null
   if($identity.timeout -or $identity.exit -ne 0 -or $identity.output -ne $expectedId){return @{status='deferred-identity-unverified';changeAttempted=$false}}
   $configRoot=Join-Path $env:SystemRoot ('ServiceProfiles\LocalService\AppData\Roaming\'+$app+'\config')
   $config=Join-Path $configRoot ($app+'.toml');$options=Join-Path $configRoot ($app+'2.toml')
   if(!(Test-Path $config) -or !(Test-Path $options)){throw 'Authoritative configuration missing'}
   $preCredential=(Get-FileHash $config).Hash;$preOptions=[IO.File]::ReadAllText($options)
   # The existing CLI treats undecodable local storage as empty. Never risk discarding existing entries.
   if($preOptions -match '(?m)^\s*g3-local-passwords\s*=\s*[\x27\x22](?![\x27\x22])'){return @{status='deferred-existing-additional-passwords';changeAttempted=$false}}
   function CredentialPolicy {
    param([string]$text)
    (($text -split '\r?\n'|Where-Object {$_ -notmatch '^\s*(g3-local-password(s|-labels)|g3-password-registry-revision)\s*='}|Sort-Object) -join "`n")
   }
   $prePolicy=HashText (CredentialPolicy $preOptions)
   $preBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks
   $label='OpsLinX Standardkennwort'
   $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret)
   try {
    $value=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    $payload=@{action='add';label=$label;password=$value}|ConvertTo-Json -Compress
    $answer=RunNative '--g3-local-password-stdin' $payload
   }finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr);$value=$null;$payload=$null}
   if($answer.timeout){return @{status='change-outcome-unknown-no-retry';changeAttempted=$true;processId=$answer.processId}}
   Start-Sleep -Milliseconds 500
   $postOptions=[IO.File]::ReadAllText($options)
   $postPolicy=HashText (CredentialPolicy $postOptions)
   $postSvc=Get-CimInstance Win32_Service -Filter "Name='$app'"
   $postId=RunNative '--get-id' $null
   $checks=[ordered]@{
    nativeCommandConfirmed=($answer.exit -eq 0 -and $answer.output -eq 'Customer password change confirmed')
    encryptedAdditionalStored=($postOptions -match '(?m)^\s*g3-local-passwords\s*=\s*[\x27\x22]00[^\x27\x22]+[\x27\x22]')
    additionalLabelStored=$postOptions.Contains($label)
    permanentCredentialAndIdentityStorageUnchanged=((Get-FileHash $config).Hash -eq $preCredential)
    otherOptionsIncludingOtpUnchanged=($prePolicy -eq $postPolicy)
    servicePidUnchanged=($service.ProcessId -eq $postSvc.ProcessId -and $postSvc.State -eq 'Running')
    bootUnchanged=($preBoot -eq (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().Ticks)
    identityUnchanged=(!$postId.timeout -and $postId.exit -eq 0 -and $postId.output -eq $expectedId)
    variantUnchanged=($app -eq 'g3Host' -or !(Get-Service g3Host -ErrorAction SilentlyContinue))
   }
   $ok=@($checks.Values|Where-Object {$_ -ne $true}).Count -eq 0
   @{status=$(if($ok){'added-verified'}else{'change-requires-review-no-retry'});changeAttempted=$true;checks=$checks;servicePID=$postSvc.ProcessId}

   }
  } catch { $proof=@{status='standard-password-outcome-unknown-no-retry';changeAttempted=$true;errorType=$_.Exception.GetType().Name} }
 }
 $verified=($proof.status -eq 'added-verified' -and $proof.checks -and @($proof.checks.Values).Count -ge 9 -and @($proof.checks.Values|Where-Object {$_ -ne $true}).Count -eq 0)
 $InstallResult | Add-Member -NotePropertyName standardPasswordRequired -NotePropertyValue $true -Force
 $InstallResult | Add-Member -NotePropertyName standardPasswordVerified -NotePropertyValue $verified -Force
 $InstallResult | Add-Member -NotePropertyName addressBookCredentialVerified -NotePropertyValue $false -Force
 $InstallResult | Add-Member -NotePropertyName addressBookCredentialSynchronizationRequired -NotePropertyValue $verified -Force
 $InstallResult | Add-Member -NotePropertyName standardPassword -NotePropertyValue $proof -Force
 if(!$verified -and $InstallResult.status -eq 'installed-verified') { $InstallResult.status='standard-password-not-verified-no-retry' }
 $receipt=@{target=$Session.ComputerName;app=$App;deviceId=$InstallResult.newDeviceId;checkedAt=[DateTimeOffset]::UtcNow.ToString('o');standardPasswordVerified=$verified;details=$proof;passwordNotLogged=$true}
 $receipt | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath (Join-Path $ReceiptDirectory ($ExpectedComputer+'-Standardkennwort-'+(Get-Date -Format yyyyMMdd)+'.json')) -Encoding UTF8
}
