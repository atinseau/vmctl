#requires -Version 5.1
Set-StrictMode -Version Latest
function Get-VmctlGpuShare {
    param([Parameter(Mandatory)][UInt64]$Total,[ValidateRange(1,100)][int]$Percent)
    # Decimal arithmetic preserves UInt64.MaxValue without double rounding/overflow.
    return [UInt64][decimal]::Floor(([decimal]$Total * [decimal]$Percent) / 100)
}
function Get-VmctlGpuFingerprint {
    param([Parameter(Mandatory)][string[]]$Records)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Records -join "`n"))
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Assert-VmctlGpuRelativePath {
    param([Parameter(Mandatory)][string]$Relative)
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Relative.Contains(':')) { throw 'Unsafe GPU driver destination.' }
    if ($Relative -notmatch '^Windows\\(?:System32|SysWOW64)\\') { throw 'GPU driver destination must be below Windows System32 or SysWOW64.' }
}
Export-ModuleMember -Function Get-VmctlGpuShare,Get-VmctlGpuFingerprint,Assert-VmctlGpuRelativePath
