#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Apollo')).TrimEnd('\')
$stage=[IO.Path]::GetFullPath('C:\ProgramData\vmctl\streaming')
$removed=@(); $restartRequired=$false; $nativeResults=@()
function Remove-AllowedDirectory([string]$Path,[string]$Expected) {
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -ine [IO.Path]::GetFullPath($Expected).TrimEnd('\') -or $full -eq [IO.Path]::GetPathRoot($full)) { throw 'Cleanup target is not the expected application directory.' }
    if (Test-Path -LiteralPath $full) {
        $item=Get-Item -LiteralPath $full -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cleanup refuses a redirected application directory.' }
        if(Get-ChildItem -LiteralPath $full -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}) { throw 'Cleanup refuses links inside an application directory.' }
        Remove-Item -LiteralPath $full -Recurse -Force
        $script:removed+=$full
    }
}
$packages=@(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue)
$apollo=@($packages | Where-Object DisplayName -eq 'Apollo')
if ($apollo.Count -gt 1) { throw 'Multiple Apollo uninstall registrations require review.' }
$service=Get-CimInstance Win32_Service -Filter "Name='ApolloService'" -ErrorAction SilentlyContinue
if ($service -and $service.PathName -notlike ('*'+$root+'\*')) { throw 'Apollo service points outside the expected installation.' }
if ($service) { Stop-Service ApolloService -Force; (Get-Service ApolloService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30)) }
# Capture only driver identities belonging to Apollo's display and controller components.
$drivers=@(Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceName -in @('SudoMaker Virtual Display Adapter','Nefarius Virtual Gamepad Emulation Bus') } | Select-Object DeviceName,InfName)
$devices=@(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object FriendlyName -eq 'SudoMaker Virtual Display Adapter')
foreach($device in $devices) {
    $output=& pnputil.exe /remove-device $device.InstanceId 2>&1
    $code=$LASTEXITCODE; $nativeResults+=@{operation='remove-display';code=$code}
    if($code -notin @(0,3010)){throw ('Display removal failed: '+($output -join ' '))}
    $restartRequired=$true
}
# NSIS silent mode defaults to keeping optional drivers/configuration, so remove them explicitly.
$gamepad=@($packages|Where-Object DisplayName -eq 'ViGEm Bus Driver')
foreach($product in $gamepad) {
    if($product.PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$'){throw 'Unexpected gamepad MSI product identity.'}
    $process=Start-Process -FilePath msiexec.exe -ArgumentList @('/x',$product.PSChildName,'/qn','/norestart') -WindowStyle Hidden -Wait -PassThru
    $nativeResults+=@{operation='remove-gamepad';code=$process.ExitCode}
    if($process.ExitCode -notin @(0,1605,3010)){throw "Gamepad uninstall failed ($($process.ExitCode))."}
    if($process.ExitCode -eq 3010){$restartRequired=$true}
}
foreach($driver in $drivers) {
    if($driver.InfName -notmatch '^oem\d+\.inf$'){throw 'Unexpected driver package identity.'}
    $output=& pnputil.exe /delete-driver $driver.InfName /uninstall 2>&1
    $code=$LASTEXITCODE; $nativeResults+=@{operation=('remove-driver-'+$driver.InfName);code=$code}
    # An MSI may already have removed its own driver package.
    if($code -notin @(0,3010) -and (Test-Path -LiteralPath (Join-Path $env:WINDIR ('INF\'+$driver.InfName)))) { throw ('Driver package removal failed: '+($output -join ' ')) }
}
$uninstaller=Join-Path $root 'Uninstall.exe'
if($apollo.Count -and -not(Test-Path -LiteralPath $uninstaller)){throw 'Registered Apollo uninstaller is missing.'}
if(Test-Path -LiteralPath $uninstaller) {
    $process=Start-Process -FilePath $uninstaller -ArgumentList '/S' -WindowStyle Hidden -Wait -PassThru
    $nativeResults+=@{operation='remove-apollo';code=$process.ExitCode}
    if($process.ExitCode -notin @(0,3010)){throw "Apollo uninstall failed ($($process.ExitCode))."}
}
$deadline=(Get-Date).AddSeconds(30)
do { $remaining=Get-CimInstance Win32_Service -Filter "Name='ApolloService'"; if(-not $remaining){break}; Start-Sleep -Seconds 1 } while((Get-Date) -lt $deadline)
if($remaining){throw 'Apollo service remains after uninstall.'}
# The NSIS uninstaller may leave its PATH entry behind. Preserve all other entries.
$machinePath=[Environment]::GetEnvironmentVariable('Path','Machine')
$entries=@($machinePath -split ';')
$kept=@($entries|Where-Object {
    $candidate=$_.Trim().Trim('"').TrimEnd('\')
    -not ($candidate -ieq $root -or $candidate.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase))
})
if($kept.Count -ne $entries.Count){[Environment]::SetEnvironmentVariable('Path',($kept -join ';'),'Machine')}
Get-NetFirewallRule -DisplayName 'Apollo' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
# Restore the guest rendering override only if vmctl created a backup for this VM.
$backupPath=Join-Path $stage 'console-rendering-before.json'
if(Test-Path -LiteralPath $backupPath) {
    $backup=Get-Content -LiteralPath $backupPath -Raw|ConvertFrom-Json
    if($backup.computer -ine $env:COMPUTERNAME){throw 'Rendering backup belongs to another VM.'}
    $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\GraphicsDrivers',$true)
    try {
        if($backup.present){$key.SetValue('GpuVirtualizationFlags',[int]$backup.value,[Microsoft.Win32.RegistryValueKind]::DWord)}
        else {$key.DeleteValue('GpuVirtualizationFlags',$false)}
    } finally {$key.Dispose()}
    $restartRequired=$true
}
Remove-AllowedDirectory $root (Join-Path $env:ProgramFiles 'Apollo')
foreach($profile in @(Get-CimInstance Win32_UserProfile | Where-Object {$_.LocalPath -and $_.LocalPath -like 'C:\Users\*'})) {
    $directory=Join-Path $profile.LocalPath 'AppData\Local\SudoMaker\Apollo'
    Remove-AllowedDirectory $directory (Join-Path $profile.LocalPath 'AppData\Local\SudoMaker\Apollo')
}
foreach($systemProfile in @((Join-Path $env:WINDIR 'System32\config\systemprofile'),(Join-Path $env:WINDIR 'SysWOW64\config\systemprofile'))) {
    $directory=Join-Path $systemProfile 'AppData\Local\SudoMaker\Apollo'
    Remove-AllowedDirectory $directory (Join-Path $systemProfile 'AppData\Local\SudoMaker\Apollo')
}
Remove-AllowedDirectory $stage 'C:\ProgramData\vmctl\streaming'
$remainingPackages=@(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue|Where-Object {$_.DisplayName -in @('Apollo','ViGEm Bus Driver')})
if($remainingPackages.Count){throw 'An Apollo component remains registered after uninstall.'}
[pscustomobject]@{computer=$env:COMPUTERNAME;uninstalled=$true;removedDirectories=$removed;removedPathEntries=($entries.Count-$kept.Count);nativeResults=$nativeResults;restartRequired=$restartRequired;gpuPartitionChanged=$false} | ConvertTo-Json -Depth 5
