#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Run once INSIDE the Windows guest, through its console or PowerShell Direct.
$capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
if ($capability.State -ne 'Installed') {
    $result = Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($result.RestartNeeded) { Write-Warning 'Windows demande un redemarrage pour terminer cette installation.' }
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
    $null = New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}
Write-Output 'OpenSSH demarre. Configurez la cle publique du compte invite avant d utiliser vmctl.'
Write-Output 'Empreinte a verifier depuis l hote :'
& ssh-keygen.exe -l -f "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"
