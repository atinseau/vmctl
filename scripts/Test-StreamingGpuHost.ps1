#requires -Version 5.1
param([Parameter(Mandatory)][string]$Vm)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
Import-Module Hyper-V
$target=Get-VM -Name $Vm -ErrorAction Stop
[pscustomobject]@{
    vm=$target.Name; vmId=$target.Id.ToString(); vmState=$target.State.ToString()
    generation=$target.Generation; automaticStartAction=$target.AutomaticStartAction.ToString()
    hostOs=(Get-CimInstance Win32_OperatingSystem | Select-Object Caption,BuildNumber,Version)
    gpus=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,PNPDeviceID)
    partitionable=@(Get-VMHostPartitionableGpu | Select-Object Name,ValidPartitionCounts,PartitionCount,TotalVRAM,TotalEncode,TotalDecode,TotalCompute)
    assigned=@(Get-VMGpuPartitionAdapter -VMName $Vm | Select-Object InstancePath,MinPartitionVRAM,MaxPartitionVRAM,OptimalPartitionVRAM,MinPartitionEncode,MaxPartitionEncode,OptimalPartitionEncode)
    network=@(Get-VMNetworkAdapter -VMName $Vm | Select-Object SwitchName,IPAddresses,MacAddress)
} | ConvertTo-Json -Depth 7
