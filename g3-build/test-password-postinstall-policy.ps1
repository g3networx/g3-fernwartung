$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'standard-password-postinstall.ps1'),[ref]$tokens,[ref]$errors)
if($errors){throw 'Shared password helper syntax invalid'}
$function=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'CredentialPolicy'},$true)
if(!$function){throw 'Actual helper policy function missing'}
$policy=$function.Body.GetScriptBlock()
$before="verification-method = 'use-both-passwords'`nrandom-password-length = 'fixture-otp-policy'`ng3-password-registry-revision = '1'"
$after=$before.Replace("revision = '1'","revision = '2'")+"`ng3-local-passwords = 'fixture-encrypted'`ng3-local-password-labels = 'fixture-label'"
if((& $policy $before) -ne (& $policy $after)){throw 'Expected registry revision/additional storage change was misclassified'}
$cases=@()
$cases+=($after.Replace('fixture-otp-policy','different-otp-policy'))
$cases+=($after.Replace('use-both-passwords','use-permanent-password'))
$cases+=($after+"`nother-security-option = 'changed'")
foreach($changed in $cases){
 if((& $policy $before) -eq (& $policy $changed)){throw 'Unrelated password/OTP policy change was hidden'}
}
'Actual shared postinstall helper policy regression checks passed'
