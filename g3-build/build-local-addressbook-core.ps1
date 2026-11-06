$ErrorActionPreference='Stop'
$release=Get-Content (Join-Path $PSScriptRoot 'local-addressbook-release.json') -Raw|ConvertFrom-Json
$source=Get-Content (Join-Path $PSScriptRoot 'build-password-reliability-core.ps1') -Raw
$old="`$env:G3_BUILD_VERSION='1.5.0-g3.60.19994'"
if(!$source.Contains($old)){throw 'Reviewed native build version boundary changed'}
Push-Location (Join-Path $PSScriptRoot '..')
try { & ([scriptblock]::Create($source.Replace($old,"`$env:G3_BUILD_VERSION='$($release.version)'"))) }
finally {Pop-Location}
