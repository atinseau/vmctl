#requires -Version 7.2
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$Vm,
    [Parameter(Mandatory)][string]$VmName,[string]$VmId,[switch]$Reconnect
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Vmctl.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../src/StreamingSupport.psm1') -Force
$bindingPath=Join-Path (Get-VmctlDataRoot) "streaming-bindings\$Vm.json"
if(-not(Test-Path -LiteralPath $bindingPath)){throw 'No saved streaming binding; run streaming-install first.'}
$binding=Get-Content -LiteralPath $bindingPath -Raw|ConvertFrom-Json
if($binding.vmName -ine $VmName -or ($VmId -and $binding.vmId -ine $VmId)){throw 'Saved streaming binding belongs to another VM.'}
$uuid=[guid]::Parse($binding.serverUuid).ToString()
$hosts=@(Get-VmctlMoonlightHost -ServerUuid $uuid)
if($hosts.Count -ne 1){throw 'A unique Moonlight profile is required.'}
$moonlight=Join-Path $env:ProgramFiles 'Moonlight Game Streaming\Moonlight.exe'
$reportDirectory=Join-Path (Get-VmctlDataRoot) "reports\streaming\$Vm"
$activePath=Join-Path $reportDirectory 'streaming-active.json'
$null=New-Item -ItemType Directory -Path $reportDirectory -Force
$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Moonlight Game Streaming Project\Moonlight')
try {
    $fps=[int]$key.GetValue('fps',60)
    $width=[int]$key.GetValue('width',1920);$height=[int]$key.GetValue('height',1080)
    $absolute=[bool]$key.GetValue('mouseacceleration',0)
} finally {$key.Dispose()}
if($fps -lt 10 -or $fps -gt 480 -or $width -lt 320 -or $width -gt 16384 -or $height -lt 240 -or $height -gt 16384){throw 'Saved streaming dimensions or frame rate are invalid.'}
$processes=@(Get-Process Moonlight -ErrorAction SilentlyContinue)
$alreadyOpen=$false;$logPath=''
if($processes.Count) {
    if($processes.Count -ne 1){throw 'Multiple Moonlight processes require review.'}
    $process=$processes[0]
    $saved=if(Test-Path -LiteralPath $activePath){Get-Content -LiteralPath $activePath -Raw|ConvertFrom-Json}else{$null}
    $savedMatches=($saved -and $saved.serverUuid -ieq $uuid -and $saved.pid -eq $process.Id -and $saved.startTicks -eq $process.StartTime.ToUniversalTime().Ticks)
    $commandLine=(Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)").CommandLine
    if(-not $savedMatches -and (-not $commandLine -or $commandLine -notmatch ([regex]::Escape($uuid)))){throw 'The open Moonlight process cannot be identified as this VM; close it first.'}
    if($savedMatches){$logPath=[string]$saved.logPath}
    else {
        $legacy=@(Get-ChildItem -LiteralPath $reportDirectory -Filter '*.stderr.log' -File|Where-Object {$_.CreationTimeUtc -ge $process.StartTime.ToUniversalTime().AddSeconds(-1)}|Sort-Object CreationTimeUtc)
        if($legacy.Count){$logPath=$legacy[0].FullName}
    }
    $alreadyOpen=$true
    if($Reconnect) {
        $null=$process.CloseMainWindow()
        if(-not $process.WaitForExit(15000)){throw 'The matching Moonlight stream did not close cleanly.'}
        $process=$null;$alreadyOpen=$false;$logPath=''
    }
}
if(-not $alreadyOpen) {
    $list=Invoke-VmctlProcess $moonlight @('list',$uuid) -TimeoutSeconds 45
    if($list.ExitCode -ne 0 -or $list.Stdout -notmatch 'Virtual Display'){throw "The paired Virtual Display is unavailable: $($list.Stderr)"}
    # ShellExecute detaches the GUI from redirected CLI pipes; Moonlight supplies
    # its own TEMP log. Inherited pipes can otherwise leave the caller stuck.
    $mouseOption=if($absolute){'--absolute-mouse'}else{'--no-absolute-mouse'}
    $arguments="stream $uuid `"Virtual Display`" --resolution ${width}x${height} --fps $fps --video-codec H.264 $mouseOption --display-mode windowed"
    $principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $newPid=& (Join-Path $PSScriptRoot 'Start-InteractiveProcess.ps1') -Executable $moonlight -Arguments $arguments -WorkingDirectory (Split-Path $moonlight)
        $process=Get-Process -Id $newPid
    } else {
        $info=[Diagnostics.ProcessStartInfo]::new($moonlight)
        $info.UseShellExecute=$true;$info.WorkingDirectory=Split-Path $moonlight;$info.Arguments=$arguments
        $process=[Diagnostics.Process]::Start($info)
    }
}
$record=@{vm=$Vm;serverUuid=$uuid;pid=$process.Id;startTicks=$process.StartTime.ToUniversalTime().Ticks;resolution="${width}x${height}";fps=$fps;absoluteMouse=$absolute;logPath=$logPath}
$record|ConvertTo-Json|Set-Content -LiteralPath $activePath
$deadline=(Get-Date).AddSeconds(30)
do {
    $process.Refresh()
    if($process.HasExited){throw "Moonlight exited while opening the stream; see $logPath"}
    if(-not $logPath){
        $logs=@(Get-ChildItem -LiteralPath $env:TEMP -Filter 'Moonlight-*.log' -File|Where-Object {$_.CreationTimeUtc -ge $process.StartTime.ToUniversalTime().AddSeconds(-0.5)}|Sort-Object CreationTimeUtc)
        if($logs.Count){$logPath=$logs[0].FullName}
    }
    $log=if($logPath -and (Test-Path -LiteralPath $logPath)){Get-Content -LiteralPath $logPath -Raw}else{''}
    $evidence=Get-VmctlStreamEvidence -WindowTitle $process.MainWindowTitle -HostName $hosts[0].hostname -Log $log
    if($process.MainWindowHandle -ne 0 -and $evidence.ready){break}
    Start-Sleep -Milliseconds 250
} while((Get-Date) -lt $deadline)
if($process.MainWindowHandle -eq 0 -or -not $evidence.ready){throw "The matching Moonlight window is not receiving video yet; see $logPath"}
$record.logPath=$logPath;$record.windowTitle=$process.MainWindowTitle;$record.windowHandle=$process.MainWindowHandle.ToInt64()
$record.streamWindowOpen=$true;$record.videoDeliveryVerified=$true;$record.alreadyOpen=$alreadyOpen
$record|ConvertTo-Json|Set-Content -LiteralPath $activePath
$record|ConvertTo-Json
