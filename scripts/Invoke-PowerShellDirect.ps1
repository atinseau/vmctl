#requires -Version 5.1
# Native Windows PowerShell worker. Request arrives on stdin; no password on the command line.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# PS7's inherited module path can resolve incompatible Security/Utility modules.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$session = $null
try {
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($request.action -notin @('exec','upload')) { throw 'Action PowerShell Direct inconnue.' }
    Import-Module Hyper-V
    $vm = @(if ($request.vmId) { Get-VM -Id ([Guid]$request.vmId) } else {
        Get-VM -Name ([WildcardPattern]::Escape($request.vmName)) | Where-Object { $_.Name -ceq $request.vmName }
    })
    if ($vm.Count -ne 1 -or $vm[0].Name -cne $request.vmName) { throw 'Nom/GUID Hyper-V incoherent ou VM introuvable.' }
    if ($vm[0].State -ne 'Running') { throw 'La VM doit etre demarree pour PowerShell Direct.' }
    # DPAPI: only this Windows user on this host can decrypt the supplied secret.
    $password = ConvertTo-SecureString -String $request.password
    $credential = New-Object Management.Automation.PSCredential($request.user, $password)
    $session = New-PSSession -VMId $vm[0].Id -Credential $credential -ErrorAction Stop
    if ($request.action -eq 'upload') {
        Copy-Item -LiteralPath $request.source -Destination $request.destination -ToSession $session -Recurse:$request.recursive -ErrorAction Stop
        $result = @{ ExitCode=0; Stdout=''; Stderr='' }
    } else {
        $result = Invoke-Command -Session $session -ArgumentList $request.shell,$request.runner,$request.script,$request.asFile -ScriptBlock {
            param($shell, $runner, $code, $asFile)
            $ErrorActionPreference = 'Stop'
            # A child preserves native stdout/stderr and explicit exit N without ending the session.
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = $shell
            $policy = if ($asFile) { ' -ExecutionPolicy Bypass' } else { '' }
            $info.Arguments = '-NoLogo -NoProfile -NonInteractive -OutputFormat Text' + $policy + ' -EncodedCommand ' + $runner
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardInput = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $utf8 = New-Object Text.UTF8Encoding($false)
            $info.StandardOutputEncoding = $utf8
            $info.StandardErrorEncoding = $utf8
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $info
            try {
                [void]$process.Start()
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
                # .NET Framework in Windows PowerShell 5.1 has no StandardInputEncoding property.
                $inputWriter = New-Object IO.StreamWriter($process.StandardInput.BaseStream, $utf8)
                try { $inputWriter.Write($code) } finally { $inputWriter.Dispose() }
                $process.WaitForExit()
                @{ ExitCode=$process.ExitCode; Stdout=$stdout.GetAwaiter().GetResult(); Stderr=$stderr.GetAwaiter().GetResult() }
            } finally { $process.Dispose() }
        } -ErrorAction Stop
    }
    [pscustomobject]@{ ExitCode=[int]$result.ExitCode; Stdout=[string]$result.Stdout; Stderr=[string]$result.Stderr } | ConvertTo-Json -Compress
} catch {
    [pscustomobject]@{ ExitCode=1; Stdout=''; Stderr=('PowerShell Direct : ' + $_.Exception.Message) } | ConvertTo-Json -Compress
} finally {
    if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}
