#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$stage = 'C:\ProgramData\vmctl\streaming'
$manifest = Get-Content -LiteralPath (Join-Path $stage 'packages.json') -Raw | ConvertFrom-Json
$package = $manifest.apollo
$installer = Join-Path $stage $package.file
if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $package.sha256) { throw 'Apollo installer hash mismatch.' }
$installed = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName -eq 'Apollo')
$changed = $false
if (-not $installed -and (Get-Service sunshinesvc -ErrorAction SilentlyContinue)) { throw 'An existing Sunshine service must be reviewed before installing Apollo.' }
if (-not ($installed | Where-Object DisplayVersion -eq $package.version)) {
    $process = Start-Process -FilePath $installer -ArgumentList '/S' -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -notin @(0,3010)) { throw "Apollo installer exit code $($process.ExitCode)." }
    $changed = $true
}
$service = Get-Service -Name ApolloService -ErrorAction Stop
Set-Service -Name ApolloService -StartupType Automatic
if ($service.Status -ne 'Running') { Start-Service -Name ApolloService }
$service.WaitForStatus('Running',[TimeSpan]::FromSeconds(30))
$root = Join-Path $env:ProgramFiles 'Apollo'
if (-not (Test-Path -LiteralPath (Join-Path $root 'sunshine.exe'))) { throw 'Apollo executable missing.' }
$versionResult=& (Join-Path $root 'sunshine.exe') --version 2>&1
if (($versionResult -join "`n") -notmatch [regex]::Escape($package.version)) { throw 'Installed Apollo version differs from the selected release.' }
# The official installer adds program rules. Restrict them to the local subnet.
Get-NetFirewallRule -DisplayName 'Apollo' -ErrorAction Stop | Set-NetFirewallRule -RemoteAddress LocalSubnet
$deadline = (Get-Date).AddSeconds(60)
do {
    $listener = Get-NetTCPConnection -LocalPort 47990 -State Listen -ErrorAction SilentlyContinue
    if ($listener) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)
[pscustomobject]@{
    computer=$env:COMPUTERNAME; version=$package.version; installerChanged=$changed
    executableVersion=($versionResult -join "`n")
    root=$root; service=(Get-Service ApolloService).Status.ToString()
    startMode=(Get-CimInstance Win32_Service -Filter "Name='ApolloService'").StartMode
    webListening=[bool]$listener
    gpu=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,ConfigManagerErrorCode)
    displayDrivers=@(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Select-Object FriendlyName,Status)
    ipv4=@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress)
} | ConvertTo-Json -Depth 5
if (-not $listener) { throw 'Apollo service runs but the web interface did not become available.' }
