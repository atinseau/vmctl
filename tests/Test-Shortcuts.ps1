#requires -Version 7.2
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../src/Vmctl.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../src/ShortcutSupport.psm1') -Force
$scratch=Join-Path $PSScriptRoot ('../work/shortcuts-'+[guid]::NewGuid().ToString('N'))
$scratch=[IO.Path]::GetFullPath($scratch)
$null=New-Item -ItemType Directory -Path $scratch
$passed=0
function Assert-That([bool]$Condition,[string]$Label){if(-not $Condition){throw "FAIL: $Label"};$script:passed++;Write-Output "OK: $Label"}
$shell=New-Object -ComObject WScript.Shell
try {
    $settings=@{targets=@{linux=@{os='linux';hypervisor='none';transport='ssh'};beta=@{os='windows';hypervisor='hyperv';transport='psdirect';vmName='Beta VM'};alpha=@{os='windows';hypervisor='hyperv';transport='psdirect';vmName='Alpha VM'}}}
    $choices=@(Get-VmctlStreamingChoices $settings)
    Assert-That ($choices.Count -eq 2 -and $choices[0].alias -eq 'alpha') 'Picker lists configured streamable VMs in stable order'
    $settings.targets.gamma=@{os='windows';hypervisor='hyperv';transport='psdirect';vmName='New VM'}
    Assert-That (@(Get-VmctlStreamingChoices $settings).Count -eq 3) 'New VMs appear without reinstalling shortcuts'
    $args=@{Name='VM test avec espaces';DesktopPath=$scratch;Runtime=(Join-Path $PSHOME 'pwsh.exe');PickerScript=(Join-Path $PSScriptRoot '../scripts/Open-StreamingPicker.ps1')}
    $installed=Set-VmctlDesktopShortcut @args -Action install -Mode windowed
    $link=$shell.CreateShortcut($installed.path)
    Assert-That ($link.Arguments -match '-STA -WindowStyle Hidden' -and $link.Arguments -match '-Mode windowed' -and $link.TargetPath -eq $args.Runtime) 'Window shortcut launches hidden VM picker with correct runtime'
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
    $installed=Set-VmctlDesktopShortcut @args -Action install -Mode fullscreen
    $link=$shell.CreateShortcut($installed.path)
    Assert-That ($link.Arguments -match '-Mode fullscreen' -and @(Get-ChildItem -LiteralPath $scratch).Count -eq 1) 'Reinstall replaces the same shortcut without duplicates'
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
    Assert-That (Set-VmctlDesktopShortcut @args -Action uninstall).removed 'Uninstall removes the named shortcut'
    Assert-That (-not (Set-VmctlDesktopShortcut @args -Action uninstall).removed) 'Repeated uninstall succeeds'
    $rejected=$false
    $unsafeArgs=$args.Clone();$unsafeArgs.Name='../outside'
    try {Set-VmctlDesktopShortcut @unsafeArgs -Action install | Out-Null}catch{$rejected=$true}
    Assert-That $rejected 'Names cannot escape the desktop directory'
    $foreign=$shell.CreateShortcut((Join-Path $scratch 'Foreign.lnk'));$foreign.TargetPath=$args.Runtime;$foreign.Description='Other application';$foreign.Save()
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($foreign)
    $rejected=$false
    try {Set-VmctlDesktopShortcut -Action uninstall -Name Foreign -DesktopPath $scratch | Out-Null}catch{$rejected=$true}
    Assert-That ($rejected -and (Test-Path -LiteralPath (Join-Path $scratch 'Foreign.lnk'))) 'Uninstall preserves shortcuts owned by other applications'
    $cli=Join-Path $PSScriptRoot '../vmctl.ps1'
    $result=Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') @('-NoProfile','-File',$cli,'shortcut','uninstall','--name',('../outside'))
    Assert-That ($result.Stderr -match 'Invalid shortcut name') 'CLI accepts shortcut subcommand and double-dash name option'
    foreach($runtime in @((Join-Path $PSHOME 'pwsh.exe'),'powershell.exe')){
        $launcher=Join-Path $PSScriptRoot '../bin/vmctl.ps1'
        $code="& '"+$launcher.Replace("'","''")+"' shortcut uninstall --name '../outside'"
        $result=Invoke-VmctlProcess $runtime @('-NoProfile','-Command',$code)
        Assert-That ($result.Stderr -match 'Invalid shortcut name') "Installed launcher accepts double-dash options in $runtime"
    }
    Write-Output "$passed shortcut tests passed. Only an isolated desktop fixture was modified."
}finally{
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    # Remove only the two known fixture files and then the empty fixture folder.
    foreach($name in @('VM test avec espaces.lnk','Foreign.lnk')){ $path=Join-Path $scratch $name;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path} }
    Remove-Item -LiteralPath $scratch
}
