#requires -Version 5.1
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine 'win-vm') { throw 'Diagnostic reserve a win-vm.' }
$archive = 'C:\vmctl-atlas-20261005\Atlas-CLI-Payload.zip'
$expected = '0b0dd46c36231896811f47296fd02594ee86f21f4ba0d8ed41f040095a780616'
$hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $expected) { throw 'Archive Atlas transferee non conforme.' }
$mp = Get-MpComputerStatus
$preferences = Get-MpPreference
$version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$updates = $null
$updateError = $null
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $search = $session.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
    $updates = @($search.Updates | ForEach-Object { [pscustomobject]@{title=$_.Title;downloaded=$_.IsDownloaded;rebootBehavior=[int]$_.InstallationBehavior.RebootBehavior} })
} catch { $updateError=$_.Exception.Message }
$internet = $false
try { $null = Invoke-WebRequest -Uri 'https://github.com' -Method Head -UseBasicParsing -TimeoutSec 20; $internet=$true } catch { }
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$ucpd = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\UCPD' -ErrorAction SilentlyContinue
[pscustomobject]@{
    computer=$env:COMPUTERNAME; archive=$archive; archiveVerified=$true; archiveSha256=$hash;
    build=[string]$version.CurrentBuildNumber; edition=$version.EditionID;
    installedAt=[DateTimeOffset]::FromUnixTimeSeconds([long]$version.InstallDate).ToString('o');
    freeBytes=[long]$disk.FreeSpace; internet=$internet; updates=$updates; updateError=$updateError;
    defender=@{realTime=$mp.RealTimeProtectionEnabled;tamperProtection=$mp.IsTamperProtected;cloudReporting=[int]$preferences.MAPSReporting;sampleConsent=[int]$preferences.SubmitSamplesConsent};
    ucpdStart=$(if($ucpd){$ucpd.Start}else{$null});
    securityChanged=$false; playbookExecuted=$false
} | ConvertTo-Json -Depth 6
