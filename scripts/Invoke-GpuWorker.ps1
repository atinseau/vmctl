#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [guid]$VmId=[guid]::Empty,
    [ValidateSet('status','setup','sync','start','startup','check','remove','task-test')][string]$Mode='status',
    [string]$VmName,[string]$GpuName='NVIDIA GeForce RTX 4090',
    [ValidateRange(1,100)][int]$Percent=25,
    [string]$ResponsePath,
    [string]$StateRoot=(Join-Path $env:ProgramData 'vmctl\gpu')
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$support=Join-Path (Split-Path $PSScriptRoot -Parent) 'src\GpuSupport.psm1'
if (-not (Test-Path -LiteralPath $support)) { $support=Join-Path $PSScriptRoot 'GpuSupport.psm1' }
Import-Module $support -Force
Import-Module Hyper-V
$id=$VmId.ToString()
$folder=Join-Path $StateRoot $id
$configurationPath=Join-Path $folder 'configuration.json'
$statePath=Join-Path $folder 'driver-state.json'
$taskName='vmctl-GPU-'+$id
$lock=$null
function Save-Json([object]$Value,[string]$Path) {
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding utf8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Protect-Folder([string]$Path) {
    $null=New-Item -ItemType Directory -Path $Path -Force
    if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'GPU automation folders cannot be reparse points.' }
    $acl=Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544')) {
        $rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Test-StartupTask {
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
    if ($task.State -eq 'Running') { throw 'The startup task is already running.' }
    $previous=(Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime
    Start-ScheduledTask -TaskName $taskName
    $deadline=(Get-Date).AddSeconds(900)
    do {
        Start-Sleep -Seconds 2
        $task=Get-ScheduledTask -TaskName $taskName
        $info=Get-ScheduledTaskInfo -TaskName $taskName
        if ($info.LastRunTime -gt $previous -and $task.State -ne 'Running') { break }
        if ((Get-Date) -ge $deadline) { throw 'Startup task test timed out; it may still be running.' }
    } while ($true)
    if ($info.LastTaskResult -ne 0) { throw "Startup task failed with result $($info.LastTaskResult)." }
    $operation=Get-Content -LiteralPath (Join-Path $folder 'last-operation.json') -Raw | ConvertFrom-Json
    if ($operation.mode -ne 'startup' -or $operation.state -ne 'Running') { throw 'The startup task did not report a running VM.' }
    return @{task=$taskName;principal=$task.Principal.UserId;lastRun=$info.LastRunTime.ToString('o');lastTaskResult=$info.LastTaskResult;startup=$operation}
}
function Get-DriverInventory([string]$PciIdentity) {
    $driver=Get-CimInstance Win32_PnPSignedDriver | Where-Object DeviceID -ieq $PciIdentity
    if (@($driver).Count -ne 1 -or $driver.Manufacturer -notmatch 'NVIDIA') { throw 'An exact NVIDIA GPU driver is required.' }
    $device=Get-PnpDevice -InstanceId $driver.DeviceID
    if ($device.Status -ne 'OK') { throw 'The selected host GPU is not healthy.' }
    $service=(Get-PnpDeviceProperty -InstanceId $driver.DeviceID -KeyName 'DEVPKEY_Device_Service').Data
    $serviceDriver=Get-CimInstance Win32_SystemDriver | Where-Object Name -eq $service
    $package=Split-Path $serviceDriver.PathName.Trim('"') -Parent
    $repository=[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\DriverStore\FileRepository'))
    $package=[IO.Path]::GetFullPath($package)
    if (-not $package.StartsWith($repository+'\',[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $package -Parent) -ine $repository) { throw 'The selected GPU driver package is outside the Windows DriverStore.' }
    $packageName=Split-Path $package -Leaf
    $files=@(foreach($item in @(Get-ChildItem -LiteralPath $package -Recurse -File | Sort-Object FullName)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point found in driver package.' }
        $relative='Windows\System32\HostDriverStore\FileRepository\'+$packageName+'\'+$item.FullName.Substring($package.Length+1)
        [pscustomobject]@{source=$item.FullName;relative=$relative;length=$item.Length;modified=$item.LastWriteTimeUtc.Ticks}
    })
    # NVIDIA user-mode APIs are also needed outside HostDriverStore (NVENC, CUDA, NVAPI).
    foreach($systemFolder in @('System32','SysWOW64')) {
        foreach($item in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot $systemFolder) -Filter 'nv*' -File | Sort-Object Name)) {
            if ($item.VersionInfo.CompanyName -notmatch 'NVIDIA') { continue }
            $files += [pscustomobject]@{source=$item.FullName;relative=('Windows\'+$systemFolder+'\'+$item.Name);length=$item.Length;modified=$item.LastWriteTimeUtc.Ticks}
        }
    }
    if (-not ($files | Where-Object relative -eq 'Windows\System32\nvEncodeAPI64.dll')) { throw 'NVENC library is missing on the host.' }
    foreach($file in $files) { Assert-VmctlGpuRelativePath $file.relative }
    $records=@($driver.DeviceID,$driver.DriverVersion,$driver.InfName,$packageName)+@($files | ForEach-Object { $_.relative+'|'+$_.length+'|'+$_.modified })
    return [pscustomobject]@{deviceId=$driver.DeviceID;version=$driver.DriverVersion;inf=$driver.InfName;package=$package;fingerprint=(Get-VmctlGpuFingerprint $records);files=$files}
}
function Sync-OfflineDriver([object]$Inventory,[object]$Machine) {
    if ($Machine.State -ne 'Off') { throw 'Driver synchronization requires the VM to be fully off.' }
    $drives=@(Get-VMHardDiskDrive -VM $Machine | Where-Object Path)
    if ($drives.Count -ne 1) { throw 'This GPU recipe requires exactly one attached Windows system disk.' }
    $leaf=[IO.Path]::GetFullPath($drives[0].Path)
    if ((Get-VHD -Path $leaf).Attached) { throw 'The active guest disk is already attached.' }
    $mount=Join-Path $folder ('mount-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $mount
    $mounted=$false; $accessAdded=$false; $partition=$null
    try {
        $vhd=Mount-VHD -Path $leaf -NoDriveLetter -Passthru
        $mounted=$true
        $disk=$vhd | Get-Disk
        $candidates=@(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Size -gt 3GB -and $_.GptType -eq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' })
        if ($candidates.Count -ne 1) { throw 'A unique Windows data partition was not found.' }
        $partition=$candidates[0]
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath ($mount+'\')
        $accessAdded=$true
        if (-not (Test-Path -LiteralPath (Join-Path $mount 'Windows\System32\config\SYSTEM'))) { throw 'Mounted partition is not a Windows installation.' }
        $copied=0; $bytes=0; $manifest=@()
        foreach($file in $Inventory.files) {
            $destination=[IO.Path]::GetFullPath((Join-Path $mount $file.relative))
            if (-not $destination.StartsWith($mount+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Driver destination escaped the mounted guest.' }
            $ancestor=$destination
            while ($ancestor.Length -gt $mount.Length) {
                if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'A guest driver path contains a reparse point; refusing host file access.' }
                $ancestor=Split-Path $ancestor -Parent
            }
            $null=New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            $hash=(Get-FileHash -LiteralPath $file.source -Algorithm SHA256).Hash
            Copy-Item -LiteralPath $file.source -Destination $destination -Force
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) { throw "Driver copy hash mismatch: $($file.relative)" }
            $copied++; $bytes+=$file.length
            $manifest += [pscustomobject]@{relative=$file.relative;sha256=$hash;bytes=$file.length}
        }
        $afterInventory=Get-DriverInventory $Inventory.deviceId
        if ($afterInventory.fingerprint -ne $Inventory.fingerprint) { throw 'The host driver changed during synchronization. VM startup refused.' }
        $guestReportDirectory=Join-Path $mount 'ProgramData\vmctl\gpu'
        $null=New-Item -ItemType Directory -Path $guestReportDirectory -Force
        $result=@{fingerprint=$Inventory.fingerprint;version=$Inventory.version;deviceId=$Inventory.deviceId;activeDiskPath=$leaf;copiedFiles=$copied;copiedBytes=$bytes;verifiedHashes=$true;copiedAt=[DateTimeOffset]::UtcNow.ToString('o');files=$manifest}
        Save-Json $result (Join-Path $guestReportDirectory 'driver-manifest.json')
        Save-Json $result $statePath
        return $result
    } finally {
        if ($accessAdded) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath ($mount+'\') -ErrorAction Continue }
        if ($mounted) { Dismount-VHD -Path $leaf -ErrorAction Stop }
        if (Test-Path -LiteralPath $mount) { Remove-Item -LiteralPath $mount -ErrorAction Continue }
    }
}
function Configure-Adapter([object]$Machine,[object]$Gpu,[int]$Share) {
    if ($Machine.State -ne 'Off') { throw 'GPU configuration requires an off VM.' }
    $adapters=@(Get-VMGpuPartitionAdapter -VM $Machine)
    if ($adapters.Count -gt 1 -or ($adapters.Count -eq 1 -and $adapters[0].InstancePath -ine $Gpu.Name)) { throw 'Existing GPU adapters do not match the selected GPU; refusing replacement.' }
    if ($adapters.Count -eq 0) { Add-VMGpuPartitionAdapter -VM $Machine -InstancePath $Gpu.Name }
    $budgets=@{VM=$Machine}
    foreach($resource in @('VRAM','Encode','Decode','Compute')) {
        $value=Get-VmctlGpuShare ([UInt64]$Gpu.('Total'+$resource)) $Share
        if ($value -eq 0) { throw "The GPU has no $resource resource budget." }
        foreach($bound in @('Min','Max','Optimal')) { $budgets[$bound+'Partition'+$resource]=$value }
    }
    Set-VMGpuPartitionAdapter @budgets
    Set-VMMemory -VM $Machine -DynamicMemoryEnabled $false
    Set-VM -VM $Machine -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 32GB -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
}
try {
    if ($VmId -eq [guid]::Empty) {
        if (-not $VmName) { throw 'A VM GUID or exact name is required.' }
        $matches=@(Get-VM -Name $VmName | Where-Object Name -ceq $VmName)
        if ($matches.Count -ne 1) { throw 'The VM name must resolve to exactly one VM.' }
        $VmId=$matches[0].Id; $id=$VmId.ToString()
        $folder=Join-Path $StateRoot $id
        $configurationPath=Join-Path $folder 'configuration.json'
        $statePath=Join-Path $folder 'driver-state.json'
        $taskName='vmctl-GPU-'+$id
    }
    $machine=Get-VM -Id $VmId
    if ($VmName -and $machine.Name -cne $VmName) { throw 'VM name and GUID differ.' }
    if ($machine.Generation -ne 2) { throw 'GPU automation requires a generation 2 VM.' }
    Protect-Folder $StateRoot
    Protect-Folder $folder
    if ($Mode -eq 'task-test') {
        # The scheduled worker takes the VM lock itself; never hold it while waiting.
        $report=@{mode=$Mode;vm=$machine.Name;vmId=$id;result=(Test-StartupTask)}
        $json=$report | ConvertTo-Json -Depth 12
        if ($ResponsePath) { [IO.File]::WriteAllText($ResponsePath,$json,(New-Object Text.UTF8Encoding($false))) }
        [Console]::Out.WriteLine($json)
        exit 0
    }
    $lockDeadline=(Get-Date).AddSeconds(120)
    do {
        try { $lock=[IO.File]::Open((Join-Path $folder 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) } catch { if ((Get-Date) -ge $lockDeadline) { throw 'GPU operation lock timeout.' }; Start-Sleep -Seconds 1 }
    } until ($lock)
    $config=$null
    if (Test-Path -LiteralPath $configurationPath) { $config=Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json }
    if ($Mode -notin @('setup','status') -and -not $config) { throw 'GPU automation is not configured for this VM.' }
    if ($config) {
        if ($config.vmId -ne $id -or $config.vmName -cne $machine.Name) { throw 'Stored GPU target identity no longer matches.' }
        if ($Mode -notin @('setup','status','remove') -and -not $config.enabled) { throw 'GPU automation is disabled for this VM.' }
        if ($Mode -ne 'setup') { $GpuName=$config.gpuName; $Percent=$config.percent }
    }
    if ($Mode -eq 'remove') {
        if ($machine.State -ne 'Off') { throw 'Removing GPU automation requires an off VM.' }
        Get-VMGpuPartitionAdapter -VM $machine | Remove-VMGpuPartitionAdapter -Confirm:$false
        Set-VM -VM $machine -GuestControlledCacheTypes $config.original.cacheTypes -LowMemoryMappedIoSpace $config.original.lowMmio -HighMemoryMappedIoSpace $config.original.highMmio -AutomaticStartAction $config.original.startAction -AutomaticStopAction $config.original.stopAction
        Set-VMMemory -VM $machine -DynamicMemoryEnabled $config.original.dynamicMemory
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        $config.enabled=$false
        Save-Json $config $configurationPath
        $report=@{mode=$Mode;vm=$machine.Name;vmId=$id;removed=$true;guestDriverFilesRetained=$true}
    } else {
        $device=@(Get-CimInstance Win32_VideoController | Where-Object Name -ceq $GpuName)
        if ($device.Count -ne 1 -or $device[0].Name -notmatch '^NVIDIA ') { throw 'Select exactly one supported NVIDIA GPU by its full name.' }
        $identity=$device[0].PNPDeviceID
        if ($config -and $config.deviceId -ine $identity) { throw 'The selected physical GPU identity changed. Reconfigure explicitly.' }
        $instancePrefix='\\?\'+$identity.Replace('\','#')+'#'
        $gpu=@(Get-VMHostPartitionableGpu | Where-Object { $_.Name.StartsWith($instancePrefix,[StringComparison]::OrdinalIgnoreCase) })
        if ($gpu.Count -ne 1) { throw 'The selected GPU is not uniquely partitionable.' }
        $inventory=Get-DriverInventory $identity
        if ($config -and $config.enabled -and $Mode -notin @('setup','status')) {
            $configuredAdapters=@(Get-VMGpuPartitionAdapter -VM $machine)
            if ($configuredAdapters.Count -ne 1 -or $configuredAdapters[0].InstancePath -ine $gpu[0].Name) { throw 'VM GPU configuration differs from the managed state, possibly after a checkpoint restore. Run gpu-setup explicitly.' }
        }
        $driverState=$null
        if (Test-Path -LiteralPath $statePath) { $driverState=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
        $needsSync=(-not $driverState -or $driverState.fingerprint -ne $inventory.fingerprint)
        $activePaths=@(Get-VMHardDiskDrive -VM $machine | Where-Object Path | Select-Object -ExpandProperty Path)
        if ($driverState -and ($driverState.PSObject.Properties.Name -notcontains 'activeDiskPath' -or $activePaths.Count -ne 1 -or $driverState.activeDiskPath -ine $activePaths[0])) { $needsSync=$true }
        $wasRunning=$machine.State -eq 'Running'
        $report=@{mode=$Mode;vm=$machine.Name;vmId=$id;gpu=$GpuName;percent=$Percent;hostDriver=$inventory.version;hostFingerprint=$inventory.fingerprint;needsSynchronization=$needsSync;state=$machine.State.ToString();synchronized=$false;task=$taskName;configured=[bool]$config}
        if ($Mode -eq 'setup') {
            if (@(Get-VMGpuPartitionAdapter -VM $machine).Count -gt 0 -and -not $config) { throw 'An unmanaged GPU adapter already exists.' }
            if (-not $config) {
                $config=[pscustomobject]@{vmId=$id;vmName=$machine.Name;gpuName=$GpuName;deviceId=$identity;percent=$Percent;enabled=$true;original=@{cacheTypes=$machine.GuestControlledCacheTypes;lowMmio=$machine.LowMemoryMappedIoSpace;highMmio=$machine.HighMemoryMappedIoSpace;startAction=$machine.AutomaticStartAction.ToString();stopAction=$machine.AutomaticStopAction.ToString();dynamicMemory=(Get-VMMemory -VM $machine).DynamicMemoryEnabled};createdAt=[DateTimeOffset]::UtcNow.ToString('o')}
            }
            if ($machine.State -eq 'Running') { Stop-VM -VM $machine -Confirm:$false }
            $deadline=(Get-Date).AddSeconds(120)
            do { $machine=Get-VM -Id $VmId; if ($machine.State -eq 'Off') { break }; if ((Get-Date) -ge $deadline) { throw 'Graceful shutdown timeout; no force stop performed.' }; Start-Sleep -Seconds 1 } while ($true)
            Configure-Adapter $machine $gpu[0] $Percent
            $config.percent=$Percent; $config.enabled=$true
            Save-Json $config $configurationPath
        }
        if ($Mode -in @('setup','sync','start','startup') -and $needsSync) {
            if ($machine.State -ne 'Off') { throw 'Driver synchronization is pending; running VM was left untouched. Use vmctl restart for a managed update.' }
            $report.driverCopy=Sync-OfflineDriver $inventory $machine
            $report.synchronized=$true; $report.needsSynchronization=$false
        }
        if ($Mode -eq 'setup') {
            $installed=Join-Path $env:ProgramFiles 'vmctl\gpu'
            Protect-Folder $installed
            $installedWorker=Join-Path $installed 'Invoke-GpuWorker.ps1'
            Copy-Item -LiteralPath $PSCommandPath -Destination $installedWorker -Force
            Copy-Item -LiteralPath $support -Destination (Join-Path $installed 'GpuSupport.psm1') -Force
            $windowsPs=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $action=New-ScheduledTaskAction -Execute $windowsPs -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$installedWorker+'" -Mode startup -VmId '+$id)
            $startup=New-ScheduledTaskTrigger -AtStartup
            $startup.Delay='PT45S'
            $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable
            $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
            $null=Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $startup -Settings $settings -Principal $principal -Force
            $report.configured=$true
        }
        if (($Mode -eq 'setup' -and $wasRunning) -or $Mode -in @('start','startup')) {
            $machine=Get-VM -Id $VmId
            if ($machine.State -eq 'Off') {
                if ($Mode -eq 'setup') {
                    $lock.Dispose(); $lock=$null
                    $report.startupTaskTest=Test-StartupTask
                } else { Start-VM -VM $machine -Confirm:$false }
            }
        }
        $machine=Get-VM -Id $VmId
        $report.state=$machine.State.ToString()
        $report.assigned=@(Get-VMGpuPartitionAdapter -VM $machine | Select-Object InstancePath,MinPartitionVRAM,MaxPartitionVRAM,OptimalPartitionVRAM,MinPartitionEncode,MaxPartitionEncode,OptimalPartitionEncode)
        $report.checkedAt=[DateTimeOffset]::UtcNow.ToString('o')
        $report.taskInfo=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Select-Object TaskName,State
    }
    Save-Json $report (Join-Path $folder 'last-operation.json')
    $json=$report | ConvertTo-Json -Depth 12
    if ($ResponsePath) { [IO.File]::WriteAllText($ResponsePath,$json,(New-Object Text.UTF8Encoding($false))) }
    [Console]::Out.WriteLine($json)
    exit 0
} catch {
    $failure=@{mode=$Mode;vmId=$id;error=$_.Exception.Message;at=[DateTimeOffset]::UtcNow.ToString('o')}
    if (Test-Path -LiteralPath $folder) { Save-Json $failure (Join-Path $folder 'last-error.json') }
    if ($ResponsePath) { $failure | ConvertTo-Json | Set-Content -LiteralPath $ResponsePath -Encoding utf8 }
    [Console]::Error.WriteLine($_.ToString())
    exit 1
} finally { if ($lock) { $lock.Dispose() } }
