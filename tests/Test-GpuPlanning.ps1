#requires -Version 7.2
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\GpuSupport.psm1') -Force
$passed=0
function Assert-Gpu([bool]$Condition,[string]$Label) { if(-not $Condition){throw $Label}; $script:passed++; Write-Output "OK: $Label" }
Assert-Gpu ((Get-VmctlGpuShare 1000000000 25) -eq 250000000) 'Quarter VRAM quota'
Assert-Gpu ((Get-VmctlGpuShare ([UInt64]::MaxValue) 25) -eq [UInt64]4611686018427387903) 'UInt64 maximum encode quota without double rounding'
Assert-Gpu ((Get-VmctlGpuShare ([UInt64]::MaxValue) 100) -eq [UInt64]::MaxValue) '100 percent quota without overflow'
Assert-Gpu ((Get-VmctlGpuShare 7 25) -eq 1) 'Fractional resource quota is floored'
foreach($percentage in @(0,101)) { $rejected=$false; try{ Get-VmctlGpuShare 100 $percentage }catch{$rejected=$true}; Assert-Gpu $rejected "Invalid percentage $percentage refused" }
$one=Get-VmctlGpuFingerprint @('GPU-Pci-identity','driver-v1','nv.dll|10|100')
$two=Get-VmctlGpuFingerprint @('GPU-Pci-identity','driver-v2','nv.dll|10|100')
Assert-Gpu ($one -ne $two) 'Driver version change triggers synchronization'
Assert-Gpu ($one -eq (Get-VmctlGpuFingerprint @('GPU-Pci-identity','driver-v1','nv.dll|10|100'))) 'Unchanged inventory remains stable'
Assert-Gpu ($one -ne (Get-VmctlGpuFingerprint @('GPU-Pci-identity','driver-v1','nv.dll|20|100'))) 'Driver file size change triggers synchronization'
foreach($path in @('C:\Windows\System32\nv.dll','..\Windows\System32\nv.dll','Windows\System32\..\..\host.dll','Windows\System32\nv.dll:stream','Windows\notallowed\file.dll')) {
 $rejected=$false; try{Assert-VmctlGpuRelativePath $path}catch{$rejected=$true}; Assert-Gpu $rejected "Unsafe destination refused: $path"
}
foreach($path in @('Windows\System32\nvEncodeAPI64.dll','Windows\SysWOW64\nvapi.dll','Windows\System32\HostDriverStore\FileRepository\nv.inf\nvlddmkm.sys')) { Assert-VmctlGpuRelativePath $path; Assert-Gpu $true "Allowed driver destination: $path" }
Write-Output "$passed GPU planning checks passed; no Hyper-V or disk mutation."
