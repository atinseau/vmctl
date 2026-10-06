#requires -Version 7.2
function Get-VmctlSshOptions {
    param([hashtable]$Target, [switch]$Scp)
    $options = @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3')
    if ($Target.ContainsKey('port')) {
        $portFlag = if ($Scp) { '-P' } else { '-p' }
        $options += @($portFlag, [string]$Target.port)
    }
    if ($Target.ContainsKey('identityFile')) { $options += @('-i', [string]$Target.identityFile) }
    if ($Target.ContainsKey('knownHostsFile')) { $options += @('-o', "UserKnownHostsFile=$($Target.knownHostsFile)") }
    if (-not $Scp -and $Target.ContainsKey('user')) { $options += @('-l', $Target.user) }
    return $options
}

function New-VmctlWindowsExecution {
    param([hashtable]$Target, [string]$Script, [switch]$AsFile)
    if ([System.Text.Encoding]::UTF8.GetByteCount($Script) -gt 1048576) {
        throw 'Script trop volumineux (maximum 1 Mio). Envoyez les fichiers avec upload.'
    }
    $shell = if ($Target.ContainsKey('shell')) { $Target.shell } else { 'powershell.exe' }
    if ($shell -notin @('powershell.exe','pwsh.exe')) { throw 'Shell Windows invalide.' }
        # Only a fixed ASCII command crosses the remote login shell. User code uses UTF-8 stdin.
        $runner = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$vmctlFile = $null
$vmctlExit = 0
try {
    $vmctlCode = [Console]::In.ReadToEnd()
    $global:LASTEXITCODE = $null
    __INVOKE__
    $vmctlSuccess = $?
    if ($null -ne $global:LASTEXITCODE) { $vmctlExit = [int]$global:LASTEXITCODE }
    if (-not $vmctlSuccess -and $vmctlExit -eq 0) { $vmctlExit = 1 }
} catch {
    [Console]::Error.WriteLine($_.ToString())
    $vmctlExit = 1
} finally {
    if ($vmctlFile -and (Test-Path -LiteralPath $vmctlFile)) {
        Remove-Item -LiteralPath $vmctlFile -Force -ErrorAction SilentlyContinue
    }
}
exit $vmctlExit
'@
        $invocation = if ($AsFile) {
            @'
$vmctlFile = Join-Path $env:TEMP ('vmctl-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    [IO.File]::WriteAllText($vmctlFile, $vmctlCode, (New-Object System.Text.UTF8Encoding($true)))
    & $vmctlFile | Out-Default
'@
        } else { '& ([scriptblock]::Create($vmctlCode)) | Out-Default' }
        $runner = $runner.Replace('__INVOKE__', $invocation)
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runner))
    return [pscustomobject]@{ Shell=$shell; EncodedCommand=$encoded; AsFile=[bool]$AsFile }
}

function New-VmctlExecution {
    param([hashtable]$Target, [string]$Script, [switch]$AsFile)
    if ([Text.Encoding]::UTF8.GetByteCount($Script) -gt 1048576) { throw 'Script trop volumineux (maximum 1 Mio). Envoyez les fichiers avec upload.' }
    $options = @(Get-VmctlSshOptions $Target)
    if ($Target.os -eq 'windows') {
        $execution = New-VmctlWindowsExecution $Target $Script -AsFile:$AsFile
        $policy = if ($AsFile) { ' -ExecutionPolicy Bypass' } else { '' }
        $remote = "$($execution.Shell) -NoLogo -NoProfile -NonInteractive -OutputFormat Text$policy -EncodedCommand $($execution.EncodedCommand)"
        $inputText = $Script
    } else {
        $shell = if ($Target.ContainsKey('shell')) { $Target.shell } else { 'sh' }
        $remote = "$shell -s"
        $inputText = $Script.Replace("`r`n", "`n") + "`n"
    }
    return [pscustomobject]@{ Arguments = @($options) + @('--', $Target.host, $remote); InputText = $inputText }
}

function Invoke-VmctlCommand {
    param([hashtable]$Target, [string]$Script, [switch]$AsFile, [int]$TimeoutSeconds = 120,
        [Management.Automation.PSCredential]$Credential, [string]$CredentialFile)
    if ((Get-VmctlTransport $Target) -eq 'psdirect') {
        $execution = New-VmctlWindowsExecution $Target $Script -AsFile:$AsFile
        $request = @{ action='exec'; shell=$execution.Shell; runner=$execution.EncodedCommand; script=$Script; asFile=[bool]$AsFile }
        return Invoke-VmctlDirect $Target $request -Credential $Credential -CredentialFile $CredentialFile -TimeoutSeconds $TimeoutSeconds
    }
    $execution = New-VmctlExecution $Target $Script -AsFile:$AsFile
    return Invoke-VmctlProcess -Executable ssh -Arguments $execution.Arguments -InputText $execution.InputText -TimeoutSeconds $TimeoutSeconds
}

function Invoke-VmctlUpload {
    param([hashtable]$Target, [string]$Source, [string]$Destination, [switch]$Recursive,
        [int]$TimeoutSeconds = 120, [Management.Automation.PSCredential]$Credential, [string]$CredentialFile)
    $sourcePath = (Resolve-Path -LiteralPath $Source -ErrorAction Stop).ProviderPath
    if ((Get-Item -LiteralPath $sourcePath).PSIsContainer -and -not $Recursive) {
        throw 'Un dossier exige -Recursive.'
    }
    if (-not $Destination -or $Destination -match '[\r\n]' -or $Destination.StartsWith('-')) {
        throw 'Destination distante invalide.'
    }
    if ((Get-VmctlTransport $Target) -eq 'psdirect') {
        $request = @{action='upload';source=$sourcePath;destination=$Destination;recursive=[bool]$Recursive}
        return Invoke-VmctlDirect $Target $request -Credential $Credential -CredentialFile $CredentialFile -TimeoutSeconds $TimeoutSeconds
    }
    $hostPart = $Target.host
    if ($hostPart.Contains(':')) { $hostPart = "[$hostPart]" }
    if ($Target.ContainsKey('user')) { $hostPart = "$($Target.user)@$hostPart" }
    $options = @(Get-VmctlSshOptions $Target -Scp)
    if ($Recursive) { $options += '-r' }
    # Modern scp uses SFTP. Never fall back to the legacy remote-shell protocol (-O).
    return Invoke-VmctlProcess -Executable scp -Arguments ($options + @('--', $sourcePath,
        "${hostPart}:$Destination")) -TimeoutSeconds $TimeoutSeconds
}

function Get-VmctlDiagnosticHint {
    param([string]$ErrorText, [string]$Transport = 'ssh')
    if ($Transport -eq 'psdirect') { return 'PowerShell Direct : verifiez les droits Hyper-V de l hote, la VM demarree et le compte/mot de passe de la VM (pas le PIN). Aucun reseau ou serveur SSH requis.' }
    if ($ErrorText -match 'Delai depasse') {
        return 'Diagnostic interrompu par le delai maximal. Verifiez la resolution du nom, le reseau et le service SSH de la VM.'
    }
    if ($ErrorText -match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED') {
        return 'Identite SSH inconnue ou modifiee. Verifiez la cle hote via la console, puis faites une connexion SSH manuelle pour la valider.'
    }
    if ($ErrorText -match 'Permission denied|Authentication failed') {
        return 'Authentification refusee. Verifiez le compte et sa cle SSH (ssh-agent ou IdentityFile dans ~/.ssh/config).'
    }
    if ($ErrorText -match 'timed out|Connection refused|No route to host|Could not resolve hostname') {
        return 'Connexion indisponible. Verifiez que la VM et sshd sont demarres, puis son adresse, son port, son reseau et son pare-feu.'
    }
    return 'La commande a echoue. Consultez stderr et verifiez le shell configure dans la VM.'
}
