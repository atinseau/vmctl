#requires -Version 7.2
param([ValidateSet('windowed','fullscreen')][string]$Mode='windowed',[string]$Config)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()
try {
    Import-Module (Join-Path $PSScriptRoot '../src/Vmctl.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/ShortcutSupport.psm1') -Force
    if(-not $Config){$Config=Get-VmctlConfigPath}
    $choices=@(Get-VmctlStreamingChoices -Settings (Read-VmctlConfig $Config))
    if(-not $choices.Count){throw 'Aucune VM Windows Hyper-V configuree pour le streaming. Ajoutez une VM avec vmctl register.'}
    $form=[Windows.Forms.Form]::new()
    try {
        $form.Text=if($Mode -eq 'fullscreen'){'vmctl - Plein ecran'}else{'vmctl - Fenetre'}
        $form.ClientSize=[Drawing.Size]::new(430,175)
        $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.MinimizeBox=$false
        $form.Add_Shown({$this.Activate()})
        $label=[Windows.Forms.Label]::new();$label.Text='Choisis la VM a ouvrir :';$label.AutoSize=$true;$label.Location=[Drawing.Point]::new(20,20)
        $combo=[Windows.Forms.ComboBox]::new();$combo.Location=[Drawing.Point]::new(20,47);$combo.Width=390;$combo.DropDownStyle='DropDownList'
        foreach($choice in $choices){[void]$combo.Items.Add($choice.label)}
        $combo.SelectedIndex=0
        $hint=[Windows.Forms.Label]::new();$hint.Location=[Drawing.Point]::new(20,83);$hint.Size=[Drawing.Size]::new(390,30)
        $hint.Text=if($Mode -eq 'fullscreen'){'Liberer la souris et le clavier : Ctrl + Alt + Maj + Z'}else{'Mode fenetre : preferences Moonlight conservees.'}
        $open=[Windows.Forms.Button]::new();$open.Text='Ouvrir';$open.Location=[Drawing.Point]::new(230,128);$open.DialogResult='OK'
        $cancel=[Windows.Forms.Button]::new();$cancel.Text='Annuler';$cancel.Location=[Drawing.Point]::new(325,128);$cancel.DialogResult='Cancel'
        $form.Controls.AddRange(@($label,$combo,$hint,$open,$cancel));$form.AcceptButton=$open;$form.CancelButton=$cancel
        if($form.ShowDialog() -ne 'OK'){exit 0}
        $selected=$choices[$combo.SelectedIndex].alias
    }finally{$form.Dispose()}
    # Use the public CLI and its existing reconnect, credentials and validation.
    $result=Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-File',(Join-Path $PSScriptRoot '../vmctl.ps1'),'streaming-open','-Vm',$selected,'-Mode',$Mode,'-Reconnect','-Config',$Config) -TimeoutSeconds 320
    if($result.ExitCode -ne 0){throw $result.Stderr}
}catch{
    [void][Windows.Forms.MessageBox]::Show($_.ToString(),'vmctl - Ouverture impossible','OK','Error')
    exit 1
}
