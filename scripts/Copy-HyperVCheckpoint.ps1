#requires -Version 5.1
#requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$SourceName,[Parameter(Mandatory)][guid]$SourceId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$CloneName,
    [Parameter(Mandatory)][string]$Destination,[Parameter(Mandatory)][string]$SnapshotName)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
Import-Module Hyper-V
$source=Get-VM -Id $SourceId
if($source.Name -cne $SourceName -or $source.State -ne 'Off'){throw 'Clone requires the named source VM, verified GUID, and state Off.'}
if($source.Generation -ne 2){throw 'Checkpoint copy requires a generation 2 VM.'}
if(Get-VM -Name $CloneName -ErrorAction SilentlyContinue){throw 'Clone VM already exists; no replacement is allowed.'}
if(@(Get-VMGpuPartitionAdapter -VM $source).Count){throw 'Remove GPU-P before checkpoint cloning.'}
if(-not [IO.Path]::IsPathRooted($Destination) -or $Destination.StartsWith('\\')){throw 'An absolute local destination is required.'}
$destinationPath=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $destinationPath){throw 'Clone destination already exists; no replacement is allowed.'}
$snapshots=@(Get-VMSnapshot -VM $source | Where-Object Name -ceq $SnapshotName)
if($snapshots.Count -ne 1){throw 'Exactly one named source checkpoint is required.'}
$disks=@(Get-VMHardDiskDrive -VMSnapshot $snapshots[0] | Where-Object Path)
if($disks.Count -ne 1){throw 'Exactly one checkpoint disk is required.'}
$disk=Get-VHD -Path $disks[0].Path
if($disk.ParentPath -or $disk.VhdType -ne 'Dynamic'){throw 'Checkpoint disk must be a self-contained dynamic VHDX.'}
$networks=@(Get-VMNetworkAdapter -VM $source)
if($networks.Count -ne 1 -or -not $networks[0].SwitchName){throw 'Exactly one connected source network adapter is required.'}
$memory=Get-VMMemory -VM $source
$processor=Get-VMProcessor -VM $source
$firmware=Get-VMFirmware -VM $source
$null=New-Item -ItemType Directory -Path $destinationPath
$statePath=Join-Path $destinationPath 'clone-state.json'
function Save-CloneState([string]$Phase){
    @{phase=$Phase;source=$SourceName;sourceId=$SourceId.ToString();checkpoint=$SnapshotName;clone=$CloneName;destination=$destinationPath;at=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $statePath -Encoding utf8
}
try{
    Save-CloneState 'copying-disk'
    $diskFolder=Join-Path $destinationPath 'Virtual Hard Disks'
    $null=New-Item -ItemType Directory -Path $diskFolder
    $cloneDisk=Join-Path $diskFolder ($CloneName+'.vhdx')
    Copy-Item -LiteralPath $disk.Path -Destination $cloneDisk
    if((Get-Item -LiteralPath $cloneDisk).Length -ne (Get-Item -LiteralPath $disk.Path).Length){throw 'Cloned disk size mismatch.'}
    if((Get-VHD -Path $cloneDisk).ParentPath){throw 'Cloned disk must be independent.'}
    Save-CloneState 'creating-vm'
    $clone=New-VM -Name $CloneName -Generation 2 -MemoryStartupBytes $memory.Startup -VHDPath $cloneDisk -SwitchName $networks[0].SwitchName -Path $destinationPath
    Set-VMProcessor -VM $clone -Count $processor.Count
    Set-VMMemory -VM $clone -DynamicMemoryEnabled $memory.DynamicMemoryEnabled -StartupBytes $memory.Startup -MinimumBytes $memory.Minimum -MaximumBytes $memory.Maximum
    Set-VM -VM $clone -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Set-VMFirmware -VM $clone -EnableSecureBoot $firmware.SecureBoot -SecureBootTemplate $firmware.SecureBootTemplate -FirstBootDevice (Get-VMHardDiskDrive -VM $clone)
    Set-VMKeyProtector -VM $clone -NewLocalKeyProtector
    Enable-VMTPM -VM $clone
    Save-CloneState 'created'
    @{vm=$clone.Name;vmId=$clone.Id.ToString();sourceId=$SourceId.ToString();checkpointId=$snapshots[0].Id.ToString();checkpoint=$SnapshotName;disk=$cloneDisk;independent=$true;state=$clone.State.ToString();switch=$networks[0].SwitchName;memoryStartup=$memory.Startup;processors=$processor.Count;report=$statePath}|ConvertTo-Json -Depth 3
}catch{
    Save-CloneState 'failed'
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
