#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('help', 'list', 'shortcut', 'register', 'exec', 'run', 'upload', 'doctor', 'checkpoint', 'start', 'stop', 'restart', 'storage', 'compact', 'gpu-setup', 'gpu-status', 'gpu-sync', 'gpu-remove', 'gpu-task-test', 'streaming-install', 'streaming-open', 'streaming-access', 'streaming-forget', 'streaming-status', 'streaming-display-fix', 'streaming-display-restore', 'streaming-video-test', 'streaming-video-restore', 'capabilities', 'screenshot', 'move', 'click', 'type', 'key', 'scroll', 'drag')]
    [string]$Action = 'help',
    [Parameter(Position=1)][ValidateSet('install','uninstall')][string]$ShortcutAction,
    [string]$Vm, [string]$Command, [string]$File, [string]$Source, [string]$Destination,
    [Alias('-name')][string]$Name, [string]$HostName, [string]$UserName,
    [ValidateSet('windows', 'linux')][string]$Os,
    [ValidateRange(1, 65535)][int]$Port,
    [ValidateSet('none', 'hyperv')][string]$Hypervisor,
    [string]$HyperVName,
    [ValidateSet('auto','psdirect','ssh')][string]$Transport = 'auto',
    [Management.Automation.PSCredential]$Credential, [string]$CredentialFile,
    [ValidateSet('powershell.exe', 'pwsh.exe', 'sh', 'bash')][string]$Shell,
    [ValidateRange(1, 86400)][int]$TimeoutSeconds = 120,
    [string]$Config, [switch]$Recursive, [switch]$Open, [switch]$Reconnect,
    [ValidateSet('Virtual Display','Desktop')][string]$Application = 'Virtual Display',
    [ValidateRange(10,480)][int]$Fps,
    [Alias('-mode')][ValidateSet('windowed','fullscreen')][string]$Mode = 'windowed',
    [string]$OutFile, [string]$Frame, [string]$Text, [string]$Keys, [string]$ReportDirectory,
    [string]$GpuName='NVIDIA GeForce RTX 4090', [ValidateRange(1,100)][int]$GpuPercent=25,
    [ValidateSet('software','nvenc')][string]$Encoder,
    [switch]$DefaultAdapter, [switch]$ConsoleDisplay, [switch]$OnlyDisplay, [switch]$PrimaryDisplay, [switch]$DisableRealtimePriority, [switch]$EnableModernCodecs,
    [int]$X = -1, [int]$Y = -1, [int]$ToX = -1, [int]$ToY = -1,
    [ValidateRange(1, 5)][int]$ButtonIndex = 1,
    [ValidateRange(1, 2)][int]$Count = 1, [int]$Delta,
    [ValidateRange(1, 600)][int]$MaxFrameAgeSeconds = 120,
    [switch]$Elevate, [switch]$RemoveCheckpoints, [switch]$DisableAutomaticCheckpoints, [switch]$Diagnostics,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$ExtraArguments
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Import-Module (Join-Path $PSScriptRoot 'src/Vmctl.psm1') -Force
try {
    # PowerShell treats --name as positional text when invoking a .ps1 directly.
    # Normalize these GNU-style options for both interactive and native callers.
    if($ExtraArguments){
        if($Action -ne 'shortcut'){throw 'Unexpected command arguments.'}
        for($index=0;$index -lt $ExtraArguments.Count;$index+=2){
            if($index+1 -ge $ExtraArguments.Count){throw 'Shortcut option requires a value.'}
            switch($ExtraArguments[$index]){
                '--name' {if($Name){throw 'Duplicate shortcut name option.'};$Name=$ExtraArguments[$index+1]}
                '--mode' {if($PSBoundParameters.ContainsKey('Mode')){throw 'Duplicate shortcut mode option.'};$Mode=$ExtraArguments[$index+1];$PSBoundParameters['Mode']=$Mode}
                default {throw "Unknown shortcut option: $($ExtraArguments[$index])"}
            }
        }
    }
    if ($Action -eq 'help') {
        @'
vmctl : PowerShell Direct (Hyper-V Windows local), SSH et console optionnelle

  vmctl list
  vmctl shortcut install --name "VM - Fenetre" [--mode windowed|fullscreen]
  vmctl shortcut uninstall --name "VM - Fenetre"
  vmctl register -Vm win-vm -Os windows -Hypervisor hyperv [-UserName win-vm\vmctl-admin]
  vmctl register -Vm debian -HostName debian-vm -Os linux [-UserName admin]
  vmctl exec -Vm win-vm -Command 'hostname; whoami' [-Credential $cred]
  vmctl run -Vm win-vm -File .\install.ps1
  vmctl upload -Vm win-vm -Source .\package.zip -Destination C:/Temp/package.zip
  vmctl doctor -Vm win-vm
  vmctl checkpoint -Vm win-vm -Name before-atlas
  vmctl start|stop|restart -Vm win-vm
  vmctl storage -Vm win-vm
  vmctl compact -Vm win-vm -TimeoutSeconds 900
  vmctl compact -Vm win-vm -RemoveCheckpoints -TimeoutSeconds 1800
  vmctl streaming-install -Vm win-vm [-Open] [-CredentialFile PATH] [-ReportDirectory PATH]
  vmctl streaming-open -Vm win-vm [-Reconnect] [-Application 'Virtual Display'|Desktop] [-Fps 60] [-Mode windowed|fullscreen]
  vmctl streaming-access -Vm win-vm
  vmctl streaming-forget -Vm win-vm [-HostName IPv4]
  vmctl streaming-status -Vm win-vm [-HostName IPv4]
  vmctl streaming-status -Vm win-vm -Diagnostics
  vmctl streaming-display-fix|streaming-display-restore -Vm win-vm
  vmctl streaming-video-test -Vm win-vm -Encoder software|nvenc
  vmctl streaming-video-test -Vm win-vm -Encoder nvenc -EnableModernCodecs
  vmctl streaming-video-test -Vm win-vm -Encoder software -DefaultAdapter -ConsoleDisplay
  vmctl streaming-video-test -Vm win-vm -Encoder nvenc -OnlyDisplay
  vmctl streaming-video-test -Vm win-vm -Encoder nvenc -PrimaryDisplay
  vmctl streaming-video-test -Vm win-vm -Encoder nvenc -PrimaryDisplay -DisableRealtimePriority
  vmctl streaming-video-restore -Vm win-vm
  vmctl gpu-setup -Vm win-vm -GpuName 'NVIDIA GeForce RTX 4090' -GpuPercent 25 [-Elevate]
  vmctl gpu-status|gpu-sync|gpu-remove|gpu-task-test -Vm win-vm [-Elevate]
  vmctl capabilities -Vm win-vm [-Elevate]
  vmctl screenshot -Vm win-vm -OutFile .\screen.png [-Elevate]
  vmctl click -Vm win-vm -Frame .\screen.json -X 420 -Y 260 [-Count 2]
  vmctl type -Vm win-vm -Frame PATH.json -Text 'texte literal'
  vmctl key -Vm win-vm -Frame PATH.json -Keys Ctrl+A
  vmctl move -Vm win-vm -Frame PATH.json -X 420 -Y 260
  vmctl scroll -Vm win-vm -Frame PATH.json -X 420 -Y 260 -Delta -120
  vmctl drag -Vm win-vm -Frame PATH.json -X 420 -Y 260 -ToX 600 -ToY 300

Options : -Config PATH, -TimeoutSeconds 120, upload -Recursive.
Transport auto : PowerShell Direct pour Windows Hyper-V local, SSH sinon.
PowerShell Direct : droits Hyper-V sur l'hote, compte/mot de passe de la VM.
-Credential $cred ou -CredentialFile PATH (Export-Clixml chiffre Windows).
Sans ces options, une saisie Get-Credential est demandee. Aucun SSH requis.
SSH : cles et alias dans ~/.ssh/config. Cle hote deja verifiee requise.
Hyper-V : hypervisor=hyperv et vmName, droits sur l'hote requis.
restart effectue un arret propre puis un demarrage, sans reset force.
storage mesure les disques et leur chaine de checkpoints. compact exige une VM arretee,
monte uniquement ses disques actifs en lecture seule puis applique Optimize-VHD Retrim et Full.
Les checkpoints et la capacite virtuelle sont conserves.
-RemoveCheckpoints supprime tous les checkpoints de la cible et attend leur fusion.
-DisableAutomaticCheckpoints desactive leur creation automatique (compact/checkpoint).
streaming-install installe Moonlight sur l'hote, Apollo dans la VM et les appaire.
Avec -Open, il ouvre Virtual Display et verifie la fenetre et la reception video.
streaming-open reutilise cet appairage sans identification Windows ni UAC.
Le client est lance avec les droits de la session Windows normale.
Une elevation UAC est lancee une seule fois si necessaire ; cet appel retourne alors
un PID et le chemin du rapport. Etat final dans streaming-status.json.
Une session en echec peut etre reprise pendant 30 minutes en relancant la commande.
Les versions et SHA-256 officiels sont fixes. Aucun GPU n'est affecte automatiquement.
streaming-access ouvre une boite de dialogue locale pour copier le mot de passe
administrateur Apollo chiffre, sans l'afficher dans la sortie du CLI.
gpu-setup installe GPU-P et synchronise le pilote NVIDIA sur le disque invite arrete.
Une tache SYSTEM protegee controle les pilotes et demarre la VM au boot de l'hote.
start et restart controles passent ensuite par la synchronisation automatique.
gpu-sync refuse de mettre a jour le disque d'une VM en cours ; gpu-remove exige l'arret.
Console Hyper-V : session de base, droits administrateur ou -Elevate (UAC).
Console testee sur win-vm : capture RGB565, clavier, clic et defilement natifs.
-Frame doit correspondre a la VM/resolution, dater de moins de 120s et etre inutilise.
Chaque action retourne du JSON ; -OutFile optionnel, fichier existant refuse.
-ButtonIndex : index natif Hyper-V 1..5 (defaut 1), pas de nouvelle tentative.
Codes : 0 succes, 2 usage/configuration, 124 timeout, 255 erreur SSH.
Les autres codes sont ceux du programme distant (ou de scp).
'@
        exit 0
    }
    if (-not $Config) { $Config = Get-VmctlConfigPath }
    if ($RemoveCheckpoints -and $Action -ne 'compact') { throw '-RemoveCheckpoints exige compact.' }
    if ($DisableAutomaticCheckpoints -and $Action -notin @('compact','checkpoint')) { throw '-DisableAutomaticCheckpoints exige compact ou checkpoint.' }
    if ($Encoder -and $Action -ne 'streaming-video-test') { throw '-Encoder is supported only with streaming-video-test.' }
    if ($EnableModernCodecs -and ($Action -ne 'streaming-video-test' -or $Encoder -ne 'nvenc')) { throw '-EnableModernCodecs requires streaming-video-test -Encoder nvenc.' }
    if (($DefaultAdapter -or $ConsoleDisplay) -and $Action -ne 'streaming-video-test') { throw '-DefaultAdapter and -ConsoleDisplay require streaming-video-test.' }
    if ($OnlyDisplay -and $Action -ne 'streaming-video-test') { throw '-OnlyDisplay requires streaming-video-test.' }
    if ($PrimaryDisplay -and $Action -ne 'streaming-video-test') { throw '-PrimaryDisplay requires streaming-video-test.' }
    if ($DisableRealtimePriority -and ($Action -ne 'streaming-video-test' -or $Encoder -ne 'nvenc')) { throw '-DisableRealtimePriority requires streaming-video-test -Encoder nvenc.' }
    if ($PrimaryDisplay -and ($OnlyDisplay -or $ConsoleDisplay)) { throw '-PrimaryDisplay, -OnlyDisplay and -ConsoleDisplay are mutually exclusive.' }
    if ($OnlyDisplay -and $ConsoleDisplay) { throw '-OnlyDisplay and -ConsoleDisplay are mutually exclusive.' }
    if ($Diagnostics -and $Action -ne 'streaming-status') { throw '-Diagnostics is supported only with streaming-status.' }
    if ($Open -and $Action -ne 'streaming-install') { throw '-Open is supported only with streaming-install.' }
    if ($Reconnect -and $Action -ne 'streaming-open') { throw '-Reconnect is supported only with streaming-open.' }
    if ($PSBoundParameters.ContainsKey('Application') -and $Action -ne 'streaming-open') { throw '-Application is supported only with streaming-open.' }
    if ($PSBoundParameters.ContainsKey('Fps') -and $Action -ne 'streaming-open') { throw '-Fps is supported only with streaming-open.' }
    if ($PSBoundParameters.ContainsKey('Mode') -and $Action -notin @('streaming-open','shortcut')) { throw '-Mode is supported only with streaming-open or shortcut.' }
    if ($ShortcutAction -and $Action -ne 'shortcut') { throw 'install/uninstall requires shortcut.' }
    if ($Action -eq 'shortcut') {
        if(-not $ShortcutAction -or -not $Name){throw 'Usage: vmctl shortcut install|uninstall --name NAME [--mode windowed|fullscreen]'}
        Import-Module (Join-Path $PSScriptRoot 'src/ShortcutSupport.psm1') -Force
        $shortcutArgs=@{Action=$ShortcutAction;Name=$Name;Mode=$Mode;Runtime=(Join-Path $PSHOME 'pwsh.exe');PickerScript=(Join-Path $PSScriptRoot 'scripts/Open-StreamingPicker.ps1')}
        if($PSBoundParameters.ContainsKey('Config')){$shortcutArgs.Config=[IO.Path]::GetFullPath($Config)}
        Set-VmctlDesktopShortcut @shortcutArgs | ConvertTo-Json
        exit 0
    }
    if ($Action -eq 'register') {
        if (-not $Vm -or $Vm -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { throw 'register exige un -Vm valide.' }
        if (-not $Os) { throw 'register exige -Os.' }
        $settings = if (Test-Path -LiteralPath $Config) { Read-VmctlConfig $Config } else {
            @{ schemaVersion = 1; targets = @{} }
        }
        if ($settings.targets.ContainsKey($Vm)) { throw "La VM '$Vm' existe deja. Modifiez le fichier $Config pour la mettre a jour." }
        $entry = @{ os = $Os; hypervisor = 'none'; transport = $Transport }
        if ($HostName) { $entry.host = $HostName }
        if ($UserName) { $entry.user = $UserName }
        if ($Port) { $entry.port = $Port }
        if ($Shell) { $entry.shell = $Shell }
        if ($Hypervisor) { $entry.hypervisor = $Hypervisor }
        if ($entry.hypervisor -eq 'hyperv') { $entry.vmName = if ($HyperVName) { $HyperVName } else { $Vm } }
        $settings.targets[$Vm] = $entry
        $null = Get-VmctlTarget $settings $Vm
        $configFull = [IO.Path]::GetFullPath($Config)
        $null = New-Item -ItemType Directory -Path (Split-Path $configFull -Parent) -Force
        $temporary = "$configFull.$([Guid]::NewGuid().ToString('N')).tmp"
        try {
            $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporary -Encoding utf8
            Move-Item -LiteralPath $temporary -Destination $configFull -Force
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
        Write-Output "VM enregistree : $Vm ($configFull)"
        exit 0
    }
    $settings = Read-VmctlConfig $Config
    if ($Action -eq 'list') {
        $settings.targets.GetEnumerator() | Sort-Object Key | ForEach-Object {
            [pscustomobject]@{ Vm = $_.Key; HostName = $(if ($_.Value.ContainsKey('host')) { $_.Value.host } else { '' }); OS = $_.Value.os;
                Hypervisor = $_.Value.hypervisor; Transport = (Get-VmctlTransport $_.Value) }
        } | Format-Table -AutoSize
        exit 0
    }
    $target = Get-VmctlTarget $settings $Vm
    if ($PSBoundParameters.ContainsKey('Transport')) {
        $target.transport = $Transport
        $null = Get-VmctlTarget $settings $Vm
    }
    if (($Credential -or $CredentialFile) -and (Get-VmctlTransport $target) -ne 'psdirect') { throw 'Credential/CredentialFile sont reserves a PowerShell Direct.' }
    $authentication = @{Credential=$Credential;CredentialFile=$CredentialFile}
    if ($Action -eq 'streaming-access') {
        $secretPath=Join-Path $env:LOCALAPPDATA "vmctl\credentials\apollo-$Vm.clixml"
        if (-not (Test-Path -LiteralPath $secretPath)) { throw 'Acces Apollo chiffre introuvable pour cette VM et cet utilisateur.' }
        $scriptPath=Join-Path $PSScriptRoot 'scripts\Show-ApolloAccess.ps1'
        $code="& '"+$scriptPath.Replace("'","''")+"' -Vm '"+$Vm.Replace("'","''")+"'"
        $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $winps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $process=Start-Process -FilePath $winps -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded -WindowStyle Hidden -PassThru
        @{state='dialog-launched';pid=$process.Id;vm=$Vm} | ConvertTo-Json
        exit 0
    }
    if ($Action -eq 'streaming-install') {
        if ($target.os -ne 'windows' -or $target.hypervisor -ne 'hyperv' -or (Get-VmctlTransport $target) -ne 'psdirect') { throw 'streaming-install exige une VM Windows Hyper-V locale utilisant Direct.' }
        if ($Credential) { throw 'streaming-install accepte -CredentialFile ; sinon une fenetre de saisie est ouverte.' }
        Import-Module (Join-Path $PSScriptRoot 'src/StreamingSupport.psm1') -Force
        $sessionPath=Join-Path $env:LOCALAPPDATA "vmctl\streaming-sessions\$Vm.json"
        # Recover a live older setup referenced by an explicit report directory.
        # Early sessions did not yet keep a per-directory copy of their metadata.
        if($ReportDirectory -and (Test-Path -LiteralPath (Join-Path $ReportDirectory 'streaming-status.json'))) {
            $previous=Get-Content -LiteralPath (Join-Path $ReportDirectory 'streaming-status.json') -Raw|ConvertFrom-Json
            $priorProcess=Get-Process -Id $previous.pid -ErrorAction SilentlyContinue
            if($previous.vm -eq $Vm -and $previous.state -eq 'failed' -and $priorProcess -and $priorProcess.ProcessName -eq 'pwsh') {
                $folders=@(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'vmctl\work') -Directory -Filter 'setup-session-*'|Where-Object {
                    $_.Name -match '^setup-session-[a-f0-9]{32}$' -and [Math]::Abs(($_.CreationTimeUtc-$priorProcess.StartTime.ToUniversalTime()).TotalSeconds) -lt 2 -and (Test-Path -LiteralPath (Join-Path $_.FullName 'guest-credential.clixml'))
                })
                if($folders.Count -eq 1 -and $target.ContainsKey('user')) {
                    $cached=Import-Clixml -LiteralPath (Join-Path $folders[0].FullName 'guest-credential.clixml')
                    $expires=[DateTimeOffset]$priorProcess.StartTime.ToUniversalTime().AddMinutes(30)
                    if($cached.UserName -ieq $target.user -and (Test-VmctlStreamingSessionFreshness $expires)) {
                        @{vm=$Vm;vmName=$target.vmName;vmId=$(if($target.ContainsKey('vmId')){$target.vmId}else{''});pid=$priorProcess.Id;startTicks=$priorProcess.StartTime.ToUniversalTime().Ticks;directory=$folders[0].FullName;expires=$expires.ToString('o');state='waiting-retry';statusFile=[IO.Path]::GetFullPath((Join-Path $ReportDirectory 'streaming-status.json'))}|ConvertTo-Json|Set-Content -LiteralPath $sessionPath
                    }
                    $cached=$null
                }
            }
        }
        if(Test-Path -LiteralPath $sessionPath) {
            $session=Get-Content -LiteralPath $sessionPath -Raw|ConvertFrom-Json
            $existing=Get-Process -Id $session.pid -ErrorAction SilentlyContinue
            if($existing -and $existing.ProcessName -eq 'pwsh' -and $existing.StartTime.ToUniversalTime().Ticks -eq $session.startTicks -and (Test-VmctlStreamingSessionFreshness -Expires $session.expires)) {
                if($session.vmName -ine $target.vmName -or ($target.ContainsKey('vmId') -and $session.vmId -ine $target.vmId)){throw 'Existing setup session belongs to another VM.'}
                if($session.state -eq 'waiting-retry'){
                    @{open=[bool]$Open}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $session.directory 'retry.json') -Encoding utf8
                    $state='retry-requested'
                } else {$state='already-running'}
                @{state=$state;pid=$session.pid;statusFile=$session.statusFile;sessionExpires=$session.expires}|ConvertTo-Json
                exit 0
            }
        }
        if (-not $ReportDirectory) { $ReportDirectory=Join-Path $env:LOCALAPPDATA "vmctl\reports\streaming\$Vm" }
        $recipeArgs=@{Vm=$Vm;Config=[IO.Path]::GetFullPath($Config);ReportDirectory=[IO.Path]::GetFullPath($ReportDirectory)}
        if($Open){$recipeArgs.Open=$true}
        if ($CredentialFile) { $recipeArgs.CredentialFile=[IO.Path]::GetFullPath($CredentialFile) }
        if ($UserName) { $recipeArgs.UserName=$UserName }
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        $principal=[Security.Principal.WindowsPrincipal]::new($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            & (Join-Path $PSScriptRoot 'scripts\Start-StreamingSession.ps1') @recipeArgs
        } else {
            $literalArgs=@($recipeArgs.GetEnumerator() | ForEach-Object { if($_.Value -is [bool]){'-'+$_.Key}else{'-'+$_.Key+" '"+$_.Value.Replace("'","''")+"'"} })
            $recipePath=(Join-Path $PSScriptRoot 'scripts\Start-StreamingSession.ps1').Replace("'","''")
            $code="& '$recipePath' "+($literalArgs -join ' ')
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
            $process=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded -Verb RunAs -WindowStyle Hidden -PassThru
            @{state='launched';pid=$process.Id;reportDirectory=$recipeArgs.ReportDirectory;statusFile=(Join-Path $recipeArgs.ReportDirectory 'streaming-status.json')} | ConvertTo-Json
        }
        exit 0
    }
    switch ($Action) {
        'streaming-open' {
            if ($target.os -ne 'windows' -or $target.hypervisor -ne 'hyperv' -or (Get-VmctlTransport $target) -ne 'psdirect') { throw 'streaming-open requires a local Hyper-V Windows target.' }
            $openArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'scripts\Open-StreamingHost.ps1'),'-Vm',$Vm,'-VmName',$target.vmName,'-Application',$Application,'-Mode',$Mode)
            if($target.ContainsKey('vmId')){$openArgs+=@('-VmId',$target.vmId)}
            if($Reconnect){$openArgs+='-Reconnect'}
            if($PSBoundParameters.ContainsKey('Fps')){$openArgs+=@('-Fps',[string]$Fps)}
            $openTimeout=if($PSBoundParameters.ContainsKey('TimeoutSeconds')){$TimeoutSeconds}else{300}
            $result=Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') $openArgs -TimeoutSeconds $openTimeout
        }
        'streaming-forget' {
            if ($target.os -ne 'windows' -or $target.hypervisor -ne 'hyperv' -or (Get-VmctlTransport $target) -ne 'psdirect') { throw 'streaming-forget requires a local Hyper-V Windows target.' }
            $forgetArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'scripts\Remove-StreamingHost.ps1'),'-Vm',$Vm,'-VmName',$target.vmName)
            if($target.ContainsKey('vmId')){$forgetArgs+=@('-VmId',$target.vmId)}
            if($HostName){$forgetArgs+=@('-HostName',$HostName)}
            $result=Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') $forgetArgs -TimeoutSeconds $TimeoutSeconds
        }
        { $_ -in @('streaming-status','streaming-display-fix','streaming-display-restore','streaming-video-test','streaming-video-restore') } {
            if ($target.os -ne 'windows' -or $target.hypervisor -ne 'hyperv' -or (Get-VmctlTransport $target) -ne 'psdirect') { throw 'streaming-status requires a local Hyper-V Windows target.' }
            if ($Diagnostics -and $Action -ne 'streaming-status') { throw '-Diagnostics is supported only with streaming-status.' }
            if ($Action -eq 'streaming-video-test' -and -not $Encoder) { throw 'streaming-video-test requires -Encoder software or nvenc.' }
            if ($Encoder -and $Action -ne 'streaming-video-test') { throw '-Encoder is supported only with streaming-video-test.' }
            $streamingArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'scripts\Get-StreamingStatus.ps1'),'-Vm',$Vm,'-VmName',$target.vmName)
            if($target.ContainsKey('vmId')){$streamingArgs+=@('-VmId',$target.vmId)}
            if ($HostName) { $streamingArgs+=@('-HostName',$HostName) }
            if ($Diagnostics) { $streamingArgs+='-Diagnostics' }
            if ($Encoder) { $streamingArgs+=@('-Encoder',$Encoder) }
            if ($DefaultAdapter) { $streamingArgs+='-DefaultAdapter' }
            if ($ConsoleDisplay) { $streamingArgs+='-ConsoleDisplay' }
            if ($OnlyDisplay) { $streamingArgs+='-OnlyDisplay' }
            if ($PrimaryDisplay) { $streamingArgs+='-PrimaryDisplay' }
            if ($DisableRealtimePriority) { $streamingArgs+='-DisableRealtimePriority' }
            if ($EnableModernCodecs) { $streamingArgs+='-EnableModernCodecs' }
            $streamingArgs+=@('-Mode',$Action.Substring(10))
            $result=Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') $streamingArgs -TimeoutSeconds $TimeoutSeconds
        }
        { $_ -in @('gpu-setup','gpu-status','gpu-sync','gpu-remove','gpu-task-test') } {
            $gpuMode=$Action.Substring(4)
            $gpuTimeout=if ($PSBoundParameters.ContainsKey('TimeoutSeconds')) { $TimeoutSeconds } else { 900 }
            $result=Invoke-VmctlGpu -Target $target -Mode $gpuMode -GpuName $GpuName -Percent $GpuPercent -Elevate:$Elevate -TimeoutSeconds $gpuTimeout
        }
        { $_ -in @('capabilities', 'screenshot', 'move', 'click', 'type', 'key', 'scroll', 'drag') } {
            $result = Invoke-VmctlConsole -Target $target -Vm $Vm -Action $Action -OutFile $OutFile -Frame $Frame `
                -Text $Text -Keys $Keys -X $X -Y $Y -ToX $ToX -ToY $ToY -ButtonIndex $ButtonIndex `
                -Count $Count -Delta $Delta -MaxFrameAgeSeconds $MaxFrameAgeSeconds -Elevate:$Elevate -TimeoutSeconds $TimeoutSeconds
        }
        'exec' {
            if (-not $Command) { throw 'exec exige -Command.' }
            $result = Invoke-VmctlCommand $target $Command -TimeoutSeconds $TimeoutSeconds @authentication
        }
        'run' {
            if (-not $File) { throw 'run exige -File.' }
            $code = Get-Content -LiteralPath $File -Raw -Encoding utf8
            $result = Invoke-VmctlCommand $target $code -AsFile -TimeoutSeconds $TimeoutSeconds @authentication
        }
        'upload' {
            if (-not $Source -or -not $Destination) { throw 'upload exige -Source et -Destination.' }
            $result = Invoke-VmctlUpload $target $Source $Destination -Recursive:$Recursive -TimeoutSeconds $TimeoutSeconds @authentication
        }
        'doctor' {
            $probe = if ($target.os -eq 'windows') {
                @'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$osInfo = Get-CimInstance Win32_OperatingSystem
[pscustomobject]@{ host = $env:COMPUTERNAME; user = $identity.Name; os = $osInfo.Caption;
    version = $osInfo.Version; admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);
    powershell = $PSVersionTable.PSVersion.ToString() } | ConvertTo-Json -Compress
'@
            } else { 'hostname; id; uname -sr' }
            $result = Invoke-VmctlCommand $target $probe -TimeoutSeconds ([Math]::Min(30, $TimeoutSeconds)) @authentication
            if ($result.ExitCode -ne 0) {
                [Console]::Error.WriteLine((Get-VmctlDiagnosticHint $result.Stderr -Transport (Get-VmctlTransport $target)))
            }
        }
        default {
            if ($Action -eq 'checkpoint' -and -not $Name) { throw 'checkpoint exige -Name.' }
            $result = Invoke-VmctlHyperV $target $Action -Name $Name -RemoveCheckpoints:$RemoveCheckpoints -DisableAutomaticCheckpoints:$DisableAutomaticCheckpoints -TimeoutSeconds $TimeoutSeconds
        }
    }
    if ($result.Stdout) { [Console]::Out.Write($result.Stdout) }
    if ($result.Stderr) { [Console]::Error.WriteLine($result.Stderr.TrimEnd()) }
    exit $result.ExitCode
} catch {
    [Console]::Error.WriteLine("vmctl : $($_.Exception.Message)")
    exit 2
}
