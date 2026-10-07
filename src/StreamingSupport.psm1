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
    if($RegistrySubKey -ieq 'Software\Moonlight Game Streaming Project\Moonlight' -and (Get-Process Moonlight -ErrorAction SilentlyContinue | Where-Object {-not $_.HasExited})){throw 'Close Moonlight before modifying its saved hosts.'}
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
    param([string]$WindowTitle,[string]$HostName,[string]$Log,
        [string]$ProcessCommandLine,[string]$ServerUuid)
    $windowMatches=($WindowTitle -ieq ($HostName+' - Moonlight'))
    if($ServerUuid){
        # Discovery may rename the host after launch. The process command line
        # binds this window to the paired UUID; the cached label cannot do so.
        $windowMatches=($WindowTitle -match '^.+ - Moonlight$' -and (Get-VmctlMoonlightProcessRole -CommandLine $ProcessCommandLine -ServerUuid $ServerUuid) -eq 'stream')
    }
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
function Get-VmctlMoonlightProcessRole {
    param([string]$CommandLine,[Parameter(Mandatory)][string]$ServerUuid)
    $command=[regex]::Match($CommandLine,'(?:^|\s)(stream|list|quit|pair)\s+"?([0-9a-f-]{36})"?(?:\s|$)',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if(-not $command.Success){return 'unknown'}
    if($command.Groups[1].Value -ine 'stream'){return 'helper'}
    if($command.Groups[2].Value -ieq $ServerUuid){return 'stream'}
    return 'other-stream'
}
function Test-VmctlStreamingSessionFreshness {
    param([Parameter(Mandatory)][object]$Expires,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    # ConvertFrom-Json may already return a DateTime. Parsing its localized
    # string can swap the month and day (for example 06/10 in French).
    $Now -lt [DateTimeOffset]$Expires
}
function Get-VmctlCapturedResolution {
    param([string[]]$Lines,[datetime]$NotBefore)
    $latest=''
    foreach($line in $Lines){
        $match=[regex]::Match($line,'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)\].*Desktop resolution \[(\d+x\d+)\]')
        if($match.Success -and [datetime]::ParseExact($match.Groups[1].Value,'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture) -ge $NotBefore){$latest=$match.Groups[2].Value}
    }
    $latest
}
function Initialize-VmctlPrimaryMonitorApi {
    if ('VmctlPrimaryMonitor' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class VmctlPrimaryMonitor {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X,Y; }
    [StructLayout(LayoutKind.Sequential)] struct MonitorInfo { public int Size; public Rect Monitor,Work; public uint Flags; }
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point point,uint flags);
    [DllImport("user32.dll",SetLastError=true)] static extern bool GetMonitorInfo(IntPtr monitor,ref MonitorInfo info);
    [DllImport("user32.dll",SetLastError=true)] static extern bool SetWindowPos(IntPtr window,IntPtr after,int x,int y,int w,int h,uint flags);
    public static Rect Bounds() {
        // Windows places the primary monitor at (0,0). Per-monitor DPI awareness
        // avoids mistaking logical pixels (for example 2560) for native 4K pixels.
        IntPtr previous=SetThreadDpiAwarenessContext(new IntPtr(-4));
        if(previous==IntPtr.Zero) throw new Win32Exception();
        try {
            MonitorInfo info=new MonitorInfo(); info.Size=Marshal.SizeOf(info);
            if(!GetMonitorInfo(MonitorFromPoint(new Point(),1),ref info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return info.Monitor;
        } finally { SetThreadDpiAwarenessContext(previous); }
    }
    public static void Place(IntPtr window) {
        Rect bounds=Bounds();
        IntPtr previous=SetThreadDpiAwarenessContext(new IntPtr(-4));
        if(previous==IntPtr.Zero) throw new Win32Exception();
        try {
            // A normal, non-topmost borderless window keeps host Alt+Tab usable.
            if(!SetWindowPos(window,IntPtr.Zero,bounds.Left,bounds.Top,bounds.Right-bounds.Left,bounds.Bottom-bounds.Top,0x214))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { SetThreadDpiAwarenessContext(previous); }
    }
}
'@
}
function Get-VmctlPrimaryMonitor {
    Initialize-VmctlPrimaryMonitorApi
    $bounds=[VmctlPrimaryMonitor]::Bounds()
    [pscustomobject]@{width=$bounds.Right-$bounds.Left;height=$bounds.Bottom-$bounds.Top}
}
function Set-VmctlStreamOnPrimaryMonitor {
    param([Parameter(Mandatory)][IntPtr]$WindowHandle)
    Initialize-VmctlPrimaryMonitorApi
    [VmctlPrimaryMonitor]::Place($WindowHandle)
}
function New-VmctlStreamingDisplayPlan {
    param([ValidateSet('windowed','fullscreen')][string]$Mode='windowed',
        [int]$SavedWidth,[int]$SavedHeight,[int]$PrimaryWidth,[int]$PrimaryHeight,[bool]$SavedAbsoluteMouse)
    $width=if($Mode -eq 'fullscreen'){$PrimaryWidth}else{$SavedWidth}
    $height=if($Mode -eq 'fullscreen'){$PrimaryHeight}else{$SavedHeight}
    if($width -lt 320 -or $width -gt 16384 -or $height -lt 240 -or $height -gt 16384){throw 'Streaming dimensions are invalid.'}
    [pscustomobject]@{mode=$Mode;width=$width;height=$height;resolution="${width}x${height}";displayMode=$(if($Mode -eq 'fullscreen'){'fullscreen'}else{'windowed'});absoluteMouse=($Mode -ne 'fullscreen' -and $SavedAbsoluteMouse);captureSystemKeys=$(if($Mode -eq 'fullscreen'){'always'}else{'preferences'})}
}
function ConvertTo-VmctlStreamingErrorText {
    param([AllowEmptyString()][string]$Text)
    ([regex]::Replace($Text,'\x1B\[[0-?]*[ -/]*[@-~]','')).Trim()
}
function Select-VmctlApolloAddress {
    param([string[]]$GuestAddresses,[string]$CachedAddress)
    $current=@($GuestAddresses | Where-Object {
        $parsed=$null
        [Net.IPAddress]::TryParse($_,[ref]$parsed) -and $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_ -notmatch '^(127\.|169\.254\.|0\.)'
    } | Select-Object -Unique)
    if($current.Count){
        if($CachedAddress -in $current){return $CachedAddress}
        return $current[0]
    }
    return $CachedAddress
}
function Invoke-VmctlStreamingStatusRead {
    # Only callers performing a read may use this retry policy. Configuration
    # writes and Moonlight launch/quit operations must never be replayed here.
    param([Parameter(Mandatory)][scriptblock]$Read,
        [ValidateRange(1,120)][int]$BudgetSeconds=60,
        [ValidateRange(0,5)][int]$RetryDelaySeconds=1)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    for($attempt=1;$attempt -le 3;$attempt++){
        $remainingSeconds=$BudgetSeconds-$clock.Elapsed.TotalSeconds
        if($remainingSeconds -le 0){break}
        # The process API takes whole seconds; round only its final fraction.
        $remaining=[int][Math]::Ceiling($remainingSeconds)
        $result=& $Read ([Math]::Min(45,$remaining))
        if($result.ExitCode -eq 0){return $result}
        # The marker comes from a typed HTTP timeout, not authentication,
        # certificate failures or invalid settings. 124 is the child deadline.
        if($result.ExitCode -ne 124 -and $result.Stderr -notmatch '(?m)^APOLLO_TIMEOUT:'){return $result}
        if($attempt -lt 3 -and $clock.Elapsed.TotalSeconds+$RetryDelaySeconds -lt $BudgetSeconds){
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    $details=if($result){ConvertTo-VmctlStreamingErrorText $result.Stderr}else{'Aucune requête terminée.'}
    [pscustomobject]@{ExitCode=124;Stdout='';Stderr="Apollo ne répond pas après plusieurs tentatives (maximum ${BudgetSeconds}s).`nDernière erreur : $details"}
}
function Test-VmctlMoonlightCertificateRepair {
    # GuestPem must come from authenticated PowerShell Direct to the bound VM.
    # A valid existing pin is never silently replaced.
    param([AllowNull()][AllowEmptyString()][object]$CachedPem,[Parameter(Mandatory)][string]$GuestPem)
    $CachedPem=if($CachedPem -is [byte[]]){[Text.Encoding]::UTF8.GetString($CachedPem)}else{[string]$CachedPem}
    $guestCertificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($GuestPem)
    $cachedCertificate=$null
    try {
        if($CachedPem.StartsWith('@ByteArray(') -and $CachedPem.EndsWith(')')){$CachedPem=$CachedPem.Substring(11,$CachedPem.Length-12)}
        $CachedPem=$CachedPem.Replace('\\n',"`n").Replace('\n',"`n").Replace('\\r',"`r").Replace('\r',"`r")
        try {$cachedCertificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($CachedPem)}
        catch [ArgumentException] {} catch [Security.Cryptography.CryptographicException] {}
        if(-not $cachedCertificate){return $true}
        if($cachedCertificate.GetCertHashString() -ne $guestCertificate.GetCertHashString()){
            throw 'Paired certificate differs from the authenticated guest; no replacement performed.'
        }
        return $false
    } finally {
        if($cachedCertificate){$cachedCertificate.Dispose()}
        $guestCertificate.Dispose()
    }
}
Export-ModuleMember -Function Get-VmctlMoonlightHost,Remove-VmctlMoonlightHost,Get-VmctlStreamEvidence,Get-VmctlMoonlightProcessRole,Test-VmctlStreamingSessionFreshness,Get-VmctlPrimaryMonitor,Set-VmctlStreamOnPrimaryMonitor,New-VmctlStreamingDisplayPlan,Get-VmctlCapturedResolution,Invoke-VmctlStreamingStatusRead,ConvertTo-VmctlStreamingErrorText,Select-VmctlApolloAddress,Test-VmctlMoonlightCertificateRepair
