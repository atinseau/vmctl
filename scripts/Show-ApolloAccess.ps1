#requires -Version 5.1
param([Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$Vm)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../src/DataPaths.ps1')
$env:PSModulePath=Join-Path $PSHOME 'Modules'
$path=Join-Path (Get-VmctlDataRoot) "credentials\apollo-$Vm.clixml"
$credential=Import-Clixml -LiteralPath $path
Add-Type -AssemblyName System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text="Apollo - acces administrateur ($Vm)"
$form.Size=New-Object Drawing.Size(510,220)
$form.StartPosition='CenterScreen'
$label=New-Object Windows.Forms.Label
$label.Text="Compte : $($credential.UserName)`r`nMot de passe conserve chiffre pour cet utilisateur sur cet hote."
$label.Location=New-Object Drawing.Point(15,15)
$label.Size=New-Object Drawing.Size(460,45)
$passwordBox=New-Object Windows.Forms.TextBox
$passwordBox.Location=New-Object Drawing.Point(15,65)
$passwordBox.Size=New-Object Drawing.Size(460,25)
$passwordBox.ReadOnly=$true
$passwordBox.UseSystemPasswordChar=$true
$passwordBox.Text=$credential.GetNetworkCredential().Password
$copyButton=New-Object Windows.Forms.Button
$copyButton.Text='Copier le mot de passe'
$copyButton.Location=New-Object Drawing.Point(245,110)
$copyButton.Size=New-Object Drawing.Size(230,30)
$copyButton.Add_Click({[Windows.Forms.Clipboard]::SetText($credential.GetNetworkCredential().Password)}.GetNewClosure())
$form.Controls.AddRange(@($label,$passwordBox,$copyButton))
$null=$form.ShowDialog()
$passwordBox.Clear()
$form.Dispose()
