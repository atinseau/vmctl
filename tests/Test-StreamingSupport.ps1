#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../src/StreamingSupport.psm1') -Force
$fixture='Software\vmctl-tests\'+[guid]::NewGuid().ToString('N')
$uuids=@([guid]::NewGuid().ToString(),[guid]::NewGuid().ToString(),[guid]::NewGuid().ToString())
$passed=0
function Assert-That([bool]$Condition,[string]$Label) {
    if(-not $Condition){throw "FAIL: $Label"}
    $script:passed++; Write-Output "OK: $Label"
}
try {
    $realLog="FFmpeg-based video decoder chosen`nReceived first video packet after 300 ms"
    Assert-That (Get-VmctlStreamEvidence 'win-vm - Moonlight' 'win-vm' $realLog).ready 'Window and real video reception prove readiness'
    Assert-That (-not (Get-VmctlStreamEvidence 'Moonlight' 'win-vm' $realLog).ready) 'Launcher window does not prove stream readiness'
    Assert-That (-not (Get-VmctlStreamEvidence 'other-vm - Moonlight' 'win-vm' $realLog).ready) 'Another VM window is rejected'
    Assert-That (-not (Get-VmctlStreamEvidence 'win-vm - Moonlight' 'win-vm' 'Test decode successful').ready) 'Decoder self-test does not prove reception'
    Assert-That (-not (Get-VmctlStreamEvidence 'win-vm - Moonlight' 'win-vm' 'FFmpeg-based video decoder chosen').ready) 'Configured decoder without packets is not ready'
    Assert-That (-not (Get-VmctlStreamEvidence 'win-vm - Moonlight' 'win-vm' 'Received first video packet after 300 ms').ready) 'Packets without a chosen decoder are not ready'
    $lostLog=$realLog+"`nControl stream received unexpected disconnect event`nConnection terminated: -1`nQuit event received"
    $lost=Get-VmctlStreamEvidence 'win-vm - Moonlight' 'win-vm' $lostLog
    Assert-That (-not $lost.ready -and $lost.disconnected -and $lost.failure -match 'Connection terminated: -1') 'Disconnect after first packets is rejected with its error code'
    Assert-That (-not (Get-VmctlStreamEvidence 'win-vm - Moonlight' 'win-vm' ($realLog+"`nQuit event received")).ready) 'A closed stream is not ready even if the GUI still exists'
    Assert-That (-not (Get-VmctlStreamEvidence 'win-vm - Moonlight' 'win-vm' ($realLog+"`nStarting video stream...")).ready) 'Old packets cannot validate a new stream attempt'
    Assert-That (Get-VmctlStreamEvidence 'win-vm - Moonlight' 'win-vm' ($lostLog+"`nStarting video stream...`n"+$realLog)).ready 'A new receiving attempt can recover from an earlier disconnect'
    $now=[DateTimeOffset]'2026-10-06T09:00:00Z'
    $parsed='{ "expires": "2026-10-06T10:00:00Z" }'|ConvertFrom-Json
    Assert-That (Test-VmctlStreamingSessionFreshness -Expires $parsed.expires -Now $now) 'JSON dates retain October instead of becoming June'
    Assert-That (Test-VmctlStreamingSessionFreshness -Expires '2026-10-06T12:00:00+02:00' -Now $now) 'Offset string session expiry is accepted'
    Assert-That (-not (Test-VmctlStreamingSessionFreshness -Expires '2026-10-06T08:00:00Z' -Now $now)) 'Expired session is rejected'
    $root=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fixture)
    try {
        $root.SetValue('certificate','fixture-client-certificate')
        $root.SetValue('key','fixture-client-key')
        $root.SetValue('fps',120,[Microsoft.Win32.RegistryValueKind]::DWord)
        foreach($array in @('hosts','hostsbackup')) {
            $arrayKey=$root.CreateSubKey($array)
            try {
                $arrayKey.SetValue('size',3,[Microsoft.Win32.RegistryValueKind]::DWord)
                for($i=0;$i -lt 3;$i++) {
                    $key=$arrayKey.CreateSubKey([string]($i+1))
                    try {
                        $key.SetValue('uuid',$uuids[$i])
                        $key.SetValue('hostname',$(if($i -eq 2){'other-vm'}else{'windows-name'}))
                        $key.SetValue('localaddress',"192.0.2.$($i+1)")
                        $key.SetValue('srvcert',[byte[]]@(1,2,$i),[Microsoft.Win32.RegistryValueKind]::Binary)
                        $app=$key.CreateSubKey('apps\1')
                        try {$app.SetValue('name',"desktop-$i");$app.SetValue('id',100+$i,[Microsoft.Win32.RegistryValueKind]::DWord)} finally {$app.Dispose()}
                    } finally {$key.Dispose()}
                }
            } finally {$arrayKey.Dispose()}
        }
    } finally {$root.Dispose()}
    Assert-That (@(Get-VmctlMoonlightHost -VmName 'windows-name' -RegistrySubKey $fixture).Count -eq 2) 'Duplicate hostnames remain ambiguous'
    $found=@(Get-VmctlMoonlightHost -Address '192.0.2.2' -RegistrySubKey $fixture)
    Assert-That ($found.Count -eq 1 -and $found[0].uuid -eq $uuids[1]) 'Address identifies the requested host'
    $found=@(Get-VmctlMoonlightHost -VmName 'different-hyperv-name' -ServerUuid $uuids[1] -RegistrySubKey $fixture)
    Assert-That ($found.Count -eq 1 -and $found[0].hostname -eq 'windows-name') 'UUID works when Hyper-V and Windows names differ'
    $result=Remove-VmctlMoonlightHost -ServerUuid $uuids[1] -RegistrySubKey $fixture
    Assert-That ($result.removed -eq 1) 'Only the requested host is removed'
    foreach($array in @('hosts','hostsbackup')) {
        $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fixture+'\'+$array)
        try {
            Assert-That ($key.GetValue('size') -eq 2 -and ($key.GetSubKeyNames() -join ',') -eq '1,2') "$array array is repacked"
            $first=$key.OpenSubKey('1');$second=$key.OpenSubKey('2')
            try {
                Assert-That ($first.GetValue('uuid') -eq $uuids[0] -and $second.GetValue('uuid') -eq $uuids[2]) "$array preserves other hosts"
                Assert-That ($second.GetValueKind('srvcert') -eq [Microsoft.Win32.RegistryValueKind]::Binary -and ($second.GetValue('srvcert') -join ',') -eq '1,2,2') "$array preserves binary certificates"
                $app=$second.OpenSubKey('apps\1')
                try {Assert-That ($app.GetValue('name') -eq 'desktop-2' -and $app.GetValueKind('id') -eq [Microsoft.Win32.RegistryValueKind]::DWord) "$array preserves nested application data"} finally {$app.Dispose()}
            } finally {$first.Dispose();$second.Dispose()}
        } finally {$key.Dispose()}
    }
    $root=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($fixture)
    try {
        Assert-That ($root.GetValue('certificate') -eq 'fixture-client-certificate' -and $root.GetValue('key') -eq 'fixture-client-key') 'Client identity is preserved'
        Assert-That ($root.GetValue('fps') -eq 120) 'Streaming preferences are preserved'
    } finally {$root.Dispose()}
    $result=Remove-VmctlMoonlightHost -ServerUuid $uuids[1] -RegistrySubKey $fixture
    Assert-That ($result.removed -eq 0) 'Repeated removal is idempotent'
    Assert-That (@(Get-VmctlMoonlightHost -ServerUuid $uuids[1] -RegistrySubKey $fixture).Count -eq 0) 'Removed server is no longer discoverable in saved hosts'
    Write-Output "$passed tests passed. Only an isolated HKCU fixture was modified."
} finally {
    if($fixture -notmatch '^Software\\vmctl-tests\\[a-f0-9]{32}$'){throw 'Unsafe test cleanup path.'}
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($fixture,$false)
}
