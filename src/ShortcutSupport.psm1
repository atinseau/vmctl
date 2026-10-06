#requires -Version 7.2
Set-StrictMode -Version Latest
function Get-VmctlStreamingChoices {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    foreach($alias in @($Settings.targets.Keys|Sort-Object)){
        $target=$Settings.targets[$alias]
        if($target.os -eq 'windows' -and $target.hypervisor -eq 'hyperv' -and (Get-VmctlTransport $target) -eq 'psdirect'){
            [pscustomobject]@{alias=$alias;label="$alias ($($target.vmName))"}
        }
    }
}
function Set-VmctlDesktopShortcut {
    param([Parameter(Mandatory)][ValidateSet('install','uninstall')][string]$Action,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('windowed','fullscreen')][string]$Mode='windowed',
        [string]$Runtime,[string]$PickerScript,[string]$Config,
        [string]$DesktopPath=[Environment]::GetFolderPath('DesktopDirectory'))
    if([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[<>:"/\\|?*\x00-\x1f]' -or $Name -match '[. ]$' -or $Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){
        throw 'Invalid shortcut name: use a simple desktop name without a path or reserved Windows characters.'
    }
    if(-not $DesktopPath -or -not(Test-Path -LiteralPath $DesktopPath -PathType Container)){throw 'Windows desktop directory is unavailable.'}
    $path=Join-Path $DesktopPath ($Name+'.lnk')
    $shell=New-Object -ComObject WScript.Shell
    $temporary=$null
    try {
        if(Test-Path -LiteralPath $path){
            $existing=$shell.CreateShortcut($path)
            try {if($existing.Description -notlike 'vmctl streaming shortcut:*'){throw 'This desktop shortcut is not managed by vmctl; choose another name.'}}
            finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($existing)}
        }
        if($Action -eq 'uninstall'){
            $removed=Test-Path -LiteralPath $path
            if($removed){Remove-Item -LiteralPath $path -Force}
            return [pscustomobject]@{action=$Action;path=$path;removed=$removed}
        }
        if(-not(Test-Path -LiteralPath $Runtime -PathType Leaf) -or -not(Test-Path -LiteralPath $PickerScript -PathType Leaf)){throw 'Shortcut runtime or VM picker script is missing.'}
        $temporary=Join-Path $DesktopPath ('.vmctl-'+[guid]::NewGuid().ToString('N')+'.lnk')
        $shortcut=$shell.CreateShortcut($temporary)
        try {
            $shortcut.TargetPath=[IO.Path]::GetFullPath($Runtime)
            $shortcut.Arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -File "'+[IO.Path]::GetFullPath($PickerScript)+'" -Mode '+$Mode
            if($Config){
                if($Config.Contains('"')){throw 'Invalid configuration path.'}
                $shortcut.Arguments+=' -Config "'+[IO.Path]::GetFullPath($Config)+'"'
            }
            $shortcut.WorkingDirectory=Split-Path (Split-Path $PickerScript -Parent) -Parent
            $shortcut.Description='vmctl streaming shortcut: '+$Mode+'; choose a VM'
            $moonlight=Join-Path $env:ProgramFiles 'Moonlight Game Streaming/Moonlight.exe'
            $shortcut.IconLocation=if(Test-Path -LiteralPath $moonlight){$moonlight+',0'}else{$Runtime+',0'}
            $shortcut.WindowStyle=1
            $shortcut.Save()
        }finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)}
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
        Move-Item -LiteralPath $temporary -Destination $path
        [pscustomobject]@{action=$Action;path=$path;mode=$Mode}
    }finally{
        if($temporary -and (Test-Path -LiteralPath $temporary)){Remove-Item -LiteralPath $temporary -Force}
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}
Export-ModuleMember -Function Set-VmctlDesktopShortcut,Get-VmctlStreamingChoices
