#requires -Version 7.2
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/Vmctl.psm1') -Force
$passed=0
function Assert([bool]$Value,[string]$Name){if(-not $Value){throw "FAILED: $Name"};$script:passed++;"OK: $Name"}
function Rejected([scriptblock]$Code,[string]$Pattern){$message=$null;try{& $Code|Out-Null}catch{$message=$_.Exception.Message};Assert ($message -match $Pattern) $Pattern}
# Framing roundtrip and hostile lengths: no pipes, VM or elevated process needed.
$stream=[IO.MemoryStream]::new()
$writer=[IO.BinaryWriter]::new($stream,[Text.Encoding]::UTF8,$true)
$bytes=[Text.Encoding]::UTF8.GetBytes('{"message":"français 日本語"}')
$writer.Write([int]$bytes.Length);$writer.Write($bytes);$writer.Flush();$stream.Position=0
Assert ((Read-VmctlPipeMessage $stream) -eq [Text.Encoding]::UTF8.GetString($bytes)) 'Unicode framed roundtrip'
$writer.Dispose();$stream.Dispose()
foreach($length in @(-1,0,16777217)){
    $s=[IO.MemoryStream]::new([BitConverter]::GetBytes([int]$length))
    try{Rejected {Read-VmctlPipeMessage $s} 'Taille de message'}finally{$s.Dispose()}
}
$s=[IO.MemoryStream]::new([byte[]]@(4,0,0,0,65))
try{Rejected {Read-VmctlPipeMessage $s} 'deconnecte'}finally{$s.Dispose()}
Rejected {Invoke-VmctlBrokerOperation @{operation='host-shell'}} 'Operation agent inconnue'
Rejected {Invoke-VmctlBrokerOperation @{operation='direct';target=@{hypervisor='none'}}} 'nom et GUID'
$target=@{hypervisor='hyperv';os='windows';vmName='test';vmId='82e1dde7-67c7-4ff0-956d-00fb4ee636e3'}
Rejected {Invoke-VmctlBrokerOperation @{operation='console';target=$target;timeoutSeconds=0}} 'Delai agent invalide'
Rejected {Invoke-VmctlBrokerOperation @{operation='console';target=$target;timeoutSeconds=10;parameters=@{Target=@{}}}} 'Parametre agent interdit'
Rejected {Invoke-VmctlBrokerOperation @{operation='console';target=$target;timeoutSeconds=10;parameters=@{Keys='';Target=@{}}}} 'Parametre agent interdit'
Rejected {Invoke-VmctlBrokerOperation @{operation='streaming-setup';target=$target;timeoutSeconds=10;parameters=@{Executable='untrusted.exe'}}} 'Parametre agent interdit'
$results=& (Get-Module Vmctl) {
    param($target)
    function Invoke-VmctlHyperV {param($Target,$Action,$Name,$RemoveCheckpoints,$DisableAutomaticCheckpoints,$TimeoutSeconds);@{target=$Target;action=$Action;timeout=$TimeoutSeconds;remove=[bool]$RemoveCheckpoints}}
    function Invoke-VmctlDirect {param($Target,$Request,$Credential,$TimeoutSeconds);@{user=$Credential.UserName;password=$Credential.GetNetworkCredential().Password;action=$Request.action;timeout=$TimeoutSeconds}}
    $h=Invoke-VmctlBrokerOperation @{operation='hyperv';target=$target;timeoutSeconds=60;parameters=@{Action='storage';Name='';RemoveCheckpoints=$false;DisableAutomaticCheckpoints=$false}}
    $c=[pscredential]::new('vm\admin',(ConvertTo-SecureString 'test-secret' -AsPlainText -Force))
    $d=Invoke-VmctlBrokerOperation @{operation='direct';target=$target;timeoutSeconds=50;request=@{action='exec'};user=$c.UserName;password=(ConvertFrom-SecureString $c.Password)}
    @{hyperv=$h;direct=$d}
} $target
Assert ($results.hyperv.target.vmId -eq $target.vmId -and $results.hyperv.action -eq 'storage' -and $results.hyperv.timeout -eq 60 -and -not $results.hyperv.remove) 'Fixed target and false switches preserved'
Assert ($results.direct.user -eq 'vm\admin' -and $results.direct.password -eq 'test-secret' -and $results.direct.action -eq 'exec') 'DPAPI credential reconstructed for same user'
$scratch=Join-Path $root ('work/broker-test-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $scratch
$result=& (Get-Module Vmctl) {
    param($scratch)
    function Get-VmctlBrokerPaths { @{Config=(Join-Path $scratch 'configuration.json');Disabled=(Join-Path $scratch 'privileged.disabled')} }
    $before=Test-VmctlBrokerInstalled
    '{}'|Set-Content (Join-Path $scratch 'configuration.json')
    $active=Test-VmctlBrokerInstalled
    $disabled=Set-VmctlPrivilegedMode disable
    @{before=$before;active=$active;disabled=$disabled;after=(Test-VmctlBrokerInstalled)}
} $scratch
Assert (-not $result.before -and $result.active -and -not $result.after -and -not $result.disabled.enabled) 'Disable blocks broker without elevation'
"$passed broker tests passed; no VM access or elevation."
