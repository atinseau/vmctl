#requires -Version 7.2
function Invoke-VmctlProcess {
    param([string]$Executable, [string[]]$Arguments, [string]$InputText,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 120)
    $resolved = Get-Command -Name $Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $resolved.Source
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $info.StandardInputEncoding = $encoding
    $info.StandardOutputEncoding = $encoding
    $info.StandardErrorEncoding = $encoding
    foreach ($argument in $Arguments) { [void]$info.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $false
    try {
        [void]$process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $remaining = { [Math]::Max(1, $TimeoutSeconds * 1000 - [int]$watch.ElapsedMilliseconds) }
        $timedOut = $false
        if ($InputText) {
            $write = $process.StandardInput.WriteAsync($InputText)
            try { $timedOut = -not $write.Wait((& $remaining)) }
            catch [System.AggregateException] {
                # SSH may reject authentication before reading stdin. Preserve its stderr/code.
                if ($_.Exception.InnerException -isnot [System.IO.IOException]) { throw }
            }
        }
        if (-not $timedOut) {
            try { $process.StandardInput.Close() } catch [System.IO.IOException] { }
            $timedOut = -not $process.WaitForExit((& $remaining))
        }
        if ($timedOut) {
            $process.Kill($true)
            [void]$process.WaitForExit(3000)
            $partialOut = if ($stdout.IsCompletedSuccessfully) { $stdout.GetAwaiter().GetResult() } else { '' }
            $partialErr = if ($stderr.IsCompletedSuccessfully) { $stderr.GetAwaiter().GetResult() } else { '' }
            return [pscustomobject]@{ ExitCode = 124; Stdout = $partialOut; Stderr =
                $partialErr + "Delai depasse (${TimeoutSeconds}s). La commande distante peut continuer : verifiez son etat avant de la relancer." }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode;
            Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}
