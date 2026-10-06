#requires -Version 7.2
Set-StrictMode -Version Latest
function Get-VmctlMoonlightHost {
    param([string]$VmName,[string]$Address,[string]$ServerUuid,[string]$RegistrySubKey='Software\Moonlight Game Streaming Project\Moonlight')
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistrySubKey+'\hosts')
    if(-not $key){return}
    try {
        foreach($name in $key.GetSubKeyNames()) {
            $hostKey=$key.OpenSubKey($name)
            try {
                $uuid=[string]$hostKey.GetValue('uuid','')
                $hostname=[string]$hostKey.GetValue('hostname','')
                $addresses=@('localaddress','manualaddress','remoteaddress')|ForEach-Object {[string]$hostKey.GetValue($_,'')}
                if (($ServerUuid -and $uuid -ieq $ServerUuid) -or (-not $ServerUuid -and (($VmName -and $hostname -ieq $VmName) -or ($Address -and $Address -in $addresses)))) {
                    [pscustomobject]@{key=$name;uuid=$uuid;hostname=$hostname;addresses=$addresses}
                }
            } finally {$hostKey.Dispose()}
        }
    } finally {$key.Dispose()}
}
function Get-VmctlRegistrySnapshot {
    param([Microsoft.Win32.RegistryKey]$Key)
    $values=@{}; $children=@{}
    foreach($name in $Key.GetValueNames()) {$values[$name]=@{value=$Key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames);kind=$Key.GetValueKind($name)}}
    foreach($name in $Key.GetSubKeyNames()){$child=$Key.OpenSubKey($name);try{$children[$name]=Get-VmctlRegistrySnapshot $child}finally{$child.Dispose()}}
    return @{values=$values;children=$children}
}
function Set-VmctlRegistrySnapshot {
    param([Microsoft.Win32.RegistryKey]$Key,[hashtable]$Snapshot)
    foreach($entry in $Snapshot.values.GetEnumerator()){$Key.SetValue($entry.Key,$entry.Value.value,$entry.Value.kind)}
    foreach($entry in $Snapshot.children.GetEnumerator()){$child=$Key.CreateSubKey($entry.Key);try{Set-VmctlRegistrySnapshot $child $entry.Value}finally{$child.Dispose()}}
}
function Remove-VmctlMoonlightHost {
    param([Parameter(Mandatory)][string]$ServerUuid,[string]$RegistrySubKey='Software\Moonlight Game Streaming Project\Moonlight')
    if($RegistrySubKey -ieq 'Software\Moonlight Game Streaming Project\Moonlight' -and (Get-Process Moonlight -ErrorAction SilentlyContinue)){throw 'Close Moonlight before modifying its saved hosts.'}
    $root=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistrySubKey,$true)
    if(-not $root){return [pscustomobject]@{removed=0;uuid=$ServerUuid}}
    $removed=0
    try {
        # Qt can restore hostsbackup on startup; remove the target from both arrays.
        foreach($array in @('hosts','hostsbackup')) {
            $key=$root.OpenSubKey($array)
            if(-not $key){continue}
            $snapshots=@(); $matched=0
            try {
                foreach($name in @($key.GetSubKeyNames() | Sort-Object {[int]$_})) {
                    if($name -notmatch '^\d+$'){throw 'Unexpected Moonlight host array layout.'}
                    $child=$key.OpenSubKey($name)
                    try {if([string]$child.GetValue('uuid','') -ieq $ServerUuid){$matched++}else{$snapshots+=,(Get-VmctlRegistrySnapshot $child)}}finally{$child.Dispose()}
                }
            } finally {$key.Dispose()}
            if(-not $matched){continue}
            $root.DeleteSubKeyTree($array)
            $replacement=$root.CreateSubKey($array)
            try {
                $replacement.SetValue('size',$snapshots.Count,[Microsoft.Win32.RegistryValueKind]::DWord)
                for($i=0;$i -lt $snapshots.Count;$i++){$child=$replacement.CreateSubKey([string]($i+1));try{Set-VmctlRegistrySnapshot $child $snapshots[$i]}finally{$child.Dispose()}}
            }finally{$replacement.Dispose()}
            if($array -eq 'hosts'){$removed=$matched}
        }
        $root.Flush()
    } finally {$root.Dispose()}
    [pscustomobject]@{removed=$removed;uuid=$ServerUuid}
}
function Get-VmctlStreamEvidence {
    param([string]$WindowTitle,[string]$HostName,[string]$Log)
    $windowMatches=($WindowTitle -ieq ($HostName+' - Moonlight'))
    # A GUI process can return to its launcher after losing a stream, and the
    # same log can contain several attempts. Inspect only the latest attempt.
    $streamStart=$Log.LastIndexOf('Starting video stream...',[StringComparison]::Ordinal)
    $currentLog=if($streamStart -ge 0){$Log.Substring($streamStart)}else{$Log}
    $videoReceived=($currentLog -match 'Received first video packet after \d+ ms')
    $decoderChosen=($currentLog -match 'video decoder chosen')
    $failures=[regex]::Matches($currentLog,'(?m)^.*(?:Connection terminated:\s*(-?\d+)|Control stream received unexpected disconnect event|Quit event received).*$')
    $terminations=[regex]::Matches($currentLog,'(?m)^.*Connection terminated:\s*(-?\d+).*$')
    $failure=if($terminations.Count){$terminations[$terminations.Count-1].Value.Trim()}elseif($failures.Count){$failures[$failures.Count-1].Value.Trim()}else{''}
    [pscustomobject]@{windowMatches=$windowMatches;videoReceived=$videoReceived;decoderChosen=$decoderChosen;disconnected=($failures.Count -gt 0);failure=$failure;ready=($windowMatches -and $videoReceived -and $decoderChosen -and -not $failures.Count)}
}
function Test-VmctlStreamingSessionFreshness {
    param([Parameter(Mandatory)][object]$Expires,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    # ConvertFrom-Json may already return a DateTime. Parsing its localized
    # string can swap the month and day (for example 06/10 in French).
    $Now -lt [DateTimeOffset]$Expires
}
Export-ModuleMember -Function Get-VmctlMoonlightHost,Remove-VmctlMoonlightHost,Get-VmctlStreamEvidence,Test-VmctlStreamingSessionFreshness
