#requires -Version 7.2
function Invoke-VmctlConsole {
    param([hashtable]$Target, [string]$Vm,
        [ValidateSet('capabilities','screenshot','move','click','type','key','scroll','drag')][string]$Action,
        [string]$OutFile, [string]$Frame, [string]$Text, [string]$Keys,
        [int]$X=-1, [int]$Y=-1, [int]$ToX=-1, [int]$ToY=-1,
        [ValidateRange(1,5)][int]$ButtonIndex=1, [ValidateRange(1,2)][int]$Count=1, [int]$Delta,
        [ValidateRange(1,600)][int]$MaxFrameAgeSeconds=120, [switch]$Elevate, [int]$TimeoutSeconds=120)
    if ($Action -eq 'capabilities' -and $Target.hypervisor -ne 'hyperv') {
        $description = @{vm=$Vm; backend='none'; console=@{screenshot=$false;keyboard=$false;mouse=$false};
            command=@{transport=(Get-VmctlTransport $Target);status='not-probed';probe="vmctl doctor -Vm $Vm"}} | ConvertTo-Json -Depth 5 -Compress
        return [pscustomobject]@{ExitCode=0;Stdout=$description;Stderr=''}
    }
    if (-not $IsWindows -or $Target.hypervisor -ne 'hyperv' -or -not $Target.vmName) {
        throw 'Console disponible pour les cibles Hyper-V locales avec hypervisor=hyperv et vmName.'
    }
    if ($Action -notin @('capabilities','screenshot') -and -not $Frame) { throw 'Une entree exige -Frame (JSON de la derniere capture).' }
    if ($Action -in @('move','click','scroll','drag') -and ($X -lt 0 -or $Y -lt 0)) { throw 'Cette action exige -X et -Y positifs ou nuls.' }
    if ($Action -eq 'drag' -and ($ToX -lt 0 -or $ToY -lt 0)) { throw 'drag exige -ToX et -ToY.' }
    if ($Action -eq 'type' -and -not $Text) { throw 'type exige -Text.' }
    if ($Action -eq 'key' -and -not $Keys) { throw 'key exige -Keys.' }
    if ($Action -eq 'scroll' -and $Delta -eq 0) { throw 'scroll exige -Delta non nul (exemple -120).' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin -and -not $Elevate) { throw 'La console Hyper-V exige les droits administrateur. Utilisez un terminal eleve ou ajoutez -Elevate (UAC).' }
    $vmId = if ($Target.ContainsKey('vmId')) { ([Guid]::Parse($Target.vmId)).ToString() } else { '' }
    $taskId = [Guid]::NewGuid().ToString('N')
    if (-not $OutFile -and $Action -ne 'capabilities') { $OutFile = Join-Path (Get-VmctlDataRoot) "captures/$Vm/$taskId.png" }
    if ($OutFile) {
        $OutFile = [IO.Path]::GetFullPath($OutFile)
        if ([IO.Path]::GetExtension($OutFile) -ine '.png') { throw 'OutFile exige un fichier .png.' }
        if ((Test-Path -LiteralPath $OutFile) -or (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($OutFile,'.json')))) { throw 'Le fichier de sortie existe deja. Choisissez un nouveau chemin.' }
    }
    if ($Frame) { $Frame = (Resolve-Path -LiteralPath $Frame -ErrorAction Stop).ProviderPath }
    $folder = Join-Path (Get-VmctlDataRoot) 'work'
    $null = New-Item -ItemType Directory -Path $folder -Force
    $requestPath = Join-Path $folder "$taskId.request.json"
    $responsePath = Join-Path $folder "$taskId.response.json"
    $worker = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts/Invoke-HyperVConsole.ps1'))
    $request = @{ action=$Action; vm=$Vm; vmName=$Target.vmName; vmId=$vmId; transport=(Get-VmctlTransport $Target); outFile=$OutFile; frame=$Frame;
        text=$Text; keys=$Keys; x=$X; y=$Y; toX=$ToX; toY=$ToY; buttonIndex=$ButtonIndex;
        count=$Count; delta=$Delta; maxFrameAgeSeconds=$MaxFrameAgeSeconds }
    $request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $requestPath -Encoding utf8
    $exe = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $timedOut = $false
    try {
        if (-not $admin) {
            # UAC belongs to the user. Only the finite console worker is elevated.
            $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',('"' + $worker + '"'),
                '-RequestPath',('"' + $requestPath + '"'),'-ResponsePath',('"' + $responsePath + '"'))
            $process = Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru
            try { $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000) } finally { $process.Dispose() }
        } else {
            $localResult = Invoke-VmctlProcess $exe @('-NoLogo','-NoProfile','-NonInteractive','-File',$worker,
                '-RequestPath',$requestPath,'-ResponsePath',$responsePath) -TimeoutSeconds $TimeoutSeconds
            $timedOut = $localResult.ExitCode -eq 124
        }
        if ($timedOut) { return [pscustomobject]@{ExitCode=124;Stdout='';Stderr="Delai console depasse. Une entree peut avoir ete effectuee : reobservez, aucune nouvelle tentative. Resultat eventual : $responsePath"} }
        if (-not (Test-Path -LiteralPath $responsePath)) {
            $detail = if ($admin) { $localResult.Stderr } else { 'Processus eleve termine sans reponse.' }
            throw "Le backend console n a pas produit de reponse : $detail"
        }
        return Get-Content -LiteralPath $responsePath -Raw -Encoding utf8 | ConvertFrom-Json
    } finally {
        # If an elevated worker is still running, retain its request/result until inspected.
        if (-not $timedOut) {
            foreach ($path in @($requestPath,$responsePath)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue } }
        }
    }
}
