#requires -Version 7.2
function Get-VmctlConfigPath {
    if ($env:VMCTL_CONFIG) { return $env:VMCTL_CONFIG }
    if ($IsWindows) { return Join-Path $env:LOCALAPPDATA 'vmctl/targets.json' }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    return Join-Path $base 'vmctl/targets.json'
}

function Read-VmctlConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration introuvable : $Path. Lancez install.ps1 ou utilisez -Config."
    }
    $config = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($config.schemaVersion -ne 1 -or $config.targets -isnot [System.Collections.IDictionary]) {
        throw 'Configuration invalide : schemaVersion doit etre 1 et targets un objet JSON.'
    }
    return $config
}

function Get-VmctlTarget {
    param([hashtable]$Config, [string]$Vm)
    if (-not $Vm -or -not $Config.targets.ContainsKey($Vm)) {
        throw "VM inconnue : '$Vm'. Utilisez vmctl list ou vmctl register."
    }
    $target = $Config.targets[$Vm]
    if ($target -isnot [System.Collections.IDictionary]) { throw "Configuration invalide pour $Vm." }
    if ($target.os -notin @('windows', 'linux')) { throw 'os doit etre windows ou linux.' }
    $transport = Get-VmctlTransport $target
    if ($transport -eq 'psdirect') {
        if ($target.hypervisor -ne 'hyperv' -or $target.os -ne 'windows' -or -not $target.Contains('vmName') -or -not $target.vmName) {
            throw 'psdirect exige os=windows, hypervisor=hyperv et vmName (VM locale).'
        }
        if ($target.Contains('vmId')) { $null = [Guid]::Parse($target.vmId) }
    } elseif (-not $target.Contains('host') -or $target.host -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._:%-]*$') { throw 'Adresse/alias SSH invalide.' }
    if ($target.Contains('user') -and $target.user -notmatch '^[a-zA-Z0-9_][a-zA-Z0-9_.@\\-]*$') {
        throw 'Utilisateur SSH invalide.'
    }
    if ($target.Contains('port') -and ([int]$target.port -lt 1 -or [int]$target.port -gt 65535)) {
        throw 'Port SSH invalide.'
    }
    if ($target.Contains('shell')) {
        $allowed = if ($target.os -eq 'windows') { @('powershell.exe', 'pwsh.exe') } else { @('sh', 'bash') }
        if ($target.shell -notin $allowed) { throw 'Shell invalide pour ce systeme.' }
    }
    return $target
}

function Get-VmctlTransport {
    param([hashtable]$Target)
    if ($Target.ContainsKey('transport') -and $Target.transport -notin @('auto','psdirect','ssh')) { throw 'transport doit etre auto, psdirect ou ssh.' }
    if ($Target.ContainsKey('transport') -and $Target.transport -ne 'auto') { return $Target.transport }
    if ($Target.ContainsKey('hypervisor') -and $Target.hypervisor -eq 'hyperv' -and $Target.os -eq 'windows') { return 'psdirect' }
    return 'ssh'
}
