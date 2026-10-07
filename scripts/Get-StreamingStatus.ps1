#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$Vm,
    [Parameter(Mandatory)][string]$VmName,
    [string]$VmId,
    [string]$HostName,
    [switch]$Diagnostics,
    [switch]$VideoSettingsOnly,
    [ValidateSet('status','display-fix','display-restore','video-test','video-restore')][string]$Mode='status',
    [ValidateSet('software','nvenc')][string]$Encoder,
    [switch]$DefaultAdapter, [switch]$ConsoleDisplay, [switch]$OnlyDisplay, [switch]$PrimaryDisplay, [switch]$DisableRealtimePriority, [switch]$EnableModernCodecs,
    [ValidateRange(1,7)][int]$NvencPreset,
    [ValidateSet('disabled','quarter_res','full_res')][string]$NvencTwoPass
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
if($VideoSettingsOnly -and (-not $Diagnostics -or $Mode -ne 'status')){throw 'VideoSettingsOnly requires read-only status diagnostics.'}
. (Join-Path $PSScriptRoot '../src/DataPaths.ps1')
if ($Mode -eq 'video-test' -and -not $Encoder) { throw 'video-test requires an encoder.' }
if ($EnableModernCodecs -and ($Mode -ne 'video-test' -or $Encoder -ne 'nvenc')) { throw 'EnableModernCodecs requires video-test with nvenc.' }
if (($PSBoundParameters.ContainsKey('NvencPreset') -or $NvencTwoPass) -and ($Mode -ne 'video-test' -or $Encoder -ne 'nvenc')) { throw 'NVENC quality options require video-test with nvenc.' }
if ($ConsoleDisplay -and $OnlyDisplay) { throw 'ConsoleDisplay and OnlyDisplay are mutually exclusive.' }
if ($PrimaryDisplay -and ($ConsoleDisplay -or $OnlyDisplay)) { throw 'PrimaryDisplay, ConsoleDisplay and OnlyDisplay are mutually exclusive.' }
if ($DisableRealtimePriority -and ($Mode -ne 'video-test' -or $Encoder -ne 'nvenc')) { throw 'DisableRealtimePriority requires video-test with nvenc.' }
$credentialPath=Join-Path (Get-VmctlDataRoot) "credentials\apollo-$Vm.clixml"
if (-not(Test-Path -LiteralPath $credentialPath)) { throw 'The saved Apollo administrator credential is missing.' }
$registry='HKCU:\Software\Moonlight Game Streaming Project\Moonlight\hosts'
$bindingPath=Join-Path (Get-VmctlDataRoot) "streaming-bindings\$Vm.json"
$serverUuid=''
if(Test-Path -LiteralPath $bindingPath) {
    $binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json
    if($binding.vmName -ine $VmName -or ($VmId -and $binding.vmId -ine $VmId)){throw 'Saved Apollo binding does not match the configured Hyper-V VM.'}
    $serverUuid=[guid]::Parse($binding.serverUuid).ToString()
}
$hosts=@(Get-ChildItem -LiteralPath $registry -ErrorAction Stop | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath } | Where-Object {
    # With a saved UUID, HostName can override a stale DHCP address. TLS remains
    # pinned to that UUID's paired certificate before credentials are sent.
    (($serverUuid -and $_.uuid -ieq $serverUuid) -or (-not $serverUuid -and $_.hostname -ieq $VmName -and (-not $HostName -or $HostName -in @($_.localaddress,$_.manualaddress,$_.remoteaddress))))
})
if ($hosts.Count -ne 1 -or -not $hosts[0].srvcert) { throw 'Select a unique paired Moonlight host with its stored server certificate.' }
$selected=$hosts[0]
$address=if ($HostName) { $HostName } elseif ($selected.localaddress) { $selected.localaddress } else { $selected.manualaddress }
if(-not $HostName -and $binding -and $binding.vmId){
    Import-Module (Join-Path $PSScriptRoot '../src/Vmctl.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../src/StreamingSupport.psm1') -Force
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if((Test-VmctlBrokerInstalled) -or $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
        $network=Invoke-VmctlHyperV -Target @{os='windows';hypervisor='hyperv';vmName=$VmName;vmId=[string]$binding.vmId} -Action network -TimeoutSeconds 20
        if($network.ExitCode -ne 0){throw "Impossible de vérifier l'adresse Hyper-V : $($network.Stderr)"}
        $guestNetwork=$network.Stdout|ConvertFrom-Json
        $address=Select-VmctlApolloAddress -GuestAddresses $guestNetwork.addresses -CachedAddress $address
    }
}
$ip=$null
if (-not[Net.IPAddress]::TryParse($address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'A cached IPv4 address is required.' }
$pem=[string]$selected.srvcert
if ($pem.StartsWith('@ByteArray(') -and $pem.EndsWith(')')) { $pem=$pem.Substring(11,$pem.Length-12) }
$pem=$pem.Replace('\n',"`n").Replace('\r',"`r")
$certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($pem)
$expectedHash=$certificate.GetCertHashString([Security.Cryptography.HashAlgorithmName]::SHA256)
$certificate.Dispose()
# Pin the already paired server certificate before transmitting administrator credentials.
# The callback is C#, since TLS callbacks execute without a PowerShell runspace.
if (-not ('VmctlPinnedApolloClient' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
public static class VmctlPinnedApolloClient {
    public static HttpClient Create(string expected) {
        var handler = new HttpClientHandler();
        handler.UseProxy = false;
        handler.AllowAutoRedirect = false;
        handler.CookieContainer = new CookieContainer();
        handler.ServerCertificateCustomValidationCallback = (request, cert, chain, errors) =>
            cert != null && String.Equals(cert.GetCertHashString(HashAlgorithmName.SHA256), expected, StringComparison.OrdinalIgnoreCase);
        return new HttpClient(handler, true) { Timeout = TimeSpan.FromSeconds(15) };
    }
}
'@
}
$client=[VmctlPinnedApolloClient]::Create($expectedHash)
$baseUri="https://${address}:47990"
$content=$null; $response=$null
$requestPath='/api/login'
try {
    $credential=Import-Clixml -LiteralPath $credentialPath
    $json=@{username=$credential.UserName;password=$credential.GetNetworkCredential().Password} | ConvertTo-Json -Compress
    $content=[Net.Http.StringContent]::new($json,[Text.Encoding]::UTF8,'application/json')
    $response=$client.PostAsync($baseUri+'/api/login',$content).GetAwaiter().GetResult()
    $null=$response.EnsureSuccessStatusCode()
    $response.Dispose(); $response=$null
    $content.Dispose(); $content=$null; $json=$null
    $result=@{status=$true;named_certs=@()}
    if(-not $VideoSettingsOnly){
        $requestPath='/api/clients/list'
        $response=$client.GetAsync($baseUri+$requestPath).GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $result=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if (-not $result.status) { throw 'Apollo did not return the paired client list.' }
    }
    $configurationResult=$null
    if ($Mode -ne 'status') {
        if (@($result.named_certs | Where-Object connected).Count) { throw 'Disconnect the Moonlight stream before changing display configuration.' }
        $requestPath='/api/config'
        $response.Dispose(); $response=$client.GetAsync($baseUri+'/api/config').GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $current=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $settingsToSave=@{}
        foreach($property in $current.PSObject.Properties) {
            if ($property.Name -notin @('status','platform','version','vdisplayStatus')) { $settingsToSave[$property.Name]=$property.Value }
        }
        $backupFolder=Join-Path (Get-VmctlDataRoot) "reports\streaming\$Vm"
        $backupName=if ($Mode.StartsWith('video-')) { 'apollo-video-before.clixml' } else { 'apollo-display-before.clixml' }
        $backup=Join-Path $backupFolder $backupName
        if ($Mode -in @('display-fix','video-test')) {
            if (-not(Test-Path -LiteralPath $backup)) {
                $null=New-Item -ItemType Directory -Path $backupFolder -Force
                ($settingsToSave | ConvertTo-Json -Depth 10) | ConvertTo-SecureString -AsPlainText -Force | Export-Clixml -LiteralPath $backup
            }
            if ($Mode -eq 'display-fix') {
                $settingsToSave.dd_configuration_option=if ($current.headless_mode -eq 'enabled' -and $current.adapter_name -match '^NVIDIA ') { 'ensure_only_display' } else { 'ensure_primary' }
                $settingsToSave.dd_config_revert_on_disconnect='enabled'
                $settingsToSave.dd_resolution_option='auto'
                $settingsToSave.dd_refresh_rate_option='auto'
                $settingsToSave.min_log_level='info'
            } else {
                if ($PSBoundParameters.ContainsKey('NvencPreset') -or $NvencTwoPass) {
                    $qualityBackup=Join-Path $backupFolder ('apollo-quality-before-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.clixml')
                    ($settingsToSave | ConvertTo-Json -Depth 10) | ConvertTo-SecureString -AsPlainText -Force | Export-Clixml -LiteralPath $qualityBackup
                }
                $settingsToSave.encoder=$Encoder
                if ($PSBoundParameters.ContainsKey('NvencPreset')) { $settingsToSave.nvenc_preset=[string]$NvencPreset }
                if ($NvencTwoPass) { $settingsToSave.nvenc_twopass=$NvencTwoPass }
                $settingsToSave.hevc_mode=if($EnableModernCodecs){'0'}else{'1'}
                $settingsToSave.av1_mode=if($EnableModernCodecs){'0'}else{'1'}
                $settingsToSave.min_log_level='debug'
                if ($DisableRealtimePriority) { $settingsToSave.nvenc_realtime_hags='disabled' }
                if ($DefaultAdapter) { $settingsToSave.adapter_name='' }
                if ($ConsoleDisplay) {
                    $settingsToSave.headless_mode='disabled'
                    $settingsToSave.output_name=''
                    $settingsToSave.dd_configuration_option='disabled'
                }
                if ($OnlyDisplay) {
                    $settingsToSave.headless_mode='enabled'
                    $settingsToSave.output_name=''
                    $settingsToSave.dd_configuration_option='ensure_only_display'
                }
                if ($PrimaryDisplay) {
                    $settingsToSave.headless_mode='enabled'
                    $settingsToSave.output_name=''
                    $settingsToSave.dd_configuration_option='ensure_primary'
                }
            }
        } else {
            $saved=Import-Clixml -LiteralPath $backup
            $previousSettings=([Net.NetworkCredential]::new('',[Security.SecureString]$saved).Password | ConvertFrom-Json -AsHashtable)
            $restoreKeys=if ($Mode -eq 'video-restore') { @('encoder','hevc_mode','av1_mode','min_log_level','adapter_name','headless_mode','output_name','dd_configuration_option','nvenc_realtime_hags') } else { @('dd_configuration_option','dd_config_revert_on_disconnect','dd_resolution_option','dd_refresh_rate_option','min_log_level') }
            foreach($setting in $restoreKeys) {
                if ($previousSettings.ContainsKey($setting)) { $settingsToSave[$setting]=$previousSettings[$setting] }
                else { $settingsToSave.Remove($setting) }
            }
        }
        $response.Dispose(); $response=$null
        $content=[Net.Http.StringContent]::new(($settingsToSave | ConvertTo-Json -Compress -Depth 10),[Text.Encoding]::UTF8,'application/json')
        $response=$client.PostAsync($baseUri+'/api/config',$content).GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $savedResult=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if (-not $savedResult.status) { throw 'Apollo display configuration was rejected.' }
        $response.Dispose(); $response=$null; $content.Dispose(); $content=$null
        $response=$client.GetAsync($baseUri+'/api/config').GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $verified=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ($Mode -eq 'display-fix' -and ($verified.dd_configuration_option -ne $settingsToSave.dd_configuration_option -or $verified.dd_resolution_option -ne 'auto' -or $verified.dd_refresh_rate_option -ne 'auto')) { throw 'The requested display configuration was not saved.' }
        if ($Mode -eq 'video-test' -and $verified.encoder -ne $Encoder) { throw 'The requested encoder was not saved.' }
        if ($EnableModernCodecs -and ($verified.hevc_mode -ne '0' -or $verified.av1_mode -ne '0')) { throw 'Modern codec detection was not enabled.' }
        if ($PSBoundParameters.ContainsKey('NvencPreset') -and [int]$verified.nvenc_preset -ne $NvencPreset) { throw 'NVENC preset was not saved.' }
        if ($NvencTwoPass -and $verified.nvenc_twopass -ne $NvencTwoPass) { throw 'NVENC two-pass mode was not saved.' }
        if ($DisableRealtimePriority -and $verified.nvenc_realtime_hags -ne 'disabled') { throw 'NVENC realtime priority was not disabled.' }
        $response.Dispose(); $response=$null
        $content=[Net.Http.StringContent]::new('{}',[Text.Encoding]::UTF8,'application/json')
        $requestPath='/api/restart'
        # Apollo may close this connection when restarting; verify its return afterward.
        try { $response=$client.PostAsync($baseUri+'/api/restart',$content).GetAwaiter().GetResult(); $null=$response.EnsureSuccessStatusCode() }
        catch [Net.Http.HttpRequestException] { }
        $deadline=[DateTimeOffset]::UtcNow.AddSeconds(35)
        do {
            Start-Sleep -Seconds 1
            try {
                $requestPath='/login'
                $restartProbe=$client.GetAsync($baseUri+'/login').GetAwaiter().GetResult()
                $ready=$restartProbe.IsSuccessStatusCode; $restartProbe.Dispose()
            } catch { $ready=$false }
        } until ($ready -or [DateTimeOffset]::UtcNow -ge $deadline)
        if (-not $ready) { throw 'Apollo did not return after restarting.' }
        $configurationResult=@{mode=$Mode;encoder=$verified.encoder;primaryDisplay=$verified.dd_configuration_option;nvencRealtimeHags=$verified.nvenc_realtime_hags;revertOnDisconnect=$verified.dd_config_revert_on_disconnect;encryptedBackup=$backup;apolloRestarted=$true}
        if ($PSBoundParameters.ContainsKey('NvencPreset') -or $NvencTwoPass) {
            $configurationResult.nvencPreset=$verified.nvenc_preset
            $configurationResult.nvencTwoPass=$verified.nvenc_twopass
            $configurationResult.qualityBackup=$qualityBackup
        }
    }
    $diagnostic=$null
    if ($Diagnostics) {
        $requestPath='/api/config'
        if($response){$response.Dispose()}
        $response=$client.GetAsync($baseUri+'/api/config').GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $settings=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $log=''
        if(-not $VideoSettingsOnly){
            $requestPath='/api/logs'
            $response.Dispose(); $response=$client.GetAsync($baseUri+$requestPath).GetAwaiter().GetResult()
            $null=$response.EnsureSuccessStatusCode()
            $log=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        $lines=@($log -split '\r?\n')
        $safeLines=@($lines | Where-Object { $_ -notmatch 'password|pin=|clientcert|rikey|Authorization|Cookie|^(Red|Green|Blue) Primary|Client dynamicRange' })
        $diagnostic=@{
            videoSettings=($settings | Select-Object adapter_name,output_name,capture,encoder,headless_mode,nvenc_preset,nvenc_twopass,nvenc_realtime_hags,nvenc_latency_over_power,dd_configuration_option,dd_resolution_option,dd_refresh_rate_option,hevc_mode,av1_mode,min_log_level,vdisplayStatus)
            displayLog=@($safeLines | Where-Object { $_ -match 'Error:|Warning:|CLIENT |Virtual Display|virtual display|Winlogon|SESSION|session|display_device|\bprimary\b|configuration|optimization|Desktop switch|display name|Display:' } | Select-Object -Last 100)
            displayApiLog=@($safeLines | Where-Object { $_ -match 'Trying to apply display device settings\. API is available:' } | Select-Object -Last 10)
            log=@($safeLines | Where-Object { $_ -match 'Error:|Warning:|Device Description|Feature Level|Capture size|Desktop resolution|Display refresh rate|Requested frame rate|Creating encoder|NvEnc:|CLIENT |Virtual Display|virtual display|desktop switch|Winlogon|SESSION|session' } | Select-Object -Last 90)
            debugLog=@($safeLines | Where-Object { $_ -match 'Debug:' -and $_ -match 'captur|frame|desktop|timeout|DXGI|D3D|duplicat|encode|switch|display|is_user_session_locked' } | Select-Object -Last 80)
            sessionLockLog=@($safeLines | Where-Object { $_ -match 'is_user_session_locked:' } | Select-Object -Last 5)
        }
    }
    [pscustomobject]@{
        vm=$Vm;address=$address;webUi=$baseUri;serverCertificateVerified=$true
        serverCertificateSha256=$expectedHash;moonlightHostUuid=$selected.uuid
        clients=@($result.named_certs | Select-Object name,uuid,perm,connected,display_mode)
        diagnostics=$diagnostic
        configuration=$configurationResult
        guestWindowsCredentialRequired=$false;checkedAt=[DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 6
} catch {
    $failureException=$_.Exception.GetBaseException()
    $exception=$_.Exception
    $isTimeout=$false
    while($exception){
        if($exception -is [TimeoutException] -or $exception -is [Threading.Tasks.TaskCanceledException]){$isTimeout=$true}
        $exception=$exception.InnerException
    }
    if($isTimeout){[Console]::Error.WriteLine("APOLLO_TIMEOUT: ${baseUri}${requestPath} n’a pas répondu dans le délai de 15 secondes.")}
    else{[Console]::Error.WriteLine(('API Apollo : '+$_.Exception.GetBaseException().Message))}
    # Persist only request identity and error type, never bodies or credentials.
    try{
        $failureFolder=Join-Path (Get-VmctlDataRoot) "reports\streaming\$Vm"
        $null=New-Item -ItemType Directory -Path $failureFolder -Force
        @{vm=$Vm;address=$address;requestPath=$requestPath;mode=$Mode;timeout=$isTimeout;exceptionType=$failureException.GetType().FullName;failedAt=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $failureFolder 'apollo-last-failure.json') -Encoding utf8
    }catch{ }
    exit 1
} finally {
    if ($response) { $response.Dispose() }
    if ($content) { $content.Dispose() }
    $client.Dispose()
}
