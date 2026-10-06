#requires -Version 7.2
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$Vm,
    [string]$CredentialFile,
    [string]$UserName,
    [string]$Config,
    [string]$ReportDirectory,
    [switch]$Open
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\Vmctl.psm1') -Force
Import-Module (Join-Path $root 'src\StreamingSupport.psm1') -Force
if (-not $Config) { $Config=Get-VmctlConfigPath }
$target=Get-VmctlTarget (Read-VmctlConfig $Config) $Vm
if ($target.os -ne 'windows' -or $target.hypervisor -ne 'hyperv' -or (Get-VmctlTransport $target) -ne 'psdirect') { throw 'This recipe requires a registered local Hyper-V Windows VM using PowerShell Direct.' }
if (-not $ReportDirectory) { $ReportDirectory=Join-Path (Get-VmctlDataRoot) "reports\streaming\$Vm" }
$runtime=Join-Path $PSHOME 'pwsh.exe'
$winps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$work=Join-Path (Get-VmctlDataRoot) ('work\streaming-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work,$ReportDirectory -Force
$statusPath=Join-Path $ReportDirectory 'streaming-status.json'
$ownedCredential=$false
$reopenMoonlight=$false
function Save-State([string]$State,[string]$Message) {
    @{vm=$Vm;state=$State;message=$Message;pid=$PID;at=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding utf8
}
function Invoke-Cli([string[]]$CliArguments,[int]$Timeout=180) {
    $result=Invoke-VmctlProcess $runtime (@('-NoProfile','-File',(Join-Path $root 'vmctl.ps1'))+$CliArguments+@('-Config',$Config)) -TimeoutSeconds ($Timeout+30)
    if ($result.ExitCode -ne 0) { throw "vmctl $($CliArguments[0]) failed ($($result.ExitCode)): $($result.Stderr) $($result.Stdout)" }
    return $result.Stdout
}
function Get-Package([string]$Repository,[string]$Tag,[string]$AssetName) {
    $release=Invoke-RestMethod "https://api.github.com/repos/$Repository/releases/tags/$Tag"
    $asset=$release.assets | Where-Object name -eq $AssetName
    if (-not $asset -or $asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'Official release digest missing.' }
    $hash=$Matches[1]
    $cache=Join-Path $root 'work\streaming'
    $null=New-Item -ItemType Directory -Path $cache -Force
    $path=Join-Path $cache $AssetName
    if (-not (Test-Path -LiteralPath $path)) { Invoke-WebRequest $asset.browser_download_url -OutFile $path }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $hash) { throw "Package hash mismatch: $AssetName" }
    return @{version=$Tag.TrimStart('v');file=$AssetName;sha256=$hash;url=$asset.browser_download_url;path=$path}
}
function Invoke-GuestApi([hashtable]$ApiRequest) {
    $path=Join-Path $work 'api-input.json'
    try {
        $ApiRequest | ConvertTo-Json -Compress | Set-Content -LiteralPath $path -Encoding utf8
        $null=Invoke-Cli @('upload','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-Source',$path,'-Destination','C:\ProgramData\vmctl\streaming\api-input.json')
        return (Invoke-Cli @('run','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-File',(Join-Path $PSScriptRoot 'Invoke-ApolloSetupApiGuest.ps1'),'-TimeoutSeconds','90') 90)
    } finally { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}
function Wait-GuestReady {
    $deadline=(Get-Date).AddMinutes(3)
    do {
        try { $null=Invoke-Cli @('exec','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-Command','$env:COMPUTERNAME','-TimeoutSeconds','15') 15;return }
        catch { $lastFailure=$_.Exception.Message;Start-Sleep -Seconds 2 }
    } while((Get-Date) -lt $deadline)
    throw "PowerShell Direct did not return after startup: $lastFailure"
}
try {
    # Independent QSettings instances can overwrite each other's pairing cache.
    $clients=@(Get-Process Moonlight -ErrorAction SilentlyContinue)
    if($Open -and @($clients|Where-Object {$_.MainWindowTitle -like '* - Moonlight'}).Count) {
        # Resume an already opened matching stream without reinstalling or closing it.
        $openArguments=@('streaming-open','-Vm',$Vm)
        if(Test-Path -LiteralPath $statusPath){$previous=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json;if($previous.state -eq 'failed' -and $previous.message -match 'streaming-open failed'){$openArguments+='-Reconnect'}}
        $opened=Invoke-Cli $openArguments
        $opened|Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-open.json')
        Save-State 'stream-window-open' 'The matching Moonlight stream is already open and receiving video.'
        return
    }
    if(@($clients|Where-Object {$_.MainWindowTitle -and $_.MainWindowTitle -ne 'Moonlight'}).Count) { throw 'Disconnect the active Moonlight stream before configuring another VM.' }
    if($clients.Count) {
        $reopenMoonlight=$true
        foreach($client in $clients){$null=$client.CloseMainWindow()}
        $deadline=(Get-Date).AddSeconds(10)
        do { Start-Sleep -Milliseconds 250; $clients=@(Get-Process Moonlight -ErrorAction SilentlyContinue) } while($clients.Count -and (Get-Date) -lt $deadline)
        if($clients.Count){throw 'Close all Moonlight processes before installation; its saved hosts cannot be updated safely.'}
    }
    Save-State 'host-preparation' 'Installing Moonlight and checking Hyper-V GPU capabilities.'
    $packages=@{moonlight=(Get-Package 'moonlight-stream/moonlight-qt' 'v6.2.0' 'MoonlightSetup-6.2.0.exe');apollo=(Get-Package 'ClassicOldSong/Apollo' 'v0.4.6' 'Apollo-0.4.6.exe')}
    $packages | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-packages.json') -Encoding utf8
    $moonlight=Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
    if (-not (Test-Path -LiteralPath $moonlight) -or (Get-Item -LiteralPath $moonlight).VersionInfo.ProductVersion -notlike '6.2.0*') {
        $install=Start-Process -FilePath $packages.moonlight.path -ArgumentList '/install','/quiet','/norestart' -WindowStyle Hidden -Wait -PassThru
        if ($install.ExitCode -notin @(0,3010)) { throw "Moonlight installer exit code $($install.ExitCode)." }
    }
    if (-not (Test-Path -LiteralPath $moonlight)) { throw 'Installed Moonlight executable not found.' }
    $gpuResult=Invoke-VmctlProcess $winps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Test-StreamingGpuHost.ps1'),'-Vm',$target.vmName) -TimeoutSeconds 60
    if ($gpuResult.ExitCode -ne 0) { throw $gpuResult.Stderr }
    $gpuInfo=$gpuResult.Stdout | ConvertFrom-Json
    if ($target.ContainsKey('vmId') -and $gpuInfo.vmId -ne $target.vmId) { throw 'Registered VM GUID differs from the Hyper-V target.' }
    $gpuResult.Stdout | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-gpu-host.json') -Encoding utf8
    if (-not $UserName) {
        if ($target.ContainsKey('user')) { $UserName=$target.user }
        if (-not $UserName) { $UserName='vmctl-admin' }
    }
    if (-not $CredentialFile) {
        $CredentialFile=Join-Path $work 'guest-credential.clixml'
        $ownedCredential=$true
        Save-State 'awaitingCredentials' "Enter the password for $UserName in the Windows credential dialog."
        $credentialResult=Invoke-VmctlProcess $winps @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Request-StreamingCredential.ps1'),'-UserName',$UserName,'-Destination',$CredentialFile) -TimeoutSeconds 900
        if ($credentialResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $CredentialFile)) { throw 'VM credential entry failed or was cancelled.' }
    }
    Save-State 'guest-installation' 'Installing Apollo through public vmctl.'
    if($gpuInfo.vmState -eq 'Off'){$null=Invoke-Cli @('start','-Vm',$Vm,'-TimeoutSeconds','900') 900;Wait-GuestReady}
    elseif($gpuInfo.vmState -ne 'Running'){throw "VM state $($gpuInfo.vmState) must be resolved before installation."}
    $doctor=Invoke-Cli @('doctor','-Vm',$Vm,'-CredentialFile',$CredentialFile)
    $doctor | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-doctor.json') -Encoding utf8
    $null=Invoke-Cli @('exec','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-Command',"`$null=New-Item -ItemType Directory -Path 'C:\ProgramData\vmctl\streaming' -Force; `$acl=Get-Acl 'C:\ProgramData\vmctl\streaming'; `$acl.SetAccessRuleProtection(`$true,`$false); foreach(`$sid in @('S-1-5-18','S-1-5-32-544')) { `$rule=New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier(`$sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow'); `$acl.AddAccessRule(`$rule) }; Set-Acl 'C:\ProgramData\vmctl\streaming' `$acl")
    $manifestPath=Join-Path $work 'packages.json'
    $packages | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    $null=Invoke-Cli @('upload','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-Source',$manifestPath,'-Destination','C:\ProgramData\vmctl\streaming\packages.json')
    $null=Invoke-Cli @('upload','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-Source',$packages.apollo.path,'-Destination',('C:\ProgramData\vmctl\streaming\'+$packages.apollo.file))
    $guest=Invoke-Cli @('run','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-File',(Join-Path $PSScriptRoot 'Install-ApolloGuest.ps1'),'-TimeoutSeconds','600') 600
    $guest | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-apollo-guest.json') -Encoding utf8
    $guestInfo=$guest | ConvertFrom-Json
    $rendering=@{restartRequired=$false;changed=$false}
    if(@($gpuInfo.assigned).Count -gt 0 -and @($guestInfo.gpu|Where-Object {$_.Name -match '^NVIDIA ' -and $_.ConfigManagerErrorCode -eq 0}).Count -eq 1) {
        Save-State 'guest-display-preparation' 'Separating Hyper-V console rendering from the shared NVIDIA GPU.'
        $rendering=(Invoke-Cli @('run','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-File',(Join-Path $PSScriptRoot 'Set-GuestConsoleRendering.ps1'))) | ConvertFrom-Json
        $rendering | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-console-rendering.json')
    }
    if($guestInfo.restartRequired -or $rendering.restartRequired) {
        Save-State 'guest-restarting' 'Restarting the guest and reusing the same Windows credential.'
        $null=Invoke-Cli @('restart','-Vm',$Vm,'-TimeoutSeconds','900') 900
        Wait-GuestReady
        $guest=Invoke-Cli @('run','-Vm',$Vm,'-CredentialFile',$CredentialFile,'-File',(Join-Path $PSScriptRoot 'Install-ApolloGuest.ps1'),'-TimeoutSeconds','600') 600
        $guestInfo=$guest|ConvertFrom-Json
        $guest|Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-apollo-guest.json')
        if($guestInfo.restartRequired){throw 'Apollo still requests a restart after startup.'}
    }
    if(-not @($guestInfo.displayDrivers|Where-Object {$_.FriendlyName -eq 'SudoMaker Virtual Display Adapter' -and $_.Status -eq 'OK'}).Count){throw 'Apollo virtual display driver is not healthy after installation.'}
    $address=$null
    foreach ($candidate in $guestInfo.ipv4) {
        $socket=[Net.Sockets.TcpClient]::new()
        try {
            $connect=$socket.ConnectAsync($candidate,47989)
            if ($connect.Wait(3000) -and $socket.Connected) { $address=$candidate; break }
        } catch { } finally { $socket.Dispose() }
    }
    if (-not $address) { throw 'Apollo installed, but no guest IPv4 is reachable from the host on TCP 47989.' }
    Save-State 'pairing' 'Creating the Apollo administrator and pairing Moonlight through the official CLI and vmctl.'
    $secretDirectory=Join-Path (Get-VmctlDataRoot) 'credentials'
    $null=New-Item -ItemType Directory -Path $secretDirectory -Force
    $secretPath=Join-Path $secretDirectory ("apollo-$Vm.clixml")
    if (Test-Path -LiteralPath $secretPath) {
        $apiCredential=Import-Clixml -LiteralPath $secretPath
        $action='login'
    } else {
        $bytes=[byte[]]::new(30)
        [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
        $password=[Convert]::ToBase64String($bytes)
        $apiCredential=[pscredential]::new('vmctl',(ConvertTo-SecureString $password -AsPlainText -Force))
        $action='initialize'
    }
    $apiRequest=@{action=$action;username=$apiCredential.UserName;password=$apiCredential.GetNetworkCredential().Password;expectedVersion=$packages.apollo.version}
    $apiResult=Invoke-GuestApi $apiRequest
    if ($action -eq 'initialize') { $apiCredential | Export-Clixml -LiteralPath $secretPath }
    $apiResult | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-apollo-api.json') -Encoding utf8
    $gpuConfigured=$false
    $guestNvidia=@($guestInfo.gpu | Where-Object { $_.Name -match '^NVIDIA ' -and $_.ConfigManagerErrorCode -eq 0 })
    if (@($gpuInfo.assigned).Count -gt 0 -and $guestNvidia.Count -eq 1) {
        $gpuRequest=@{action='configure-gpu';username=$apiCredential.UserName;password=$apiCredential.GetNetworkCredential().Password;gpuName=$guestNvidia[0].Name}
        $gpuApi=Invoke-GuestApi $gpuRequest
        $gpuApi | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-apollo-gpu.json') -Encoding utf8
        $gpuConfigured=$true
    }
    $listResult=Invoke-VmctlProcess $moonlight @('list',$address) -TimeoutSeconds 45
    if ($listResult.ExitCode -ne 0) {
        $pin=[Security.Cryptography.RandomNumberGenerator]::GetInt32(1000,10000).ToString()
        $pairProcess=Start-Process -FilePath $moonlight -ArgumentList 'pair',$address,'--pin',$pin -WindowStyle Hidden -PassThru
        try {
            Start-Sleep -Seconds 4
            $apiRequest.action='pair'; $apiRequest.pin=$pin; $apiRequest.clientName=$env:COMPUTERNAME
            $pairResult=Invoke-GuestApi $apiRequest
            $pairResult | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-pairing.json') -Encoding utf8
            # CLI pairing opens a completion dialog instead of exiting. Its certificate
            # must reach QSettings before closing that process or launching another CLI.
            $deadline=(Get-Date).AddSeconds(15)
            $certificateSaved=$false
            do {
                $savedHosts=@(Get-VmctlMoonlightHost -Address $address)
                if($savedHosts.Count -eq 1) {
                    $savedKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Moonlight Game Streaming Project\Moonlight\hosts\'+$savedHosts[0].key)
                    try {$certificateSaved=[bool]$savedKey.GetValue('srvcert','')} finally {$savedKey.Dispose()}
                }
                if(-not $certificateSaved){Start-Sleep -Milliseconds 250}
            } while(-not $certificateSaved -and -not $pairProcess.HasExited -and (Get-Date) -lt $deadline)
            if(-not $certificateSaved){throw 'Moonlight did not persist its paired server certificate.'}
            if(-not $pairProcess.HasExited){$null=$pairProcess.CloseMainWindow(); $null=$pairProcess.WaitForExit(5000)}
        } finally { if (-not $pairProcess.HasExited) { $pairProcess.Kill() }; $pairProcess.Dispose() }
        $listResult=Invoke-VmctlProcess $moonlight @('list',$address) -TimeoutSeconds 45
    }
    $listResult | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-moonlight-apps.json') -Encoding utf8
    if ($listResult.ExitCode -ne 0) { throw "Moonlight pairing/app listing failed: $($listResult.Stderr)" }
    $pairedHosts=@(Get-VmctlMoonlightHost -Address $address)
    if($pairedHosts.Count -ne 1){throw 'A unique persisted Moonlight host was not found after pairing.'}
    $bindingDirectory=Join-Path (Get-VmctlDataRoot) 'streaming-bindings'
    $null=New-Item -ItemType Directory -Path $bindingDirectory -Force
    @{vm=$Vm;vmName=$target.vmName;vmId=$gpuInfo.vmId;serverUuid=$pairedHosts[0].uuid} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $bindingDirectory "$Vm.json") -Encoding utf8
    @{vm=$Vm;vmName=$target.vmName;vmId=$gpuInfo.vmId;address=$address;webUi="https://${address}:47990";moonlight=$moonlight;moonlightHostUuid=$pairedHosts[0].uuid;apolloVersion=$packages.apollo.version;moonlightVersion=$packages.moonlight.version;paired=$true;streamTested=$false;gpuAssigned=(@($gpuInfo.assigned).Count -gt 0);apolloGpuConfigured=$gpuConfigured;apolloAdministratorCredentialFile=$secretPath;checkpointsModified=$false} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-install-result.json') -Encoding utf8
    Save-State 'installed-and-paired' 'Moonlight and Apollo installed, paired, and app listing verified. GPU acceleration and a video stream remain to be tested.'
    if($Open) {
        Save-State 'opening-stream' 'Opening the paired Virtual Display with the saved Moonlight preferences.'
        $opened=Invoke-Cli @('streaming-open','-Vm',$Vm)
        $opened|Set-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-open.json')
        Save-State 'stream-window-open' 'Moonlight has a visible streaming window. Consult the stream diagnostics to verify video delivery.'
    }
} catch {
    Save-State 'failed' $_.Exception.Message
    throw
} finally {
    if ($ownedCredential -and (Test-Path -LiteralPath $CredentialFile)) { Remove-Item -LiteralPath $CredentialFile -Force }
    if($reopenMoonlight -and -not(Get-Process Moonlight -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'))) {
        $null=Start-Process -FilePath (Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe') -WorkingDirectory (Join-Path $env:ProgramFiles 'Moonlight Game Streaming')
    }
}
