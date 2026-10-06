#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RequestPath, [Parameter(Mandatory)][string]$ResponsePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:PSModulePath = Join-Path $PSHOME 'Modules'

function Invoke-ConsoleMethod($Device, [string]$Method, [hashtable]$Arguments) {
    $answer = Invoke-CimMethod -InputObject $Device -MethodName $Method -Arguments $Arguments
    if ($answer.ReturnValue -ne 0) { throw "$Method a echoue (Hyper-V $($answer.ReturnValue)). Etat partiel possible, aucune nouvelle tentative automatique." }
    return $answer
}
function Get-ConsoleContext($Request) {
    $ns = 'root/virtualization/v2'
    if ($Request.vmId) {
        $id = ([Guid]::Parse($Request.vmId)).ToString()
        $vm = @(Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "Name='$id'")
    } else {
        $vm = @(Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem |
            Where-Object { $_.ElementName -ceq $Request.vmName -and $_.Caption -eq 'Virtual Machine' })
    }
    if ($vm.Count -ne 1) { throw 'La cible doit identifier exactement une VM Hyper-V locale.' }
    $vm = $vm[0]
    if ($vm.EnabledState -ne 2) { throw 'La VM doit etre en cours pour utiliser sa console.' }
    if ($Request.vmName -and $vm.ElementName -cne $Request.vmName) { throw 'Le nom et le GUID Hyper-V ne correspondent pas.' }
    $setting = @(Get-CimAssociatedInstance -InputObject $vm -Association Msvm_SettingsDefineState -ResultClassName Msvm_VirtualSystemSettingData)
    $controllers = @(Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_SyntheticDisplayController)
    $heads = @($controllers | ForEach-Object { Get-CimAssociatedInstance -InputObject $_ -ResultClassName Msvm_VideoHead } |
        Where-Object { $_.CurrentHorizontalResolution -gt 0 -and $_.CurrentVerticalResolution -gt 0 })
    if ($setting.Count -ne 1 -or $heads.Count -ne 1) { throw 'Cette version exige une configuration courante et un seul ecran console actif.' }
    $width = [int]$heads[0].CurrentHorizontalResolution
    $height = [int]$heads[0].CurrentVerticalResolution
    if ($width -gt 65535 -or $height -gt 65535 -or ([long]$width * $height) -gt 33554432) { throw 'Resolution console non prise en charge.' }
    $keyboard = @(Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_Keyboard)
    $mouse = @(Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_SyntheticMouse)
    return @{ vm=$vm; setting=$setting[0]; width=$width; height=$height;
        keyboard=$(if ($keyboard.Count -eq 1) { $keyboard[0] } else { $null });
        mouse=$(if ($mouse.Count -eq 1) { $mouse[0] } else { $null }); ns=$ns }
}
function Save-ConsoleFrame($Context, $Request) {
    Add-Type -AssemblyName System.Drawing
    $service = Get-CimInstance -Namespace $Context.ns -ClassName Msvm_VirtualSystemManagementService
    $answer = Invoke-ConsoleMethod $service GetVirtualSystemThumbnailImage @{
        TargetSystem=$Context.setting; WidthPixels=[uint16]$Context.width; HeightPixels=[uint16]$Context.height }
    $data = [byte[]]$answer.ImageData
    $pixelBytes = $Context.width * $Context.height * 2
    $offset = 0
    # This Hyper-V provider prefixes its RGB565 data with a big-endian total byte count.
    if ($data.Length -eq $pixelBytes + 4) {
        $declaredLength = [long]$data[0]*16777216 + [long]$data[1]*65536 + [long]$data[2]*256 + [long]$data[3]
        if ($declaredLength -eq $data.Length) { $offset = 4 }
    }
    if ($data.Length - $offset -ne $pixelBytes) { throw "Taille inattendue du framebuffer RGB565 : $($data.Length) octets pour $($Context.width)x$($Context.height), attendu $pixelBytes." }
    $frameId = [Guid]::NewGuid().ToString('N')
    $path = if ($Request.outFile) { [IO.Path]::GetFullPath($Request.outFile) } else {
        Join-Path $env:LOCALAPPDATA "vmctl\captures\$($Context.vm.Name)\$frameId.png" }
    if ([IO.Path]::GetExtension($path) -ine '.png') { throw 'OutFile exige un fichier .png.' }
    if (Test-Path -LiteralPath $path) { throw 'Le fichier image existe deja. Choisissez un nouveau chemin.' }
    $frameFile = [IO.Path]::ChangeExtension($path, '.json')
    if (Test-Path -LiteralPath $frameFile) { throw 'Le fichier de metadonnees existe deja.' }
    $null = New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force
    $bitmap = New-Object Drawing.Bitmap($Context.width, $Context.height, [Drawing.Imaging.PixelFormat]::Format16bppRgb565)
    try {
        $rectangle = New-Object Drawing.Rectangle(0, 0, $Context.width, $Context.height)
        $locked = $bitmap.LockBits($rectangle, [Drawing.Imaging.ImageLockMode]::WriteOnly, [Drawing.Imaging.PixelFormat]::Format16bppRgb565)
        try {
            for ($row = 0; $row -lt $Context.height; $row++) {
                [Runtime.InteropServices.Marshal]::Copy($data, $offset + $row * $Context.width * 2,
                    [IntPtr]::Add($locked.Scan0, $row * $locked.Stride), $Context.width * 2)
            }
        } finally { $bitmap.UnlockBits($locked) }
        $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
    $frame = [ordered]@{ schemaVersion=1; backend='hyperv'; vm=$Request.vm; vmId=[string]$Context.vm.Name;
        frameId=$frameId; width=$Context.width; height=$Context.height; headerBytes=$offset; capturedAt=[DateTimeOffset]::UtcNow.ToString('o');
        image=$path; frameFile=$frameFile; imageSha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $frame | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $frameFile -Encoding UTF8
    return $frame
}
function Assert-ConsoleFrame($Context, $Request) {
    if (-not $Request.frame) { throw 'Une entree exige -Frame, le JSON de la derniere capture.' }
    $frame = Get-Content -LiteralPath $Request.frame -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($frame.schemaVersion -ne 1 -or $frame.backend -ne 'hyperv' -or $frame.vmId -ine $Context.vm.Name) { throw 'La capture ne correspond pas a cette VM.' }
    if ($frame.width -ne $Context.width -or $frame.height -ne $Context.height) { throw 'La resolution a change. Prenez une nouvelle capture.' }
    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]$frame.capturedAt).TotalSeconds
    if ($age -lt -5 -or $age -gt $Request.maxFrameAgeSeconds) { throw 'Capture expiree. Prenez une nouvelle capture.' }
    if ((Get-FileHash -LiteralPath $frame.image -Algorithm SHA256).Hash -ine $frame.imageSha256) { throw 'L image de reference a ete modifiee.' }
    return $frame
}
function Assert-ConsolePoint($Context, [int]$X, [int]$Y) {
    if ($X -lt 0 -or $Y -lt 0 -or $X -ge $Context.width -or $Y -ge $Context.height) { throw 'Coordonnees hors de l ecran console.' }
}
function Claim-ConsoleFrame([string]$Path) {
    $claim = [IO.File]::Open(([IO.Path]::GetFullPath($Path) + '.used'), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $claim.Dispose()
}
function Get-ConsoleKeyCodes([string]$Keys) {
    $map = @{ Ctrl=0x11; Control=0x11; Shift=0x10; Alt=0x12; Enter=0x0D; Tab=0x09; Escape=0x1B; Esc=0x1B;
        Space=0x20; Backspace=0x08; Delete=0x2E; Insert=0x2D; Left=0x25; Up=0x26; Right=0x27; Down=0x28;
        Home=0x24; End=0x23; PageUp=0x21; PageDown=0x22; Win=0x5B }
    if (-not $Keys) { throw 'key exige -Keys, par exemple Ctrl+A ou Enter.' }
    $tokens = @($Keys.Split('+'))
    if ($tokens.Count -gt 5 -or @($tokens | Select-Object -Unique).Count -ne $tokens.Count) { throw 'Raccourci invalide.' }
    foreach ($token in $tokens) {
        if ($map.ContainsKey($token)) { [uint32]$map[$token] }
        elseif ($token -match '^[a-zA-Z0-9]$') { [uint32][char]$token.ToUpperInvariant() }
        elseif ($token -match '^F([1-9]|1[0-9]|2[0-4])$') { [uint32](0x6F + [int]$Matches[1]) }
        else { throw "Touche non prise en charge : $token" }
    }
}
$performed = $false
try {
    $request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($request.action -notin @('capabilities','screenshot','move','click','type','key','scroll','drag')) { throw 'Action console inconnue.' }
    $context = Get-ConsoleContext $request
    $answer = [ordered]@{ action=$request.action; vm=$request.vm; vmId=[string]$context.vm.Name; backend='hyperv' }
    if ($request.action -eq 'capabilities') {
        $answer.console = @{ screenshot=$true; keyboard=($null -ne $context.keyboard -and -not $context.keyboard.IsLocked);
            unicode=($null -ne $context.keyboard -and $context.keyboard.UnicodeSupported);
            mouse=($null -ne $context.mouse -and $context.mouse.EnabledState -eq 2 -and -not $context.mouse.IsLocked);
            width=$context.width; height=$context.height; session='basic-console' }
        $answer.command = @{transport=$request.transport;status='not-probed';probe='vmctl doctor -Vm ' + $request.vm}
    } elseif ($request.action -eq 'screenshot') {
        $answer.frame = Save-ConsoleFrame $context $request
    } else {
        $reference = Assert-ConsoleFrame $context $request
        if ($request.action -in @('move','click','scroll','drag')) {
            if ($null -eq $context.mouse -or $context.mouse.EnabledState -ne 2 -or $context.mouse.IsLocked) { throw 'Souris console indisponible.' }
            Assert-ConsolePoint $context $request.x $request.y
            if ($request.action -eq 'drag') { Assert-ConsolePoint $context $request.toX $request.toY }
            if ($request.action -in @('click','drag') -and ($request.buttonIndex -lt 1 -or $request.buttonIndex -gt $context.mouse.NumberOfButtons)) { throw 'Bouton souris invalide.' }
        } else {
            if ($null -eq $context.keyboard -or $context.keyboard.IsLocked) { throw 'Clavier console indisponible.' }
            if ($request.action -eq 'key') { $keyCodes = @(Get-ConsoleKeyCodes $request.keys) }
            if ($request.action -eq 'type' -and ([string]::IsNullOrEmpty($request.text) -or $request.text.Length -gt 65536 -or $request.text -match '[\x00-\x1F\x7F]')) { throw 'type exige du texte literal, sans caracteres de controle (maximum 65536). Utilisez key pour Enter ou Tab.' }
        }
        # Consume a frame once, before input, including uncertain/partial failures.
        Claim-ConsoleFrame $request.frame
        $performed = $true
        switch ($request.action) {
            { $_ -in @('move','click','scroll','drag') } {
                $null = Invoke-ConsoleMethod $context.mouse SetAbsolutePosition @{ horizontalPosition=[int]$request.x; verticalPosition=[int]$request.y }
                switch ($request.action) {
                    'click' { for ($i=0; $i -lt $request.count; $i++) {
                        $null = Invoke-ConsoleMethod $context.mouse ClickButton @{buttonIndex=[uint32]$request.buttonIndex}
                        if ($i -eq 0 -and $request.count -eq 2) { Start-Sleep -Milliseconds 80 }
                    } }
                    'scroll' { $null = Invoke-ConsoleMethod $context.mouse SetScrollPosition @{scrollPositionDelta=[int]$request.delta} }
                    'drag' {
                        try {
                            $null = Invoke-ConsoleMethod $context.mouse SetButtonState @{buttonIndex=[uint32]$request.buttonIndex;isDown=$true}
                            for ($step=1; $step -le 10; $step++) {
                                $null = Invoke-ConsoleMethod $context.mouse SetAbsolutePosition @{
                                    horizontalPosition=[int]($request.x + ($request.toX - $request.x) * $step / 10);
                                    verticalPosition=[int]($request.y + ($request.toY - $request.y) * $step / 10) }
                                Start-Sleep -Milliseconds 20
                            }
                        } finally { $null = Invoke-ConsoleMethod $context.mouse SetButtonState @{buttonIndex=[uint32]$request.buttonIndex;isDown=$false} }
                    }
                }
            }
            'key' {
                $pressed = New-Object 'System.Collections.Generic.List[uint32]'
                try {
                    foreach ($code in $keyCodes) {
                        $pressed.Add($code)
                        $null = Invoke-ConsoleMethod $context.keyboard PressKey @{keyCode=$code}
                    }
                    Start-Sleep -Milliseconds 40
                } finally {
                    $releaseError = $null
                    for ($index=$pressed.Count-1; $index -ge 0; $index--) {
                        try { $null = Invoke-ConsoleMethod $context.keyboard ReleaseKey @{keyCode=$pressed[$index]} }
                        catch { $releaseError = $_ }
                    }
                    if ($releaseError) { throw $releaseError }
                }
            }
            'type' {
                for ($offset=0; $offset -lt $request.text.Length;) {
                    $length = [Math]::Min(128, $request.text.Length - $offset)
                    if ([char]::IsHighSurrogate($request.text[$offset + $length - 1])) { $length-- }
                    if ($length -eq 0) { throw 'Texte Unicode invalide.' }
                    $null = Invoke-ConsoleMethod $context.keyboard TypeText @{asciiText=$request.text.Substring($offset, $length)}
                    $offset += $length
                }
                $answer.characters = $request.text.Length
            }
        }
        $answer.inputAttempted = $true
        $answer.referenceFrameId = $reference.frameId
        Start-Sleep -Milliseconds 250
        $context = Get-ConsoleContext $request
        $answer.frame = Save-ConsoleFrame $context $request
    }
    @{ExitCode=0;Stdout=($answer | ConvertTo-Json -Depth 8 -Compress);Stderr=''} |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResponsePath -Encoding UTF8
    exit 0
} catch {
    $message = $_.Exception.Message
    if ($performed) { $message += ' Une entree a ete tentee. Reobservez avant toute nouvelle action.' }
    @{ExitCode=1;Stdout='';Stderr=$message} | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $ResponsePath -Encoding UTF8
    exit 1
}
