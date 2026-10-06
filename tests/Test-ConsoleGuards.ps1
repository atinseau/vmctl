#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$errors = $null; $tokens = $null
$worker = Join-Path $root 'scripts/Invoke-HyperVConsole.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($worker, [ref]$tokens, [ref]$errors)
if ($errors) { throw ($errors | Out-String) }
# Load pure guards and the RGB565 converter; no worker dispatch, CIM or VM input.
foreach ($name in @('Assert-ConsoleFrame','Assert-ConsolePoint','Get-ConsoleKeyCodes','Save-ConsoleFrame','Claim-ConsoleFrame')) {
    $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
$scratch = Join-Path $root ('work/console-guards-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch -Force
$script:passed = 0
function Assert-That([bool]$Condition, [string]$Label) {
    if (-not $Condition) { throw "ECHEC : $Label" }
    $script:passed++; Write-Output "OK : $Label"
}
function Assert-Rejected([scriptblock]$Action, [string]$Pattern, [string]$Label) {
    $caught = $null
    try { $null = & $Action } catch { $caught = $_.Exception.Message }
    Assert-That ($null -ne $caught -and $caught -match $Pattern) $Label
}
# A 3-pixel row exercises the padding required by GDI's 4-byte stride.
function Get-CimInstance { [pscustomobject]@{fakeService=$true} }
function Invoke-ConsoleMethod { param($Device,$Method,$Arguments)
    if ($Method -ne 'GetVirtualSystemThumbnailImage') { throw 'Aucune entree autorisee pendant ce test.' }
    [pscustomobject]@{ImageData=[byte[]]@(0x00,0xF8,0xE0,0x07,0x1F,0x00, 0xFF,0xFF,0x00,0x00,0xE0,0xFF)}
}
$context = @{ns='fake';vm=@{Name='82e1dde7-67c7-4ff0-956d-00fb4ee636e3'};setting=@{};width=3;height=2}
$request = @{vm='test';outFile=(Join-Path $scratch 'frame.png');frame=(Join-Path $scratch 'frame.json');maxFrameAgeSeconds=120}
$frame = Save-ConsoleFrame $context $request
$image = [Drawing.Bitmap]::new($frame.image)
try {
    Assert-That ($image.Width -eq 3 -and $image.Height -eq 2) 'PNG aux dimensions natives'
    Assert-That ($image.GetPixel(0,0).R -eq 255 -and $image.GetPixel(1,0).G -eq 255 -and $image.GetPixel(2,0).B -eq 255) 'RGB565 converti en couleurs RGB correctes'
    Assert-That ($image.GetPixel(0,1).R -eq 255 -and $image.GetPixel(1,1).R -eq 0 -and $image.GetPixel(2,1).R -eq 255) 'Stride et ordre des lignes preserves'
} finally { $image.Dispose() }
$script:prefixedPixels = [byte[]]@(0,0,0,16,0x00,0xF8,0xE0,0x07,0x1F,0x00,0xFF,0xFF,0x00,0x00,0xE0,0xFF)
function Invoke-ConsoleMethod { param($Device,$Method,$Arguments) [pscustomobject]@{ImageData=$script:prefixedPixels} }
$prefixed = Save-ConsoleFrame $context @{vm='test';outFile=(Join-Path $scratch 'prefixed.png')}
$image = [Drawing.Bitmap]::new($prefixed.image)
try {
    Assert-That ($prefixed.headerBytes -eq 4 -and $image.GetPixel(0,0).R -eq 255 -and $image.GetPixel(2,1).G -eq 255) 'Prefixe Hyper-V de longueur big-endian reconnu sans decalage de pixels'
} finally { $image.Dispose() }
$script:prefixedPixels[3] = 15
Assert-Rejected { Save-ConsoleFrame $context @{vm='test';outFile=(Join-Path $scratch 'invalid-prefix.png')} } 'Taille inattendue' 'Prefixe inconnu refuse sans supposer le format'
$script:prefixedPixels[3] = 16
Assert-That ((Assert-ConsoleFrame $context $request).frameId -eq $frame.frameId) 'Capture authentique acceptee'
function Save-TestFrame { $frame | ConvertTo-Json | Set-Content -LiteralPath $request.frame -Encoding utf8 }
$originalId = $frame.vmId
$frame.vmId = [Guid]::NewGuid().ToString(); Save-TestFrame
Assert-Rejected { Assert-ConsoleFrame $context $request } 'correspond pas' 'Capture d une autre VM refusee'
$frame.vmId = $originalId; $frame.width = 4; Save-TestFrame
Assert-Rejected { Assert-ConsoleFrame $context $request } 'resolution' 'Resolution changee refusee'
$frame.width = 3; $originalDate = $frame.capturedAt
$frame.capturedAt = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o'); Save-TestFrame
Assert-Rejected { Assert-ConsoleFrame $context $request } 'expiree' 'Capture expiree refusee'
$frame.capturedAt = [DateTimeOffset]::UtcNow.AddMinutes(10).ToString('o'); Save-TestFrame
Assert-Rejected { Assert-ConsoleFrame $context $request } 'expiree' 'Horodatage futur refuse'
$frame.capturedAt = $originalDate; $frame.imageSha256 = 'fake'; Save-TestFrame
Assert-Rejected { Assert-ConsoleFrame $context $request } 'modifiee' 'Image modifiee refusee'
Assert-Rejected { Assert-ConsolePoint $context -1 0 } 'Coordonnees' 'Coordonnees negatives refusees'
Assert-Rejected { Assert-ConsolePoint $context 3 0 } 'Coordonnees' 'Bord droit exclusif'
Assert-Rejected { Assert-ConsolePoint $context 0 2 } 'Coordonnees' 'Bord inferieur exclusif'
Assert-Rejected { Get-ConsoleKeyCodes 'Ctrl+NoSuchKey' } 'Touche' 'Raccourci inconnu refuse avant toute pression'
Assert-Rejected { Get-ConsoleKeyCodes 'Ctrl+Ctrl' } 'invalide' 'Touches dupliquees refusees'
$codes = @(Get-ConsoleKeyCodes 'Ctrl+Shift+A')
Assert-That ($codes.Count -eq 3 -and $codes[0] -eq 0x11 -and $codes[1] -eq 0x10 -and $codes[2] -eq 0x41) 'Raccourci traduit en touches virtuelles'
Assert-Rejected { Save-ConsoleFrame $context $request } 'existe deja' 'Une capture existante n est pas ecrasee'
Claim-ConsoleFrame $request.frame
Assert-Rejected { Claim-ConsoleFrame $request.frame } 'exist' 'Une capture ne peut autoriser qu une seule entree'
Import-Module (Join-Path $root 'src/Vmctl.psm1') -Force
$generic = Invoke-VmctlConsole -Target @{host='test';os='linux';hypervisor='none'} -Vm test -Action capabilities
$genericData = $generic.Stdout | ConvertFrom-Json
Assert-That ($generic.ExitCode -eq 0 -and -not $genericData.console.screenshot -and $genericData.command.status -eq 'not-probed') 'Cible SSH sans adaptateur visuel decrite sans promettre de connexion'
Write-Output "$script:passed verifications console reussies. Aucun acces a une VM ni entree clavier/souris."
