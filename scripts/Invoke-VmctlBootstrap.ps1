#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Runtime,
    [Parameter(Mandatory)][string]$Script,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Runtime -PathType Leaf)) {
    throw 'PowerShell 7 introuvable. Relancez install.ps1 depuis PowerShell 7.2 ou plus recent.'
}
# Preserve typed arguments without cmd.exe quoting or command-line length limits.
# Restrict the directory before writing; Export-Clixml protects credentials with DPAPI.
$directory = Join-Path ([IO.Path]::GetTempPath()) ('vmctl-bootstrap-' + [Guid]::NewGuid().ToString('N'))
$payload = Join-Path $directory 'parameters.clixml'
$exitCode = 1
try {
    $null = New-Item -ItemType Directory -Path $directory
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($identity, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    # Use the framework API: a parent PS7 process may expose PS7-only modules
    # through PSModulePath, preventing PS5 from autoloading Set-Acl.
    [IO.DirectoryInfo]::new($directory).SetAccessControl($acl)
    $bound = @{}
    foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        # SwitchParameter can deserialize differently between PowerShell versions.
        if ($value -is [Management.Automation.SwitchParameter]) { $value = $value.IsPresent }
        $bound[$key] = $value
    }
    Export-Clixml -InputObject $bound -LiteralPath $payload -Depth 10
    $literalPayload = $payload.Replace("'", "''")
    $literalScript = $Script.Replace("'", "''")
    $code = "`$ErrorActionPreference = 'Stop'; `$bound = Import-Clixml -LiteralPath '$literalPayload'; & '$literalScript' @bound; exit `$LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    & $Runtime -NoLogo -NoProfile -EncodedCommand $encoded
    $exitCode = $LASTEXITCODE
} finally {
    if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Force }
    # Remove only this empty directory; never recurse over computed paths.
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory }
}
exit $exitCode
