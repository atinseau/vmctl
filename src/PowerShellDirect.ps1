#requires -Version 7.2
function Invoke-VmctlDirect {
    param([hashtable]$Target, [hashtable]$Request, [Management.Automation.PSCredential]$Credential,
        [string]$CredentialFile, [int]$TimeoutSeconds = 120)
    if (-not $IsWindows) { throw 'PowerShell Direct exige un hote Windows Hyper-V local.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $hypervGroup = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-578')
    if (-not ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or $principal.IsInRole($hypervGroup))) {
        throw 'PowerShell Direct exige les droits Hyper-V sur l hote. Ouvrez une fois le terminal en administrateur.'
    }
    if ($Credential -and $CredentialFile) { throw 'Choisissez -Credential ou -CredentialFile.' }
    if ($CredentialFile) { $Credential = Import-Clixml -LiteralPath $CredentialFile -ErrorAction Stop }
    if ($Credential -and $Credential -isnot [Management.Automation.PSCredential]) { throw 'Le fichier doit contenir un PSCredential exporte par cet utilisateur Windows sur cet hote.' }
    if (-not $Credential) {
        $user = if ($Target.ContainsKey('user')) { [string]$Target.user } else { '' }
        $Credential = Get-Credential -UserName $user -Message ('Compte et mot de passe de la VM ' + $Target.vmName + ' (pas le PIN)')
    }
    if (-not $Credential) { throw 'Connexion annulee.' }
    $Request.vmName = $Target.vmName
    $Request.vmId = if ($Target.ContainsKey('vmId')) { $Target.vmId } else { '' }
    $Request.user = $Credential.UserName
    $Request.password = ConvertFrom-SecureString $Credential.Password
    $worker = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts/Invoke-PowerShellDirect.ps1'))
    $exe = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    try {
        $local = Invoke-VmctlProcess $exe @('-NoLogo','-NoProfile','-NonInteractive','-File',$worker) -InputText ($Request | ConvertTo-Json -Depth 5 -Compress) -TimeoutSeconds $TimeoutSeconds
        if ($local.ExitCode -ne 0) { return $local }
        if (-not $local.Stdout) { throw 'Le worker PowerShell Direct n a pas produit de reponse.' }
        return $local.Stdout | ConvertFrom-Json
    } finally { $Request.Remove('password'); $Request.Remove('user') }
}
