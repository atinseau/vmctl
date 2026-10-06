#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Ce lanceur global est prevu pour Windows.' }
$vmctlBin = Join-Path $PSScriptRoot 'bin'
$null = New-Item -ItemType Directory -Path $vmctlBin -Force
$vmctlRuntime = Join-Path $PSHOME 'pwsh.exe'
$vmctlScript = Join-Path $PSScriptRoot 'vmctl.ps1'
# Resolve the runtime once; no dependency on profile aliases or a system-wide pwsh install.
$vmctlLauncher = "@echo off`r`n`"$vmctlRuntime`" -NoLogo -NoProfile -File `"$vmctlScript`" %*`r`nexit /b %errorlevel%`r`n"
[IO.File]::WriteAllText((Join-Path $vmctlBin 'vmctl.cmd'), $vmctlLauncher, [Text.Encoding]::Default)
# PowerShell prefers a .ps1 launcher. Typed splatting avoids cmd.exe quote interpretation.
$vmctlParseErrors = $null
$vmctlTokens = $null
$vmctlAst = [Management.Automation.Language.Parser]::ParseFile($vmctlScript, [ref]$vmctlTokens, [ref]$vmctlParseErrors)
if ($vmctlParseErrors) { throw 'Le script vmctl contient une erreur de syntaxe.' }
$vmctlLiteralScript = $vmctlScript.Replace("'", "''")
$vmctlLiteralRuntime = $vmctlRuntime.Replace("'", "''")
$vmctlLiteralBootstrap = (Join-Path $PSScriptRoot 'scripts/Invoke-VmctlBootstrap.ps1').Replace("'", "''")
$vmctlPsLauncher = '#requires -Version 5.1' + "`n" + $vmctlAst.ParamBlock.Extent.Text + "`n" + @"
`$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new(`$false)
try {
    if (`$PSVersionTable.PSVersion -lt [version]'7.2') {
        & '$vmctlLiteralBootstrap' -Runtime '$vmctlLiteralRuntime' -Script '$vmctlLiteralScript' -Parameters `$PSBoundParameters
    } else {
        & '$vmctlLiteralScript' @PSBoundParameters
    }
    exit `$LASTEXITCODE
} catch {
    [Console]::Error.WriteLine(`$_.ToString())
    exit 1
}
"@
[IO.File]::WriteAllText((Join-Path $vmctlBin 'vmctl.ps1'), $vmctlPsLauncher, [Text.UTF8Encoding]::new($false))
. (Join-Path $PSScriptRoot 'src/DataPaths.ps1')
$vmctlDataRoot = Initialize-VmctlDataRoot -LegacyRoot (Join-Path $env:LOCALAPPDATA 'vmctl')
$vmctlConfig = Join-Path $vmctlDataRoot 'targets.json'
if (-not (Test-Path -LiteralPath $vmctlConfig)) {
    $null = New-Item -ItemType Directory -Path (Split-Path $vmctlConfig -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'targets.example.json') -Destination $vmctlConfig
}
$vmctlUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$vmctlEntries = @($vmctlUserPath -split ';' | Where-Object { $_ })
if ($vmctlBin -notin $vmctlEntries) {
    [Environment]::SetEnvironmentVariable('Path', (($vmctlEntries + $vmctlBin) -join ';'), 'User')
}
if ($vmctlBin -notin ($env:Path -split ';')) { $env:Path += ";$vmctlBin" }
Write-Output "vmctl installe : $vmctlBin"
Write-Output "Configuration : $vmctlConfig"
Write-Output 'Ouvrez un nouveau terminal. Les applications deja ouvertes peuvent necessiter un redemarrage pour lire le nouveau PATH.'
