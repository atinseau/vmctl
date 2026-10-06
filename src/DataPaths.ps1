#requires -Version 5.1
function Get-VmctlDataRoot {
    # AppData writes can be virtualized by an MSIX parent (including terminals).
    # A directory in the user profile is shared by packaged and ordinary callers.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.vmctl'
    }
    $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
    return Join-Path $base 'vmctl'
}

function Initialize-VmctlDataRoot {
    param([string]$Root = (Get-VmctlDataRoot), [string]$LegacyRoot)
    $null = New-Item -ItemType Directory -Path $Root -Force
    # Never resurrect removed profiles or replace an already initialized store.
    if (Test-Path -LiteralPath (Join-Path $Root 'targets.json')) { return $Root }
    if (-not $LegacyRoot -or -not (Test-Path -LiteralPath (Join-Path $LegacyRoot 'targets.json'))) { return $Root }
    foreach ($folder in @('credentials', 'streaming-bindings', 'reports', 'captures', 'keys')) {
        $source = Join-Path $LegacyRoot $folder
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        $destination = Join-Path $Root $folder
        $null = New-Item -ItemType Directory -Path $destination -Force
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
            $relative = $file.FullName.Substring($source.TrimEnd('\', '/').Length).TrimStart('\', '/')
            $target = Join-Path $destination $relative
            if (Test-Path -LiteralPath $target) { continue }
            $null = New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
    }
    # Config last: an interrupted migration can resume without replacing files.
    Copy-Item -LiteralPath (Join-Path $LegacyRoot 'targets.json') -Destination (Join-Path $Root 'targets.json')
    return $Root
}
