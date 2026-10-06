#requires -Version 5.1
$ErrorActionPreference='Stop'
$stage='C:\ProgramData\vmctl\streaming'
$inputPath=Join-Path $stage 'api-input.json'
$bodyPath=Join-Path $stage 'api-body.json'
$cookiePath=Join-Path $stage 'api-cookie.txt'
$request=Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json
function Invoke-LocalApi([string]$Endpoint,[object]$Body) {
    $Body | ConvertTo-Json -Compress | Set-Content -LiteralPath $bodyPath -Encoding utf8
    # Certificate bypass is scoped to this loopback call, never a global TLS change.
    $output=& curl.exe --noproxy '*' --insecure --silent --show-error --fail --max-time 15 --cookie $cookiePath --cookie-jar $cookiePath --header 'Content-Type: application/json' --data-binary ('@'+$bodyPath) ('https://127.0.0.1:47990'+$Endpoint) 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Apollo local API failed: $Endpoint (curl $LASTEXITCODE)." }
    if ($output) { return ($output | ConvertFrom-Json) }
}
function Get-LocalApi([string]$Endpoint) {
    $output=& curl.exe --noproxy '*' --insecure --silent --show-error --fail --max-time 15 --cookie $cookiePath ('https://127.0.0.1:47990'+$Endpoint) 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Apollo local API failed: $Endpoint (curl $LASTEXITCODE)." }
    return ($output | ConvertFrom-Json)
}
try {
    if ($request.action -notin @('initialize','pair','login','configure-gpu')) { throw 'Unknown Apollo setup action.' }
    if ($request.action -eq 'initialize') {
        $result=Invoke-LocalApi '/api/password' @{newUsername=$request.username;newPassword=$request.password;confirmNewPassword=$request.password}
        if (-not $result.status) { throw 'Apollo administrator initialization rejected.' }
    }
    $null=Invoke-LocalApi '/api/login' @{username=$request.username;password=$request.password}
    $runningConfig=Get-LocalApi '/api/config'
    if($request.PSObject.Properties.Name -contains 'expectedVersion' -and $runningConfig.version -ne $request.expectedVersion){throw 'Running Apollo version differs from the selected release.'}
    $pinAccepted=$null
    $gpuConfig=$null
    if ($request.action -eq 'pair') {
        $deadline=(Get-Date).AddSeconds(20)
        do {
            $result=Invoke-LocalApi '/api/pin' @{pin=$request.pin;name=$request.clientName}
            $pinAccepted=[bool]$result.status
            if ($pinAccepted) { break }
            Start-Sleep -Seconds 1
        } while ((Get-Date) -lt $deadline)
        if (-not $pinAccepted) { throw 'No pending Moonlight pairing request accepted.' }
    }
    if ($request.action -eq 'configure-gpu') {
        $gpu=@(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -ceq $request.gpuName -and $_.ConfigManagerErrorCode -eq 0 })
        if ($gpu.Count -ne 1 -or $request.gpuName -notmatch '^NVIDIA ') { throw 'A healthy matching NVIDIA GPU is required before forcing NVENC.' }
        $existing=Get-LocalApi '/api/config'
        $settings=@{}
        foreach($property in $existing.PSObject.Properties) {
            if ($property.Name -notin @('status','platform','version','vdisplayStatus')) { $settings[$property.Name]=$property.Value }
        }
        $backup=Join-Path $stage 'apollo-config-before-gpu.json'
        if (-not(Test-Path -LiteralPath $backup)) { $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $backup -Encoding utf8 }
        $settings.adapter_name=[string]$request.gpuName
        $settings.encoder='nvenc'
        $settings.headless_mode='enabled'
        # GPU-P capture can continuously lose access while the Hyper-V output is active.
        # Restore the console topology when streaming ends.
        $settings.dd_configuration_option='ensure_only_display'
        $settings.dd_config_revert_on_disconnect='enabled'
        $settings.dd_resolution_option='auto'
        $settings.dd_refresh_rate_option='auto'
        $result=Invoke-LocalApi '/api/config' $settings
        if (-not $result.status) { throw 'Apollo GPU configuration rejected.' }
        $saved=Get-LocalApi '/api/config'
        if ($saved.encoder -ne 'nvenc' -or $saved.adapter_name -cne $request.gpuName) { throw 'Apollo GPU settings were not saved.' }
        Restart-Service -Name ApolloService -ErrorAction Stop
        $deadline=(Get-Date).AddSeconds(30)
        do {
            if (Get-NetTCPConnection -LocalPort 47990 -State Listen -ErrorAction SilentlyContinue) { break }
            if ((Get-Date) -ge $deadline) { throw 'Apollo web service did not return after its restart.' }
            Start-Sleep -Seconds 1
        } while ($true)
        $gpuConfig=@{adapter=$saved.adapter_name;encoder=$saved.encoder;headless=$saved.headless_mode;backup=$backup;serviceRestarted=$true}
    }
    [pscustomobject]@{action=$request.action;authenticated=$true;runningVersion=$runningConfig.version;pinAccepted=$pinAccepted;gpuConfig=$gpuConfig} | ConvertTo-Json -Depth 5
} finally {
    foreach ($path in @($inputPath,$bodyPath,$cookiePath)) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
}
