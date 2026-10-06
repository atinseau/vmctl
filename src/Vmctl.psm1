#requires -Version 7.2
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Configuration.ps1')
. (Join-Path $PSScriptRoot 'Process.ps1')
. (Join-Path $PSScriptRoot 'Ssh.ps1')
. (Join-Path $PSScriptRoot 'HyperV.ps1')
. (Join-Path $PSScriptRoot 'Gpu.ps1')
. (Join-Path $PSScriptRoot 'Console.ps1')
. (Join-Path $PSScriptRoot 'PowerShellDirect.ps1')

Export-ModuleMember -Function Get-VmctlConfigPath, Read-VmctlConfig, Get-VmctlTarget, Get-VmctlTransport, Invoke-VmctlProcess, Get-VmctlSshOptions, New-VmctlWindowsExecution, New-VmctlExecution, Invoke-VmctlCommand, Invoke-VmctlUpload, Get-VmctlDiagnosticHint, Invoke-VmctlHyperV, Invoke-VmctlGpu, Invoke-VmctlConsole, Invoke-VmctlDirect
