#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$Vm,
    [Parameter(Mandatory)][string]$VmName,
    [string]$HostName,
    [switch]$Diagnostics,
    [ValidateSet('status','display-fix','display-restore','video-test','video-restore')][string]$Mode='status',
    [ValidateSet('software','nvenc')][string]$Encoder,
    [switch]$DefaultAdapter, [switch]$ConsoleDisplay, [switch]$OnlyDisplay
)
$ErrorActionPreference='Stop'
if ($Mode -eq 'video-test' -and -not $Encoder) { throw 'video-test requires an encoder.' }
if ($ConsoleDisplay -and $OnlyDisplay) { throw 'ConsoleDisplay and OnlyDisplay are mutually exclusive.' }
$credentialPath=Join-Path $env:LOCALAPPDATA "vmctl\credentials\apollo-$Vm.clixml"
if (-not(Test-Path -LiteralPath $credentialPath)) { throw 'The saved Apollo administrator credential is missing.' }
$registry='HKCU:\Software\Moonlight Game Streaming Project\Moonlight\hosts'
$hosts=@(Get-ChildItem -LiteralPath $registry -ErrorAction Stop | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath } | Where-Object {
    $_.hostname -ieq $VmName -and (-not $HostName -or $HostName -in @($_.localaddress,$_.manualaddress,$_.remoteaddress))
})
if ($hosts.Count -ne 1 -or -not $hosts[0].srvcert) { throw 'Select a unique paired Moonlight host with its stored server certificate.' }
$selected=$hosts[0]
$address=if ($HostName) { $HostName } elseif ($selected.localaddress) { $selected.localaddress } else { $selected.manualaddress }
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
try {
    $credential=Import-Clixml -LiteralPath $credentialPath
    $json=@{username=$credential.UserName;password=$credential.GetNetworkCredential().Password} | ConvertTo-Json -Compress
    $content=[Net.Http.StringContent]::new($json,[Text.Encoding]::UTF8,'application/json')
    $response=$client.PostAsync($baseUri+'/api/login',$content).GetAwaiter().GetResult()
    $null=$response.EnsureSuccessStatusCode()
    $response.Dispose(); $response=$null
    $content.Dispose(); $content=$null; $json=$null
    $response=$client.GetAsync($baseUri+'/api/clients/list').GetAwaiter().GetResult()
    $null=$response.EnsureSuccessStatusCode()
    $result=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
    if (-not $result.status) { throw 'Apollo did not return the paired client list.' }
    $configurationResult=$null
    if ($Mode -ne 'status') {
        if (@($result.named_certs | Where-Object connected).Count) { throw 'Disconnect the Moonlight stream before changing display configuration.' }
        $response.Dispose(); $response=$client.GetAsync($baseUri+'/api/config').GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $current=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $settingsToSave=@{}
        foreach($property in $current.PSObject.Properties) {
            if ($property.Name -notin @('status','platform','version','vdisplayStatus')) { $settingsToSave[$property.Name]=$property.Value }
        }
        $backupFolder=Join-Path $env:LOCALAPPDATA "vmctl\reports\streaming\$Vm"
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
                $settingsToSave.encoder=$Encoder
                $settingsToSave.hevc_mode='1'
                $settingsToSave.av1_mode='1'
                $settingsToSave.min_log_level='debug'
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
            }
        } else {
            $saved=Import-Clixml -LiteralPath $backup
            $previousSettings=([Net.NetworkCredential]::new('',[Security.SecureString]$saved).Password | ConvertFrom-Json -AsHashtable)
            $restoreKeys=if ($Mode -eq 'video-restore') { @('encoder','hevc_mode','av1_mode','min_log_level','adapter_name','headless_mode','output_name','dd_configuration_option') } else { @('dd_configuration_option','dd_config_revert_on_disconnect','dd_resolution_option','dd_refresh_rate_option','min_log_level') }
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
        $response.Dispose(); $response=$null
        $content=[Net.Http.StringContent]::new('{}',[Text.Encoding]::UTF8,'application/json')
        # Apollo may close this connection when restarting; verify its return afterward.
        try { $response=$client.PostAsync($baseUri+'/api/restart',$content).GetAwaiter().GetResult(); $null=$response.EnsureSuccessStatusCode() }
        catch [Net.Http.HttpRequestException] { }
        $deadline=[DateTimeOffset]::UtcNow.AddSeconds(35)
        do {
            Start-Sleep -Seconds 1
            try {
                $restartProbe=$client.GetAsync($baseUri+'/login').GetAwaiter().GetResult()
                $ready=$restartProbe.IsSuccessStatusCode; $restartProbe.Dispose()
            } catch { $ready=$false }
        } until ($ready -or [DateTimeOffset]::UtcNow -ge $deadline)
        if (-not $ready) { throw 'Apollo did not return after restarting.' }
        $configurationResult=@{mode=$Mode;encoder=$verified.encoder;primaryDisplay=$verified.dd_configuration_option;revertOnDisconnect=$verified.dd_config_revert_on_disconnect;encryptedBackup=$backup;apolloRestarted=$true}
    }
    $diagnostic=$null
    if ($Diagnostics) {
        $response.Dispose(); $response=$client.GetAsync($baseUri+'/api/config').GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $settings=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        $response.Dispose(); $response=$client.GetAsync($baseUri+'/api/logs').GetAwaiter().GetResult()
        $null=$response.EnsureSuccessStatusCode()
        $log=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $lines=@($log -split '\r?\n')
        $safeLines=@($lines | Where-Object { $_ -notmatch 'password|pin=|clientcert|rikey|Authorization|Cookie|^(Red|Green|Blue) Primary|Client dynamicRange' })
        $diagnostic=@{
            videoSettings=($settings | Select-Object adapter_name,output_name,capture,encoder,headless_mode,nvenc_realtime_hags,nvenc_latency_over_power,dd_configuration_option,dd_resolution_option,dd_refresh_rate_option,hevc_mode,av1_mode,min_log_level,vdisplayStatus)
            displayLog=@($safeLines | Where-Object { $_ -match 'Error:|Warning:|CLIENT |Virtual Display|virtual display|Winlogon|SESSION|session|display_device|\bprimary\b|configuration|optimization|Desktop switch|display name|Display:' } | Select-Object -Last 100)
            log=@($safeLines | Where-Object { $_ -match 'Error:|Warning:|Device Description|Feature Level|Capture size|Desktop resolution|Display refresh rate|Requested frame rate|Creating encoder|NvEnc:|CLIENT |Virtual Display|virtual display|desktop switch|Winlogon|SESSION|session' } | Select-Object -Last 90)
            debugLog=@($safeLines | Where-Object { $_ -match 'Debug:' -and $_ -match 'captur|frame|desktop|timeout|DXGI|D3D|duplicat|encode|switch|display' } | Select-Object -Last 80)
        }
    }
    [pscustomobject]@{
        vm=$Vm;address=$address;webUi=$baseUri;serverCertificateVerified=$true
        serverCertificateSha256=$expectedHash;moonlightHostUuid=$selected.uuid
        clients=@($result.named_certs | Select-Object name,uuid,perm,connected)
        diagnostics=$diagnostic
        configuration=$configurationResult
        guestWindowsCredentialRequired=$false;checkedAt=[DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 6
} finally {
    if ($response) { $response.Dispose() }
    if ($content) { $content.Dispose() }
    $client.Dispose()
}
