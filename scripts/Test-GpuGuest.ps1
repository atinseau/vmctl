#requires -Version 5.1
$ErrorActionPreference='Stop'
$controllers=@(Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,ConfigManagerErrorCode,AdapterRAM)
$manifest=Get-Content -LiteralPath 'C:\ProgramData\vmctl\gpu\driver-manifest.json' -Raw | ConvertFrom-Json
$nvidia=@($controllers | Where-Object Name -match 'NVIDIA')
$healthy=$nvidia.Count -ge 1 -and @($nvidia | Where-Object ConfigManagerErrorCode -ne 0).Count -eq 0
$stage='C:\ProgramData\vmctl\gpu'
$nvenc=Join-Path $env:SystemRoot 'System32\nvEncodeAPI64.dll'
$nvencVersion=if(Test-Path -LiteralPath $nvenc){(Get-Item -LiteralPath $nvenc).VersionInfo.FileVersion}else{$null}
$apollo=Get-CimInstance Win32_Service -Filter "Name='ApolloService'"
$pageFiles=@(Get-CimInstance Win32_PageFileUsage | Select-Object Name,AllocatedBaseSize,CurrentUsage,PeakUsage)
[pscustomobject]@{
 computer=$env:COMPUTERNAME;lastBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
 controllers=$controllers;nvidiaHealthy=$healthy;copiedHostDriver=$manifest.version;copiedFiles=$manifest.copiedFiles
 nvencLibraryVersion=$nvencVersion;dxgiDiagnostic='Not run: console tool blocks in a noninteractive session; real streaming verifies capture and encoding.'
 apollo=@{state=$apollo.State;startMode=$apollo.StartMode;webListening=[bool](Get-NetTCPConnection -LocalPort 47990 -State Listen -ErrorAction SilentlyContinue)}
 cDrive=(Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" | Select-Object Size,FreeSpace)
 pageFiles=$pageFiles
} | ConvertTo-Json -Depth 7
if(-not $healthy){throw 'NVIDIA GPU is missing or reports a device error.'}
