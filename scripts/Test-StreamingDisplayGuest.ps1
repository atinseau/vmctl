#requires -Version 5.1
# Read-only guest diagnosis; run through vmctl run with an administrator credential.
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VmctlConsoleSession {
    [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool WTSQuerySessionInformation(IntPtr server, uint id, int info, out IntPtr buffer, out uint bytes);
    [DllImport("wtsapi32.dll")] private static extern void WTSFreeMemory(IntPtr buffer);
    public static string Query(uint id, int info) {
        IntPtr buffer; uint bytes;
        if (!WTSQuerySessionInformation(IntPtr.Zero, id, info, out buffer, out bytes)) return null;
        try { return bytes > 2 ? Marshal.PtrToStringUni(buffer) : ""; }
        finally { WTSFreeMemory(buffer); }
    }
}
'@
$consoleId=[VmctlConsoleSession]::WTSGetActiveConsoleSessionId()
$consoleUser=[VmctlConsoleSession]::Query($consoleId,5)
$consoleDomain=[VmctlConsoleSession]::Query($consoleId,7)
$graphics=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction SilentlyContinue
$events=@(Get-WinEvent -FilterHashtable @{LogName='System';StartTime=(Get-Date).AddHours(-3)} -MaxEvents 200 -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'Display|nvlddmkm|Dxg|DriverFramework|Kernel-PnP' } |
    Select-Object -First 20 TimeCreated,ProviderName,Id,LevelDisplayName,Message)
[pscustomobject]@{
    computer=$env:COMPUTERNAME
    consoleSessionId=$consoleId
    consoleUser=$consoleUser
    consoleDomain=$consoleDomain
    userLoggedIn=(-not [string]::IsNullOrWhiteSpace($consoleUser))
    gpuSchedulingOverride=$graphics.HwSchMode
    videoControllers=@(Get-CimInstance Win32_VideoController | Select-Object Name,PNPDeviceID,Status,ConfigManagerErrorCode,DriverVersion,CurrentHorizontalResolution,CurrentVerticalResolution)
    processes=@(Get-Process sunshine,explorer,dwm,winlogon -ErrorAction SilentlyContinue | Select-Object Name,Id,SessionId)
    apolloService=(Get-Service ApolloService | Select-Object Name,Status,StartType)
    displayEvents=$events
    checkedAt=[DateTimeOffset]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 6
