#requires -Version 7.2
[CmdletBinding()]
param(
    [string]$Vm = 'win-vm',
    [string]$Config,
    [Management.Automation.PSCredential]$Credential, [string]$CredentialFile,
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 30,
    [string]$Report
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/Vmctl.psm1') -Force
if (-not $Config) { $Config = Get-VmctlConfigPath }
$checks = [Collections.Generic.List[object]]::new()
$started = [DateTimeOffset]::Now
$testId = [Guid]::NewGuid().ToString('N')
$scratch = Join-Path $root "work/real-vm-$testId"
$null = New-Item -ItemType Directory -Path $scratch -Force
if (-not $Report) { $Report = Join-Path $scratch 'report.json' }
$remoteDirectory = $null
$target = $null
$failure = $null
$cleanupFailure = $null
function Record-Check([string]$Name, [bool]$Passed, [object]$Details) {
    $checks.Add([pscustomobject]@{ name=$Name; passed=$Passed; details=$Details })
    $label = if ($Passed) { 'OK' } else { 'ECHEC' }
    Write-Output "${label} : $Name"
    if (-not $Passed) { throw "Verification echouee : $Name" }
}
try {
    $settings = Read-VmctlConfig $Config
    $target = Get-VmctlTarget $settings $Vm
    if ($target.os -ne 'windows') { throw 'Ce test reel est prevu pour une VM Windows.' }
    $transport = Get-VmctlTransport $target
    if ($CredentialFile) { $Credential = Import-Clixml -LiteralPath $CredentialFile }
    if ($transport -eq 'psdirect' -and -not $Credential) {
        $Credential = Get-Credential -Message 'Compte et mot de passe de la VM'
    }
    $authentication = @{Credential=$Credential}
    $probe = @'
[pscustomobject]@{ host=$env:COMPUTERNAME; user=[Security.Principal.WindowsIdentity]::GetCurrent().Name;
    temp=$env:TEMP; powershell=$PSVersionTable.PSVersion.ToString() } | ConvertTo-Json -Compress
'@
    $result = Invoke-VmctlCommand $target $probe -TimeoutSeconds $TimeoutSeconds @authentication
    Record-Check "Connexion $transport et identification de la VM" ($result.ExitCode -eq 0) $result
    $identity = $result.Stdout | ConvertFrom-Json
    if ($target.ContainsKey('vmName')) { Record-Check 'Identite de la VM conforme a la cible' ($identity.host -ieq $target.vmName) $identity.host }
    Record-Check 'Execution dans l invite et pas sur l hote' ($identity.host -ine $env:COMPUTERNAME) $identity.host
    $remoteDirectory = Join-Path $identity.temp "vmctl-test-$testId"
    $quotedDirectory = $remoteDirectory.Replace("'", "''")
    $create = "New-Item -ItemType Directory -Path '$quotedDirectory' -ErrorAction Stop | Out-Null"
    $result = Invoke-VmctlCommand $target $create -TimeoutSeconds $TimeoutSeconds @authentication
    Record-Check 'Creation du dossier temporaire dans la VM' ($result.ExitCode -eq 0) $result

    $content = 'élève "quotes" $literal & |' + "`n" + [Guid]::NewGuid().ToString()
    $localFile = Join-Path $scratch 'probe avec espaces.txt'
    [IO.File]::WriteAllText($localFile, $content, [Text.UTF8Encoding]::new($false))
    $expectedHash = (Get-FileHash -LiteralPath $localFile -Algorithm SHA256).Hash
    $remoteFile = Join-Path $remoteDirectory 'probe avec espaces.txt'
    $result = Invoke-VmctlUpload $target $localFile $remoteFile.Replace('\','/') -TimeoutSeconds $TimeoutSeconds @authentication
    Record-Check "Transfert $transport reel, chemin avec espaces" ($result.ExitCode -eq 0) $result
    $quotedFile = $remoteFile.Replace("'", "''")
    $result = Invoke-VmctlCommand $target "(Get-FileHash -LiteralPath '$quotedFile' -Algorithm SHA256).Hash" -TimeoutSeconds $TimeoutSeconds @authentication
    Record-Check 'Contenu transfere identique (SHA-256)' ($result.ExitCode -eq 0 -and $result.Stdout.Trim() -eq $expectedHash) $result

    $code = @'
$literal = 'élève "quotes" $variable & |'
Write-Output $literal
'@
    $result = Invoke-VmctlCommand $target $code -AsFile -TimeoutSeconds $TimeoutSeconds @authentication
    Record-Check 'Execution de script, Unicode et guillemets dans la vraie VM' ($result.ExitCode -eq 0 -and $result.Stdout.Trim() -eq 'élève "quotes" $variable & |') $result
    $result = Invoke-VmctlCommand $target 'cmd.exe /c exit 7' -TimeoutSeconds $TimeoutSeconds @authentication
    Record-Check 'Code de retour natif distant conserve' ($result.ExitCode -eq 7) $result
    $result = Invoke-VmctlCommand $target 'throw "vmctl-test-erreur-attendue"' -TimeoutSeconds $TimeoutSeconds @authentication
    Record-Check 'Erreur distante sur stderr' ($result.ExitCode -eq 1 -and $result.Stderr -match 'vmctl-test-erreur-attendue') $result
} catch {
    $failure = $_.Exception.Message
    [Console]::Error.WriteLine($failure)
} finally {
    if ($remoteDirectory -and $target) {
        # Only remove exact generated files, then the exact directory non-recursively.
        $quotedFile = (Join-Path $remoteDirectory 'probe avec espaces.txt').Replace("'", "''")
        $quotedDirectory = $remoteDirectory.Replace("'", "''")
        $cleanup = "if (Test-Path -LiteralPath '$quotedFile') { Remove-Item -LiteralPath '$quotedFile' -Force }; if (Test-Path -LiteralPath '$quotedDirectory') { Remove-Item -LiteralPath '$quotedDirectory' -Force }"
        try {
            $result = Invoke-VmctlCommand $target $cleanup -TimeoutSeconds $TimeoutSeconds @authentication
            $checks.Add([pscustomobject]@{name='Nettoyage du dossier temporaire distant';passed=($result.ExitCode -eq 0);details=$result})
            if ($result.ExitCode -ne 0) { $cleanupFailure = $result.Stderr }
        } catch { $cleanupFailure = $_.Exception.Message }
    }
    $reportFull = [IO.Path]::GetFullPath($Report)
    $null = New-Item -ItemType Directory -Path (Split-Path $reportFull -Parent) -Force
    [pscustomobject]@{ vm=$Vm; startedAt=$started.ToString('o'); finishedAt=[DateTimeOffset]::Now.ToString('o');
        success=($null -eq $failure -and $null -eq $cleanupFailure); failure=$failure;
        cleanupFailure=$cleanupFailure; remoteTemporaryDirectory=$remoteDirectory; checks=@($checks.ToArray()) } |
        ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFull -Encoding utf8
    Write-Output "Rapport : $reportFull"
}
if ($failure -or $cleanupFailure) { exit 1 }
exit 0
