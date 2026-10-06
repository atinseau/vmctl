#requires -Version 5.1
param([Parameter(Mandatory)][string]$UserName,[Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
Add-Type -AssemblyName System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text='vmctl - Connexion a la VM'
$form.Size=New-Object Drawing.Size(490,235)
$form.StartPosition='CenterScreen'
$form.TopMost=$true
$form.FormBorderStyle='FixedDialog'
$form.MaximizeBox=$false
$label=New-Object Windows.Forms.Label
$label.Text="Mot de passe Windows de $UserName (pas le PIN)."
$label.Location=New-Object Drawing.Point(20,20)
$label.Size=New-Object Drawing.Size(440,40)
$passwordBox=New-Object Windows.Forms.TextBox
$passwordBox.Location=New-Object Drawing.Point(20,70)
$passwordBox.Size=New-Object Drawing.Size(435,25)
$passwordBox.UseSystemPasswordChar=$true
$button=New-Object Windows.Forms.Button
$button.Text='Connecter'
$button.Location=New-Object Drawing.Point(335,120)
$button.Size=New-Object Drawing.Size(120,32)
$button.DialogResult=[Windows.Forms.DialogResult]::OK
$form.AcceptButton=$button
$form.Controls.AddRange(@($label,$passwordBox,$button))

if ($form.ShowDialog() -ne [Windows.Forms.DialogResult]::OK -or -not $passwordBox.Text) { $form.Dispose(); throw 'Credential entry cancelled.' }
$credential=New-Object Management.Automation.PSCredential($UserName,(ConvertTo-SecureString $passwordBox.Text -AsPlainText -Force))
$passwordBox.Clear()
$form.Dispose()
$credential | Export-Clixml -LiteralPath $Destination
