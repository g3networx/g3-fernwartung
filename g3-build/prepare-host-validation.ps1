param(
  [Parameter(Mandatory=$true)][string]$ArtifactDirectory,
  [Parameter(Mandatory=$true)][string]$PackageDirectory
)
$ErrorActionPreference='Stop'
$artifact=(Resolve-Path $ArtifactDirectory).Path
$package=(New-Item -ItemType Directory -Force -Path $PackageDirectory).FullName
$outputs=Get-Content (Join-Path $artifact 'SHA256.json') -Raw | ConvertFrom-Json
foreach($item in $outputs){
  $file=Join-Path $artifact $item.file
  if(!(Test-Path -LiteralPath $file)){throw "Missing artifact file $($item.file)"}
  if((Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ne $item.Hash.ToLowerInvariant()){throw "Artifact file hash mismatch: $($item.file)"}
}
$items=Get-Content (Join-Path $artifact 'msi-items.json') -Raw | ConvertFrom-Json
$version='1.5.0-g3.25'
foreach($key in @('host_msi')){
  $entry=$items.$key
  $source=Join-Path $artifact $entry.file
  if((Get-Item -LiteralPath $source).Length -ne $entry.size){throw 'Host MSI size mismatch'}
  if((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -ne $entry.sha256.ToLowerInvariant()){throw 'Host MSI hash mismatch'}
  Copy-Item -LiteralPath $source -Destination $package
}
$setup=Get-ChildItem -LiteralPath $artifact -Filter 'g3-OpsLinX-Host-1.5.0-g3.25-host-install.exe' -File
if(!$setup){throw 'Host bootstrapper missing'}
Copy-Item -LiteralPath $setup.FullName -Destination $package
$payloadZip=Join-Path $artifact 'g3-windows-unsigned.zip'
$payloadRoot=Join-Path $package 'payload'
Expand-Archive -LiteralPath $payloadZip -DestinationPath $payloadRoot -Force
$payload=@{}
Get-ChildItem -LiteralPath $payloadRoot -Recurse -File | ForEach-Object {
  $relative=$_.FullName.Substring($payloadRoot.Length+1).Replace('\','/')
  if($relative -eq 'rustdesk.exe'){$relative='g3Host.exe'}
  $payload[$relative]=(Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()
}
$bootstrapName=$setup.Name
$msiName=$items.host_msi.file
$proof=@{
  version=$version
  packages=@{
    $bootstrapName=(Get-FileHash (Join-Path $package $bootstrapName)).Hash.ToLowerInvariant()
    $msiName=(Get-FileHash (Join-Path $package $msiName)).Hash.ToLowerInvariant()
  }
  payload=$payload
}
$proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $package 'package.json') -Encoding utf8
Write-Output "Prepared exact $version Host candidate for isolated native validation."
