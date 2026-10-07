#requires -Version 7.2
function Invoke-VmctlGpu {
    param([hashtable]$Target,[ValidateSet('setup','status','sync','remove','task-test')][string]$Mode,
        [string]$GpuName='NVIDIA GeForce RTX 4090',[ValidateRange(1,100)][int]$Percent=25,
        [switch]$Elevate,[int]$TimeoutSeconds=900)
    if (-not $IsWindows -or $Target.hypervisor -ne 'hyperv' -or $Target.os -ne 'windows') { throw 'GPU automation requires a local Hyper-V Windows target.' }
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if((Test-VmctlBrokerInstalled) -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        return Invoke-VmctlBroker @{operation='gpu';target=$Target;parameters=@{Mode=$Mode;GpuName=$GpuName;Percent=$Percent}} -TimeoutSeconds $TimeoutSeconds
    }
    $worker=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Invoke-GpuWorker.ps1'
    $folder=Join-Path (Get-VmctlDataRoot) 'work\gpu'
    $null=New-Item -ItemType Directory -Path $folder -Force
    $response=Join-Path $folder ([guid]::NewGuid().ToString('N')+'.response.json')
    $parameters=@{Mode=$Mode;VmName=[string]$Target.vmName;GpuName=$GpuName;Percent=$Percent;ResponsePath=$response}
    if ($Target.ContainsKey('vmId')) { $parameters.VmId=([guid]$Target.vmId).ToString() }
    $winps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$worker)
        foreach($entry in $parameters.GetEnumerator()) { $arguments+=@(('-'+$entry.Key),([string]$entry.Value)) }
        return Invoke-VmctlProcess $winps $arguments -TimeoutSeconds $TimeoutSeconds
    }
    if (-not $Elevate) { throw 'GPU administration requires an elevated terminal or -Elevate.' }
    $arguments=@($parameters.GetEnumerator() | ForEach-Object { '-'+$_.Key+" '"+([string]$_.Value).Replace("'","''")+"'" })
    $code="& '"+$worker.Replace("'","''")+"' "+($arguments -join ' ')
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $process=Start-Process -FilePath $winps -ArgumentList '-NoProfile','-NonInteractive','-EncodedCommand',$encoded -Verb RunAs -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds*1000)) { return [pscustomobject]@{ExitCode=124;Stdout='';Stderr=('GPU operation may still be running; inspect before retrying: '+$response)} }
    if (-not (Test-Path -LiteralPath $response)) { throw 'Elevated GPU worker did not produce a response.' }
    $data=Get-Content -LiteralPath $response -Raw
    $result=$data | ConvertFrom-Json
    if ($result.PSObject.Properties.Name -contains 'error') { return [pscustomobject]@{ExitCode=1;Stdout='';Stderr=$result.error} }
    return [pscustomobject]@{ExitCode=0;Stdout=$data;Stderr=''}
}
