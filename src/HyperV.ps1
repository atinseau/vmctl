#requires -Version 7.2
function Invoke-VmctlHyperV {
    param([hashtable]$Target, [ValidateSet('checkpoint', 'start', 'stop', 'restart', 'storage', 'compact')][string]$Action,
        [string]$Name, [switch]$RemoveCheckpoints, [switch]$DisableAutomaticCheckpoints, [int]$TimeoutSeconds = 120)
    if (-not $IsWindows -or $Target.hypervisor -ne 'hyperv' -or -not $Target.vmName) {
        throw 'Cette action exige un hote Windows et une cible avec hypervisor=hyperv et vmName.'
    }
    $vmName = [string]$Target.vmName
    $encodedVm = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($vmName))
    $encodedName = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Name))
    $encodedId = if ($Target.ContainsKey('vmId')) { [string]$Target.vmId } else { '' }
    if ($encodedId) { $encodedId = ([Guid]::Parse($encodedId)).ToString() }
    if ($RemoveCheckpoints -and $Action -ne 'compact') { throw '-RemoveCheckpoints exige compact.' }
    if ($DisableAutomaticCheckpoints -and $Action -notin @('compact','checkpoint')) { throw '-DisableAutomaticCheckpoints exige compact ou checkpoint.' }
    # Windows PowerShell loads the native Hyper-V module without a compatibility proxy.
    $script = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
    Import-Module Hyper-V
    $vmctlName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__VM__'))
    $vmctlCheckpoint = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__NAME__'))
    $vmctlVm = Get-VM -Name $vmctlName | Where-Object { $_.Name -eq $vmctlName }
    if (@($vmctlVm).Count -ne 1) { throw 'La cible Hyper-V doit identifier exactement une VM.' }
    if ('__ID__' -and $vmctlVm.Id.ToString() -ine '__ID__') { throw 'Le GUID de la VM a change ; operation refusee.' }
    if ('__ACTION__' -in @('storage','compact')) {
        if ('__ACTION__' -eq 'compact' -and $vmctlVm.State -ne 'Off') { throw 'compact exige une VM arretee. Utilisez vmctl stop au prealable.' }
        $removed=@()
        if ('__ACTION__' -eq 'compact' -and '__REMOVE__' -eq 'True') {
            $snapshots=@(Get-VMSnapshot -VM $vmctlVm)
            $removed=@($snapshots | ForEach-Object {$_.Name})
            if($snapshots.Count -gt 0){$snapshots | Remove-VMSnapshot -Confirm:$false}
            $mergeDeadline=[DateTime]::UtcNow.AddSeconds(__TIMEOUT__ - 30)
            do {
                $vmctlVm=Get-VM -Id $vmctlVm.Id
                $remaining=@(Get-VMSnapshot -VM $vmctlVm)
                $pendingMerge=$remaining.Count -gt 0
                $mergeDrives=@(Get-VMHardDiskDrive -VM $vmctlVm | Where-Object Path)
                if($mergeDrives.Count -eq 0){ $pendingMerge=$true }
                foreach($drive in $mergeDrives) {
                    # VM configuration can briefly refer to an AVHDX already consumed by the merge.
                    try {
                        if(-not(Test-Path -LiteralPath $drive.Path)){ $pendingMerge=$true; continue }
                        if((Get-VHD -Path $drive.Path).ParentPath){ $pendingMerge=$true }
                    } catch { $pendingMerge=$true }
                }
                if(-not $pendingMerge){break}
                if([DateTime]::UtcNow -ge $mergeDeadline){throw 'Fusion non terminee dans le delai. Inspecter storage avant toute reprise.'}
                Start-Sleep -Seconds 2
            } while($true)
        }
        if ('__ACTION__' -eq 'compact' -and '__NOAUTO__' -eq 'True') {
            Set-VM -VM $vmctlVm -AutomaticCheckpointsEnabled $false
            $vmctlVm=Get-VM -Id $vmctlVm.Id
        }
        $disks=@(Get-VMHardDiskDrive -VM $vmctlVm | Where-Object Path)
        if ($disks.Count -eq 0) { throw 'Aucun disque dur attache a cette VM.' }
        $reports=@(foreach($disk in $disks) {
            $leaf=[IO.Path]::GetFullPath($disk.Path)
            $before=Get-VHD -Path $leaf
            if ('__ACTION__' -eq 'compact') {
                if ($before.VhdType -notin @('Dynamic','Differencing')) { throw 'Seuls les disques dynamiques ou differentiels peuvent etre compactes.' }
                if ($before.Attached) { throw 'Disque encore attache : compaction refusee.' }
                $mounted=$false
                try {
                    $null=Mount-VHD -Path $leaf -ReadOnly -NoDriveLetter -Passthru
                    $mounted=$true
                    Optimize-VHD -Path $leaf -Mode Retrim -Confirm:$false
                    Optimize-VHD -Path $leaf -Mode Full -Confirm:$false
                } finally { if($mounted){ Dismount-VHD -Path $leaf -Confirm:$false } }
            }
            $after=Get-VHD -Path $leaf
            $chain=@(); $seen=@{}; $current=$leaf
            while($current) {
                $current=[IO.Path]::GetFullPath($current)
                if($seen.ContainsKey($current)){throw 'Cycle dans la chaine VHD.'}
                $seen[$current]=$true
                $vhd=Get-VHD -Path $current
                $chain += [pscustomobject]@{path=$current;type=$vhd.VhdType.ToString();fileBytes=$vhd.FileSize;virtualBytes=$vhd.Size}
                $current=$vhd.ParentPath
            }
            [pscustomobject]@{activeDisk=$leaf;beforeBytes=$before.FileSize;afterBytes=$after.FileSize;reclaimedBytes=($before.FileSize-$after.FileSize);chain=$chain;chainBytes=($chain | Measure-Object fileBytes -Sum).Sum}
        })
        [pscustomobject]@{vm=$vmctlVm.Name;vmId=$vmctlVm.Id.ToString();state=$vmctlVm.State.ToString();action='__ACTION__';removedCheckpoints=$removed;automaticCheckpoints=$vmctlVm.AutomaticCheckpointsEnabled;checkpoints=@(Get-VMSnapshot -VM $vmctlVm | ForEach-Object {$_.Name});disks=$reports} | ConvertTo-Json -Depth 6
        exit 0
    }
      switch ('__ACTION__') {
        'checkpoint' {
            if ('__NOAUTO__' -eq 'True') { Set-VM -VM $vmctlVm -AutomaticCheckpointsEnabled $false }
            Checkpoint-VM -VM $vmctlVm -SnapshotName $vmctlCheckpoint -Confirm:$false
        }
          'start' {
              $gpuConfig=Join-Path $env:ProgramData ('vmctl\gpu\'+$vmctlVm.Id.ToString()+'\configuration.json')
              if ((Test-Path -LiteralPath $gpuConfig) -and (Get-Content -LiteralPath $gpuConfig -Raw | ConvertFrom-Json).enabled) {
                  & (Join-Path $env:ProgramFiles 'vmctl\gpu\Invoke-GpuWorker.ps1') -VmId $vmctlVm.Id -Mode start
                  exit $LASTEXITCODE
              }
              Start-VM -VM $vmctlVm -Confirm:$false
          }
        'stop' { Stop-VM -VM $vmctlVm -Confirm:$false }
        'restart' {
            if ($vmctlVm.State -ne 'Running') { throw 'La VM doit etre en cours pour restart.' }
            Stop-VM -VM $vmctlVm -Confirm:$false
            do {
                Start-Sleep -Milliseconds 500
                $vmctlVm = Get-VM -Id $vmctlVm.Id
            } while ($vmctlVm.State -ne 'Off')
              $gpuConfig=Join-Path $env:ProgramData ('vmctl\gpu\'+$vmctlVm.Id.ToString()+'\configuration.json')
              if ((Test-Path -LiteralPath $gpuConfig) -and (Get-Content -LiteralPath $gpuConfig -Raw | ConvertFrom-Json).enabled) {
                  & (Join-Path $env:ProgramFiles 'vmctl\gpu\Invoke-GpuWorker.ps1') -VmId $vmctlVm.Id -Mode start
                  exit $LASTEXITCODE
              }
              Start-VM -VM $vmctlVm -Confirm:$false
        }
    }
    Get-VM -Id $vmctlVm.Id | Select-Object Name, State | ConvertTo-Json -Compress
    exit 0
} catch { [Console]::Error.WriteLine($_.ToString()); exit 1 }
'@
    $script = $script.Replace('__VM__', $encodedVm).Replace('__NAME__', $encodedName).Replace('__ACTION__', $Action).Replace('__ID__', $encodedId)
    $script = $script.Replace('__REMOVE__', $RemoveCheckpoints.ToString()).Replace('__NOAUTO__', $DisableAutomaticCheckpoints.ToString()).Replace('__TIMEOUT__', ([Math]::Max(60,$TimeoutSeconds)).ToString())
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $exe = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    return Invoke-VmctlProcess $exe @('-NoLogo', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', $encoded) -TimeoutSeconds $TimeoutSeconds
}
