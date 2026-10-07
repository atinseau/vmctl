#requires -Version 7.2
function Get-VmctlBrokerPaths {
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $root=Join-Path $env:ProgramData "vmctl\broker\$sid"
    @{Root=$root;Config=(Join-Path $root 'configuration.json');Status=(Join-Path $root 'status.json');Disabled=(Join-Path (Get-VmctlDataRoot) 'privileged.disabled');Task="vmctl-Broker-$sid";Pipe="vmctl-broker-$sid"}
}
function Test-VmctlBrokerInstalled {
    if(-not $IsWindows){return $false}
    $paths=Get-VmctlBrokerPaths
    (Test-Path -LiteralPath $paths.Config) -and -not(Test-Path -LiteralPath $paths.Disabled)
}
function Invoke-VmctlBroker {
    param([hashtable]$Request,[int]$TimeoutSeconds=120)
    $paths=Get-VmctlBrokerPaths
    if(-not(Test-VmctlBrokerInstalled)){throw 'Mode privilegie vmctl non active.'}
    if(-not ('VmctlPipePeer' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class VmctlPipePeer {
 [DllImport("kernel32.dll",SetLastError=true)] public static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe,out uint pid);
}
'@
    }
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $paths.Pipe,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
    try {
        try {$pipe.Connect(1000)} catch [TimeoutException] {
            # Starting an already installed, delegated task does not request UAC.
            Start-ScheduledTask -TaskName $paths.Task -ErrorAction Stop
            $pipe.Connect(10000)
        }
        $status=Get-Content -LiteralPath $paths.Status -Raw|ConvertFrom-Json
        [uint32]$peer=0
        if(-not [VmctlPipePeer]::GetNamedPipeServerProcessId($pipe.SafePipeHandle,[ref]$peer) -or $peer -ne $status.pid){throw 'Identite de l agent privilegie invalide.'}
        $process=Get-Process -Id $peer -ErrorAction Stop
        if($process.StartTime.ToUniversalTime().Ticks -ne ([DateTimeOffset]$status.startedAt).UtcDateTime.Ticks){throw 'Session de l agent privilegie expiree.'}
        $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false),$true)
        try {
            $Request.timeoutSeconds=$TimeoutSeconds
            $json=ConvertTo-Json -InputObject $Request -Depth 12 -Compress
            if([Text.Encoding]::UTF8.GetByteCount($json) -gt 16777216){throw 'Requete agent trop volumineuse (16 Mio).'}
            $bytes=[Text.Encoding]::UTF8.GetBytes($json)
            $writer.Write([int]$bytes.Length);$writer.Write($bytes);$writer.Flush()
            $answer=Read-VmctlPipeMessage -Pipe $pipe -TimeoutSeconds ($TimeoutSeconds+15) -MaxBytes 67108864
            $answer|ConvertFrom-Json
        } finally {$writer.Dispose()}
    } finally {$pipe.Dispose()}
}
function Read-VmctlPipeMessage {
    param([IO.Stream]$Pipe,[int]$TimeoutSeconds=30,[int]$MaxBytes=16777216)
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $header=[byte[]]::new(4)
    $buffers=@(,$header)
    foreach($stage in 0,1){
        $buffer=$buffers[$stage];$offset=0
        while($offset -lt $buffer.Length){
            $read=$Pipe.ReadAsync($buffer,$offset,$buffer.Length-$offset)
            $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds
            if($remaining -le 0 -or -not $read.Wait($remaining)){throw 'Delai agent depasse. Resultat inconnu : ne pas relancer automatiquement.'}
            $count=$read.GetAwaiter().GetResult()
            if($count -eq 0){throw 'Agent/client deconnecte ; resultat inconnu.'}
            $offset+=$count
        }
        if($stage -eq 0){
            $length=[BitConverter]::ToInt32($header,0)
            if($length -le 0 -or $length -gt $MaxBytes){throw 'Taille de message agent invalide.'}
            $buffers+=,([byte[]]::new($length))
        }
    }
    [Text.Encoding]::UTF8.GetString($buffers[1])
}
function Invoke-VmctlBrokerOperation {
    param([hashtable]$Request)
    if($Request.operation -eq 'status'){
        return [pscustomobject]@{ExitCode=0;Stdout=([pscustomobject]@{available=$true;user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;elevated=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}|ConvertTo-Json -Compress);Stderr=''}
    }
    if($Request.operation -notin @('hyperv','gpu','console','direct','streaming-setup')){throw 'Operation agent inconnue.'}
    $t=$Request.target
    if(-not $t -or $t.hypervisor -ne 'hyperv' -or -not $t.vmName -or -not $t.vmId){throw 'Agent : nom et GUID Hyper-V explicites requis.'}
    $null=[guid]::Parse($t.vmId)
    $timeout=[int]$Request.timeoutSeconds
    if($timeout -lt 1 -or $timeout -gt 86400){throw 'Delai agent invalide.'}
    if($Request.operation -ne 'direct'){
        $allowed=switch($Request.operation){hyperv {@('Action','Name','RemoveCheckpoints','DisableAutomaticCheckpoints')} gpu {@('Mode','GpuName','Percent')} console {@('Vm','Action','OutFile','Frame','Text','Keys','X','Y','ToX','ToY','ButtonIndex','Count','Delta','MaxFrameAgeSeconds')} streaming-setup {@('Vm','Config','ReportDirectory','CredentialFile','UserName','Open')}}
        foreach($entry in $Request.parameters.GetEnumerator()){if($entry.Key -notin $allowed){throw "Parametre agent interdit : $($entry.Key)"}}
    }
    switch($Request.operation){
        streaming-setup {
            $info=[Diagnostics.ProcessStartInfo]::new()
            $info.FileName=Join-Path $PSHOME 'pwsh.exe'
            $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true
            $info.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
            foreach($a in @('-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot '../scripts/Start-BrokerStreamingSetup.ps1'))){$info.ArgumentList.Add($a)}
            $p=[Diagnostics.Process]::new();$p.StartInfo=$info
            try{
                $null=$p.Start()
                $p.StandardInput.Write(($Request.parameters|ConvertTo-Json -Depth 5 -Compress));$p.StandardInput.Close()
                return @{ExitCode=0;Stdout=(@{state='launched';pid=$p.Id;reportDirectory=$Request.parameters.ReportDirectory;statusFile=(Join-Path $Request.parameters.ReportDirectory 'streaming-status.json')}|ConvertTo-Json -Compress);Stderr=''}
            }finally{$p.Dispose()}
        }
        hyperv { $p=$Request.parameters;Invoke-VmctlHyperV -Target $t @p -TimeoutSeconds $timeout }
        gpu { $p=$Request.parameters;Invoke-VmctlGpu -Target $t @p -TimeoutSeconds $timeout }
        console { $p=$Request.parameters;Invoke-VmctlConsole -Target $t @p -TimeoutSeconds $timeout }
        direct {
            $credential=[Management.Automation.PSCredential]::new([string]$Request.user,(ConvertTo-SecureString -String $Request.password))
            Invoke-VmctlDirect -Target $t -Request $Request.request -Credential $credential -TimeoutSeconds $timeout
        }
    }
}
function Set-VmctlPrivilegedMode {
    param([ValidateSet('enable','disable','status')][string]$Mode)
    if(-not $IsWindows){throw 'Le mode privilegie exige Windows.'}
    $paths=Get-VmctlBrokerPaths
    if($Mode -eq 'disable'){
        $null=New-Item -ItemType Directory -Path (Split-Path $paths.Disabled -Parent) -Force
        [IO.File]::WriteAllText($paths.Disabled,'disabled')
        return @{enabled=$false;installed=(Test-Path $paths.Config);pendingOperations='Les operations deja lancees terminent avant la fermeture de l agent.'}
    }
    if($Mode -eq 'enable'){
        if(-not(Test-Path $paths.Config)){
            $installer=Join-Path $PSScriptRoot '../scripts/Install-AdminBroker.ps1'
            $result=Join-Path (Get-VmctlDataRoot) ('work/broker-install-'+[guid]::NewGuid().ToString('N')+'.json')
            $null=New-Item -ItemType Directory -Path (Split-Path $result -Parent) -Force
            $exe=Join-Path $PSHOME 'pwsh.exe'
            $arguments='-NoLogo -NoProfile -NonInteractive -File "'+$installer+'" -ResultPath "'+$result+'"'
            $p=Start-Process -FilePath $exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru
            try{$p.WaitForExit();if($p.ExitCode -ne 0){throw 'Installation du mode privilegie echouee.'}}finally{$p.Dispose()}
            if(-not(Test-Path $paths.Config)){throw 'Installation non confirmee.'}
        }
        if(Test-Path $paths.Disabled){
            $deadline=[DateTime]::UtcNow.AddSeconds(10)
            while((Get-ScheduledTask -TaskName $paths.Task).State -eq 'Running'){
                if([DateTime]::UtcNow -ge $deadline){throw 'Agent encore occupe ; attendre la fin de l operation avant de reactiver.'}
                Start-Sleep -Milliseconds 250
            }
            Remove-Item -LiteralPath $paths.Disabled
        }
        $r=Invoke-VmctlBroker @{operation='status'}
        if($r.ExitCode -ne 0){throw $r.Stderr}
        return @{enabled=$true;installed=$true;agent=($r.Stdout|ConvertFrom-Json);source=(Get-Content $paths.Config -Raw|ConvertFrom-Json).repoRoot}
    }
    $enabled=Test-VmctlBrokerInstalled
    $agent=$null;$errorText=$null
    if($enabled){try{$r=Invoke-VmctlBroker @{operation='status'};if($r.ExitCode -ne 0){throw $r.Stderr};$agent=$r.Stdout|ConvertFrom-Json}catch{$errorText=$_.Exception.Message}}
    @{enabled=$enabled;installed=(Test-Path $paths.Config);agent=$agent;error=$errorText;source=$(if(Test-Path $paths.Config){(Get-Content $paths.Config -Raw|ConvertFrom-Json).repoRoot})}
}
