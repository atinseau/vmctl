#requires -Version 7.2
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/Vmctl.psm1') -Force
$scratch = Join-Path $root ('work/data-paths-' + [Guid]::NewGuid().ToString('N'))
$legacy = Join-Path $scratch 'legacy'
$shared = Join-Path $scratch 'shared'
$null = New-Item -ItemType Directory -Path "$legacy/credentials", "$legacy/streaming-bindings", "$legacy/reports/nested", "$legacy/work", "$legacy/streaming-sessions" -Force
'{"schemaVersion":1,"targets":{}}' | Set-Content "$legacy/targets.json"
'encrypted-fixture' | Set-Content "$legacy/credentials/apollo-test.clixml"
'binding-fixture' | Set-Content "$legacy/streaming-bindings/test.json"
'report-fixture' | Set-Content "$legacy/reports/nested/test.json"
'expired-fixture' | Set-Content "$legacy/work/temporary.clixml"
'expired-fixture' | Set-Content "$legacy/streaming-sessions/temporary.json"
$script:passed = 0
function Assert-That([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "ECHEC : $Label" }
    $script:passed++; Write-Output "OK : $Label"
}
$null = Initialize-VmctlDataRoot -Root $shared -LegacyRoot $legacy
Assert-That ((Get-FileHash "$legacy/targets.json").Hash -eq (Get-FileHash "$shared/targets.json").Hash) 'Configuration migree sans modification'
Assert-That ((Get-FileHash "$legacy/credentials/apollo-test.clixml").Hash -eq (Get-FileHash "$shared/credentials/apollo-test.clixml").Hash) 'Identifiants chiffres conserves tels quels'
Assert-That (Test-Path "$shared/streaming-bindings/test.json") 'Appairage migre'
Assert-That (Test-Path "$shared/reports/nested/test.json") 'Rapports imbriques migres'
Assert-That (-not (Test-Path "$shared/work") -and -not (Test-Path "$shared/streaming-sessions")) 'Sessions et caches temporaires exclus'
Assert-That (Test-Path "$legacy/targets.json") 'Ancienne configuration conservee pour retour arriere'
'changed' | Set-Content "$shared/targets.json"
Remove-Item -LiteralPath "$shared/streaming-bindings/test.json"
$null = Initialize-VmctlDataRoot -Root $shared -LegacyRoot $legacy
Assert-That ((Get-Content "$shared/targets.json" -Raw).Trim() -eq 'changed') 'Configuration existante jamais remplacee'
Assert-That (-not (Test-Path "$shared/streaming-bindings/test.json")) 'Profil supprime non ressuscite par une reinstallation'
$originalLocal = $env:LOCALAPPDATA
try {
    $expected = Get-VmctlDataRoot
    $env:LOCALAPPDATA = Join-Path $scratch 'virtualized-appdata'
    Assert-That ((Get-VmctlDataRoot) -eq $expected) 'Racine independante de la vue AppData'
    $source = (Join-Path $root 'src/DataPaths.ps1').Replace("'", "''")
    $code = ". '$source'; Get-VmctlDataRoot"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $result = Invoke-VmctlProcess "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" @('-NoProfile','-EncodedCommand',$encoded)
    Assert-That ($result.ExitCode -eq 0 -and $result.Stdout.Trim() -eq $expected) 'Racine identique depuis Windows PowerShell 5.1'
} finally { $env:LOCALAPPDATA = $originalLocal }
Write-Output "$script:passed verifications des donnees reussies. Aucun acces a une VM."
