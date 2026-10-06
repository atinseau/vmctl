#requires -Version 7.2
param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$Vm,[Parameter(Mandatory)][string]$VmName,[string]$VmId,[string]$HostName)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../src/DataPaths.ps1')
Import-Module (Join-Path $PSScriptRoot '../src/StreamingSupport.psm1') -Force
$report=Join-Path (Get-VmctlDataRoot) "reports\streaming\$Vm\streaming-install-result.json"
$serverUuid=''
$bindingPath=Join-Path (Get-VmctlDataRoot) "streaming-bindings\$Vm.json"
if(Test-Path -LiteralPath $bindingPath){$binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json; if($binding.vmName -ine $VmName -or ($VmId -and $binding.vmId -ine $VmId)){throw 'Saved Apollo binding belongs to another VM.'}; $serverUuid=[string]$binding.serverUuid}
elseif(Test-Path -LiteralPath $report){$state=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json; if($state.PSObject.Properties.Name -contains 'moonlightHostUuid'){$serverUuid=[string]$state.moonlightHostUuid}}
$matches=@(Get-VmctlMoonlightHost -VmName $(if(-not $HostName){$VmName}) -Address $HostName -ServerUuid $serverUuid)
if($matches.Count -gt 1){throw 'Multiple Moonlight hosts match this VM; specify -HostName to identify the target.'}
if($serverUuid){$null=[guid]::Parse($serverUuid)}
if($matches.Count -eq 1){$null=[guid]::Parse($matches[0].uuid)}
if($matches.Count -eq 1){$result=Remove-VmctlMoonlightHost -ServerUuid $matches[0].uuid}
else {$result=[pscustomobject]@{removed=0;uuid=$serverUuid}}
# Clear only this alias's Apollo login and stale configuration backups.
$credential=Join-Path (Get-VmctlDataRoot) "credentials\apollo-$Vm.clixml"
if(Test-Path -LiteralPath $credential){Remove-Item -LiteralPath $credential}
if(Test-Path -LiteralPath $bindingPath){Remove-Item -LiteralPath $bindingPath}
foreach($file in @('apollo-display-before.clixml','apollo-video-before.clixml','streaming-install-result.json')) {
    $path=Join-Path (Get-VmctlDataRoot) "reports\streaming\$Vm\$file"
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path}
}
if($result.uuid) {
    $uuid=[guid]::Parse($result.uuid).ToString().ToUpperInvariant()
    $cacheRoot=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Moonlight Game Streaming Project\Moonlight\cache\boxart')).TrimEnd('\')
    $cache=[IO.Path]::GetFullPath((Join-Path $cacheRoot $uuid))
    if(-not $cache.StartsWith($cacheRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Cache target outside Moonlight boxart.'}
    if(Test-Path -LiteralPath $cache){if((Get-Item -LiteralPath $cache).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected cache directory refused'}; if(Get-ChildItem -LiteralPath $cache -Recurse -Force|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw 'Links inside cache refused'}; Remove-Item -LiteralPath $cache -Recurse -Force}
}
[pscustomobject]@{vm=$Vm;moonlight=$result;apolloCredentialRemoved=(-not(Test-Path -LiteralPath $credential));clientIdentityPreserved=$true} | ConvertTo-Json -Depth 4
