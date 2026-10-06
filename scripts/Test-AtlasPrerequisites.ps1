#requires -Version 5.1
[CmdletBinding()]
param([string]$ExpectedComputerName = 'win-vm')
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine $ExpectedComputerName) { throw 'Preflight Atlas reserve a la VM cible. Aucun changement effectue.' }
$computer = Get-CimInstance Win32_ComputerSystem
if ($computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine') { throw 'Cette preparation exige une VM Hyper-V.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$os = Get-CimInstance Win32_OperatingSystem
$version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$installDate = [DateTimeOffset]::FromUnixTimeSeconds([long]$version.InstallDate)
$pendingReboot = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
$defender = $null
try { $mp = Get-MpComputerStatus; $defender = @{running=$mp.AMServiceEnabled;realTime=$mp.RealTimeProtectionEnabled;tamperProtection=$mp.IsTamperProtected} }
catch { $defender = @{error=$_.Exception.Message} }
$ucpd = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -ErrorAction SilentlyContinue
$antivirus = @()
try { $antivirus = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct | Select-Object displayName,productState) } catch { }
[pscustomobject]@{schemaVersion=1;computer=$env:COMPUTERNAME;user=$identity.Name;admin=$admin;
    caption=$os.Caption;build=[string]$os.BuildNumber;edition=$version.EditionID;
    buildSupported=([string]$os.BuildNumber -in @('26100','26200'));
    editionSupported=($version.EditionID -in @('Professional','ProfessionalWorkstation','Enterprise'));
    installedAt=$installDate.ToString('o');installAgeHours=[Math]::Round(([DateTimeOffset]::UtcNow-$installDate).TotalHours,1);
    freshWithin40Hours=(([DateTimeOffset]::UtcNow-$installDate).TotalHours -le 40);
    pendingReboot=$pendingReboot;defender=$defender;antivirus=$antivirus;
    ucpdStart=$(if ($ucpd) { $ucpd.Start } else { $null });
    notes='Lecture seule. Les mises a jour disponibles et la preparation interactive du CLI AME restent a verifier.'} |
    ConvertTo-Json -Depth 6
