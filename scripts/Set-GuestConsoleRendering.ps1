#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param([ValidateSet('base','restore')][string]$Mode='base')
$ErrorActionPreference='Stop'
$keyPath='SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$valueName='GpuVirtualizationFlags'
$backupPath='C:\ProgramData\vmctl\streaming\console-rendering-before.json'
if (-not @(Get-CimInstance Win32_VideoController | Where-Object Name -match '^NVIDIA ').Count) { throw 'This diagnostic requires an assigned NVIDIA virtual GPU.' }
$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath,$true)
if (-not $key) { throw 'GraphicsDrivers registry key is missing.' }
try {
    if ($Mode -eq 'base') {
        $present=$valueName -in $key.GetValueNames()
        $current=if ($present) { $key.GetValue($valueName) } else { 8 }
        if ($present -and $key.GetValueKind($valueName) -ne [Microsoft.Win32.RegistryValueKind]::DWord) { throw 'Unexpected registry value type.' }
        if (-not (Test-Path -LiteralPath $backupPath)) {
            $null=New-Item -ItemType Directory -Path (Split-Path $backupPath) -Force
            @{present=$present;value=$current;computer=$env:COMPUTERNAME;capturedAt=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $backupPath -Encoding UTF8
        }
        # Microsoft documents bit 0x8 as pairing the render-only GPU with the display-only adapter.
        $key.SetValue($valueName,([int]$current -band (-bnot 8)),[Microsoft.Win32.RegistryValueKind]::DWord)
    } else {
        $previous=Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        if ($previous.computer -cne $env:COMPUTERNAME) { throw 'Backup belongs to another guest.' }
        if ($previous.present) { $key.SetValue($valueName,[int]$previous.value,[Microsoft.Win32.RegistryValueKind]::DWord) }
        else { $key.DeleteValue($valueName,$false) }
    }
    @{computer=$env:COMPUTERNAME;mode=$Mode;value=$key.GetValue($valueName,$null);backup=$backupPath;restartRequired=$true} | ConvertTo-Json
} finally { $key.Dispose() }
