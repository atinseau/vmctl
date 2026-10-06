#requires -Version 5.1
[CmdletBinding()]
param([string]$PayloadRoot = 'C:\vmctl-atlas-20261005', [string]$ExpectedComputerName = 'win-vm', [switch]$Apply,
    [switch]$CleanWindowsConfirmed)
$ErrorActionPreference = 'Stop'
if ($env:COMPUTERNAME -ine $ExpectedComputerName) { throw 'Installation Atlas reservee a la VM cible. Aucun installateur lance.' }
$root = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')
$prefix = $root + '\'
$manifest = Get-Content -LiteralPath (Join-Path $root 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($entry in $manifest) {
    $path = [IO.Path]::GetFullPath((Join-Path $root $entry.path))
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Chemin du manifeste hors du paquet.' }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.sha256) { throw "Paquet modifie : $($entry.path)" }
}
$probe = & (Join-Path $root 'Test-AtlasPrerequisites.ps1') -ExpectedComputerName $ExpectedComputerName | ConvertFrom-Json
if (-not $Apply) { $probe | ConvertTo-Json -Depth 6; return }
if (-not $probe.admin -or -not $probe.buildSupported -or -not $probe.editionSupported) { throw 'Compte ou edition/build Windows incompatible. Consulter le preflight.' }
if (-not $CleanWindowsConfirmed) { throw 'Confirmez une installation Windows propre avec -CleanWindowsConfirmed ; son age ne prouve pas son utilisation.' }
if ($probe.pendingReboot) { throw 'Redemarrage Windows en attente. Aucun Playbook applique.' }
if ($probe.defender.PSObject.Properties['error'] -or $probe.defender.realTime -or $probe.defender.tamperProtection) {
    throw 'Preparation Defender requise dans la VM avant une execution sans prompts. Aucun changement de protection effectue par ce lanceur.'
}
$preferences = Get-MpPreference
if ($preferences.MAPSReporting -ne 0 -or [int]$preferences.SubmitSamplesConsent -notin @(0,2,4)) {
    throw 'Options Defender attendues par le CLI AME encore actives. Aucun Playbook applique.'
}
if ($null -ne $probe.ucpdStart -and $probe.ucpdStart -ne 4) { throw 'Le CLI AME exigerait une preparation UCPD et un redemarrage. Aucun Playbook applique.' }
$ucpdDriver = Get-CimInstance Win32_SystemDriver -Filter "Name='UCPD'" -ErrorAction SilentlyContinue
if ($ucpdDriver -and $ucpdDriver.State -ne 'Stopped') { throw 'Le pilote UCPD doit etre arrete par redemarrage avant installation.' }
if (@($probe.antivirus | Where-Object { $_.displayName -notmatch 'Defender' }).Count -gt 0) { throw 'Antivirus tiers detecte. Aucun Playbook applique.' }
$null = Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -TimeoutSec 15
$updateSession = New-Object -ComObject Microsoft.Update.Session
$updateSearch = $updateSession.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')
if ($updateSearch.Updates.Count -gt 0) { throw 'Mises a jour Windows disponibles. Aucun Playbook applique avant leur installation.' }
$logFolder = Join-Path $root ('logs\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $logFolder -Force
$exe = Join-Path $root 'CLI\TrustedUninstaller.CLI.exe'
$playbook = Join-Path $root 'Playbook'
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '"' + $playbook + '" defender-enable mitigations-default auto-updates-default'
$info.WorkingDirectory = Join-Path $root 'CLI'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$process = New-Object Diagnostics.Process
$process.StartInfo = $info
try {
    $null = $process.Start()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Close()
    $writer = New-Object IO.StreamWriter((Join-Path $logFolder 'stdout.txt'), $false, (New-Object Text.UTF8Encoding($false)))
    $writer.AutoFlush = $true
    try { while ($null -ne ($line = $process.StandardOutput.ReadLine())) { $writer.WriteLine($line) } }
    finally { $writer.Dispose() }
    $process.WaitForExit()
    $stdout = Get-Content -LiteralPath (Join-Path $logFolder 'stdout.txt') -Raw -Encoding UTF8
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $stderr | Set-Content -LiteralPath (Join-Path $logFolder 'stderr.txt') -Encoding UTF8
    $applied = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\AME\Playbooks\Applied' -ErrorAction SilentlyContinue |
        Get-ItemProperty | Where-Object { $_.Name -eq 'AtlasOS' -and $_.Version -eq '0.5.0' })
    # CLI 0.8.4 records applied Playbooks only on its fatal-error path. A successful run can have no AME registry entry.
    $oem = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation' -ErrorAction SilentlyContinue
    $installedFiles = (Test-Path 'C:\Windows\AtlasModules') -and (Test-Path 'C:\Windows\AtlasDesktop')
    $success = $process.ExitCode -eq 0 -and $stdout -match 'Playbook completed successfully\.' -and $stdout -notmatch 'Playbook completed with errors\.' -and
        $oem.Model -eq 'Atlas Playbook v0.5.0' -and $installedFiles -and @($applied | Where-Object ErrorLevel -ne 0).Count -eq 0
    [pscustomobject]@{computer=$env:COMPUTERNAME;exitCode=$process.ExitCode;success=$success;logs=$logFolder;
        oemModel=$oem.Model;installedFiles=$installedFiles;registryRecorded=($applied.Count -gt 0);
        applied=@($applied | Select-Object Name,Version,ErrorLevel,SelectedOptions)} | ConvertTo-Json -Depth 5
    if (-not $success) { throw "Le CLI AME n a pas confirme l installation complete. Consulter $logFolder avant toute reprise." }
} finally { $process.Dispose() }
