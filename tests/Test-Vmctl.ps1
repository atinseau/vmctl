#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/Vmctl.psm1') -Force
$scratch = Join-Path $root ('work/tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch -Force
$script:passed = 0
function Assert-That([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "ECHEC : $Label" }
    $script:passed++
    Write-Output "OK : $Label"
}
function Invoke-LocalRunner([string]$Code, [switch]$AsFile, [string]$Shell = 'powershell.exe') {
    $plan = New-VmctlExecution @{host='test';os='windows';shell=$Shell} $Code -AsFile:$AsFile
    $remoteArgs = $plan.Arguments[-1].Split(' ')
    $exe = if ($Shell -eq 'pwsh.exe') { Join-Path $PSHOME 'pwsh.exe' } else { 'powershell.exe' }
    return Invoke-VmctlProcess $exe $remoteArgs[1..($remoteArgs.Length - 1)] -InputText $plan.InputText -TimeoutSeconds 20
}
try {
    foreach ($shell in @('powershell.exe', 'pwsh.exe')) {
        $code = @'
$x = 'élève "double" ''simple'' $literal `backtick ; & |'
Write-Output $x
'@
        $result = Invoke-LocalRunner $code -Shell $shell
        Assert-That ($result.ExitCode -eq 0 -and $result.Stdout.Trim() -eq 'élève "double" ''simple'' $literal `backtick ; & |') "Unicode et caracteres shell intacts ($shell)"
        Assert-That ([string]::IsNullOrEmpty($result.Stderr)) "Pas de CLIXML parasite ($shell)"
        $result = Invoke-LocalRunner '[pscustomobject]@{Vm="formatting-check";Ready=$true}' -Shell $shell
        Assert-That ($result.ExitCode -eq 0 -and $result.Stdout -match 'formatting-check' -and $result.Stdout -match 'True') "Objets PowerShell formates avant exit ($shell)"
        $result = Invoke-LocalRunner 'cmd.exe /c exit 7' -Shell $shell
        Assert-That ($result.ExitCode -eq 7) "Code de retour natif conserve ($shell)"
        $result = Invoke-LocalRunner 'throw "erreur attendue"' -Shell $shell
        Assert-That ($result.ExitCode -eq 1 -and $result.Stderr -match 'erreur attendue') "Exception distante sur stderr ($shell)"
        $result = Invoke-LocalRunner 'Write-Error "erreur attendue"; Write-Output "ne doit pas arriver"' -Shell $shell
        Assert-That ($result.ExitCode -eq 1 -and $result.Stdout -notmatch 'ne doit pas arriver') "Erreur PowerShell arretee ($shell)"
        $result = Invoke-LocalRunner 'exit 23' -Shell $shell
        Assert-That ($result.ExitCode -eq 23) "exit explicite conserve ($shell)"
    }
    $result = Invoke-LocalRunner 'Write-Output ($PSScriptRoot); Write-Output ($PSCommandPath)' -AsFile
    $remoteFile = ($result.Stdout.Trim() -split '\r?\n')[-1]
    Assert-That ($result.ExitCode -eq 0 -and $remoteFile -match 'vmctl-.*\.ps1$') 'run fournit un vrai fichier et PSScriptRoot'
    Assert-That (-not (Test-Path -LiteralPath $remoteFile)) 'Fichier distant temporaire supprime apres run'
    $largeCode = ('# commentaire tres long' + "`n") * 3000 + 'Write-Output "long script OK"'
    $result = Invoke-LocalRunner $largeCode -AsFile
    Assert-That ($result.ExitCode -eq 0 -and $result.Stdout.Trim() -eq 'long script OK') 'Script de plus de 64 Ko sans limite de ligne de commande'

    $timeout = Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-Command','Start-Sleep 10') -TimeoutSeconds 1
    Assert-That ($timeout.ExitCode -eq 124 -and $timeout.Stderr -match 'peut continuer') 'Timeout explicite sans nouvelle tentative'

    $config = Join-Path $scratch 'targets.json'
    $cli = Join-Path $root 'vmctl.ps1'
    $runtime = Join-Path $PSHOME 'pwsh.exe'
    $guard = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'storage','-Vm','test','-Config',$config,'-RemoveCheckpoints')
    Assert-That ($guard.ExitCode -eq 2 -and $guard.Stderr -match 'RemoveCheckpoints exige compact') 'Suppression de checkpoints refusee hors compact avant acces Hyper-V'
    $guard = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'start','-Vm','test','-Config',$config,'-DisableAutomaticCheckpoints')
    Assert-That ($guard.ExitCode -eq 2 -and $guard.Stderr -match 'DisableAutomaticCheckpoints exige compact ou checkpoint') 'Option automatique refusee hors operation autorisee'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'register','-Vm','test',
        '-HostName','example.invalid','-Os','linux','-Config',$config)
    Assert-That ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $config)) 'Enregistrement CLI et creation de configuration'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'streaming-install','-Vm','test','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'streaming-install exige') 'Installation streaming refusee sur cible SSH avant installation ou elevation'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'gpu-setup','-Vm','test','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'GPU automation requires') 'Configuration GPU refusee sur cible non Hyper-V avant toute mutation'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'streaming-status','-Vm','test','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'streaming-status requires') 'Diagnostic Apollo refuse sur cible SSH avant lecture des identifiants ou appel reseau'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'streaming-forget','-Vm','test','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'streaming-forget requires') 'Suppression de profil refusee sur cible SSH avant mutation'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'streaming-video-test','-Vm','test','-Encoder','software','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'streaming-status requires') 'Changement encodeur refuse sur cible SSH avant mutation'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'streaming-video-test','-Vm','test','-Encoder','software','-Diagnostics','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'Diagnostics is supported only') 'Diagnostics et changement encodeur refuses ensemble avant mutation'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'gpu-setup','-Vm','test','-Encoder','software','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'Encoder is supported only') 'Option encodeur refusee hors commande video'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'gpu-setup','-Vm','test','-ConsoleDisplay','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'ConsoleDisplay require streaming-video-test') 'Options de capture refusees hors diagnostic video avant mutation'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'gpu-setup','-Vm','test','-OnlyDisplay','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'OnlyDisplay requires streaming-video-test') 'Ecran virtuel seul refuse hors commande video avant mutation'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'streaming-video-test','-Vm','test','-Encoder','nvenc','-OnlyDisplay','-ConsoleDisplay','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'mutually exclusive') 'Deux profils de moniteur incompatibles refuses avant mutation'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'streaming-access','-Vm','test','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'Acces Apollo chiffre introuvable') 'Acces Apollo absent refuse avant ouverture de fenetre'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'help')
    Assert-That ($result.ExitCode -eq 0 -and $result.Stdout -match 'streaming-install') 'Recette streaming exposee dans le CLI public'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'exec','-Vm','inconnue','-Command','echo nope','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and $result.Stderr -match 'VM inconnue') 'VM inconnue refusee avant connexion'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'register','-Vm','test',
        '-HostName','different.invalid','-Os','linux','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and (Read-VmctlConfig $config).targets.test.host -eq 'example.invalid') 'Enregistrement existant preserve'
    $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'register','-Vm','bad',
        '-HostName','-oProxyCommand=bad','-Os','linux','-Config',$config)
    Assert-That ($result.ExitCode -eq 2 -and -not (Read-VmctlConfig $config).targets.ContainsKey('bad')) 'Injection dans alias SSH refusee'

    $sshOptions = @(Get-VmctlSshOptions @{host='test';os='windows';port=2222;user='test'})
    Assert-That ($sshOptions -contains 'StrictHostKeyChecking=yes' -and $sshOptions -contains 'BatchMode=yes') 'Verification hote stricte et aucun prompt de mot de passe'
    $sshOptions = @(Get-VmctlSshOptions @{host='test';os='windows';identityFile='C:\path with spaces\key';knownHostsFile='C:\path with spaces\known_hosts'})
    Assert-That ($sshOptions -contains 'C:\path with spaces\key' -and $sshOptions -contains 'UserKnownHostsFile=C:\path with spaces\known_hosts') 'Cle privee et fichier known_hosts dedies'
    Assert-That ((Get-VmctlDiagnosticHint 'Permission denied (publickey).') -match 'Authentification') 'Diagnostic authentification'
    Assert-That ((Get-VmctlDiagnosticHint 'Host key verification failed.') -match 'Identite') 'Diagnostic cle hote'

    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (Test-Path -LiteralPath $compiler) {
        $fakeSsh = Join-Path $scratch 'ssh.exe'
        $fixture = Join-Path $PSScriptRoot 'fixtures/NativeStub.cs'
        $compiled = Invoke-VmctlProcess $compiler @('/nologo','/target:exe',"/out:$fakeSsh",$fixture)
        if ($compiled.ExitCode -ne 0) { throw $compiled.Stdout + $compiled.Stderr }
        Copy-Item -LiteralPath $fakeSsh -Destination (Join-Path $scratch 'scp.exe')
        $originalPath = $env:Path
        $originalTestExit = $env:VMCTL_TEST_EXITCODE
        $originalTestStderr = $env:VMCTL_TEST_STDERR
        try {
            $env:Path = "$scratch;$originalPath"
            $env:VMCTL_TEST_EXITCODE = '0'
            $env:VMCTL_TEST_STDERR = ''
            $quotedCode = '$literal = ''élève "quotes" & | $variable''; Write-Output $literal'
            $launcher = Join-Path $root 'bin/vmctl.ps1'
            if (Test-Path -LiteralPath $launcher) {
                $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$launcher,'exec','-Vm','test',
                    '-Config',$config,'-Command',$quotedCode)
                Assert-That ($result.ExitCode -eq 0 -and $result.Stdout.TrimEnd() -eq $quotedCode) 'Lanceur global : arguments complexes transmis intacts'
            }
            $uploadSource = Join-Path $scratch 'fichier avec espaces.txt'
            'fixture' | Set-Content -LiteralPath $uploadSource -Encoding utf8
            $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'upload','-Vm','test',
                '-Config',$config,'-Source',$uploadSource,'-Destination','/tmp/path with spaces.txt')
            $scpArgs = $result.Stdout -split [char]30
            Assert-That ($result.ExitCode -eq 0 -and $scpArgs[-2] -eq $uploadSource -and
                $scpArgs[-1] -eq 'example.invalid:/tmp/path with spaces.txt') 'upload : chemins avec espaces transmis comme arguments separes'
            $env:VMCTL_TEST_EXITCODE = '255'
            $env:VMCTL_TEST_STDERR = 'Permission denied (publickey).'
            $result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',$cli,'doctor','-Vm','test','-Config',$config)
            Assert-That ($result.ExitCode -eq 255 -and $result.Stderr -match 'Authentification refusee') 'doctor CLI : code SSH et diagnostic conserves'
        } finally {
            $env:Path = $originalPath
            $env:VMCTL_TEST_EXITCODE = $originalTestExit
            $env:VMCTL_TEST_STDERR = $originalTestStderr
        }
    } else { Write-Output 'SKIP : compilateur de fixture SSH/SCP indisponible.' }

    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $sh = if ($git) { Join-Path (Split-Path (Split-Path $git.Source -Parent) -Parent) 'usr/bin/sh.exe' } else { '' }
    if ($sh -and (Test-Path -LiteralPath $sh)) {
        $linuxCode = "printf '%s\n' 'dollar `$ intact'; exit 9"
        $plan = New-VmctlExecution @{host='test';os='linux'} $linuxCode
        $result = Invoke-VmctlProcess $sh @('-s') -InputText $plan.InputText -TimeoutSeconds 10
        Assert-That ($result.ExitCode -eq 9 -and $result.Stdout.Trim() -eq 'dollar $ intact') 'Execution POSIX et code retour'
    } else { Write-Output 'SKIP : shell POSIX indisponible sur cet hote.' }
    Write-Output "$script:passed verifications reussies. Aucun acces a une VM pendant ces tests."
} finally {
    # Keep scratch data within work; avoid recursive removal of any computed path.
    Write-Verbose "Fichiers de test : $scratch"
}
