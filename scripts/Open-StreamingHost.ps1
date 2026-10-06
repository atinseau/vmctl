#requires -Version 7.2
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$Vm,
    [Parameter(Mandatory)][string]$VmName,[string]$VmId,[switch]$Reconnect,
    [ValidateSet('Virtual Display','Desktop')][string]$Application='Virtual Display',
    [ValidateRange(10,480)][int]$Fps,
    [ValidateSet('windowed','fullscreen')][string]$Mode='windowed'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Vmctl.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../src/StreamingSupport.psm1') -Force
$launchLock=[Threading.Mutex]::new($false,('Local\vmctl-moonlight-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
$lockTaken=$false
try {
try {$lockTaken=$launchLock.WaitOne(0)}catch [Threading.AbandonedMutexException]{$lockTaken=$true}
if(-not $lockTaken){throw 'A vmctl streaming-open operation is already running; wait for its result before retrying.'}
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
$saved=if(Test-Path -LiteralPath $activePath){Get-Content -LiteralPath $activePath -Raw|ConvertFrom-Json}else{$null}
$previousApplication=if($saved -and $saved.PSObject.Properties.Name -contains 'application') {[string]$saved.application} else {'Virtual Display'}
$changingApplication=($saved -and $previousApplication -ne $Application)
if($changingApplication -and -not $Reconnect){throw 'Changing the streaming application requires -Reconnect.'}
$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Moonlight Game Streaming Project\Moonlight')
try {
    $fps=if($PSBoundParameters.ContainsKey('Fps')){$Fps}elseif($binding.PSObject.Properties.Name -contains 'fps'){[int]$binding.fps}else{[int]$key.GetValue('fps',60)}
    $width=[int]$key.GetValue('width',1920);$height=[int]$key.GetValue('height',1080)
    $absolute=[bool]$key.GetValue('mouseacceleration',0)
    $manualBitrate=if([string]$key.GetValue('autoadjustbitrate','true') -in @('false','0')){[int]$key.GetValue('bitrate',20000)}else{0}
} finally {$key.Dispose()}
$primary=if($Mode -eq 'fullscreen'){Get-VmctlPrimaryMonitor}else{$null}
$displayArgs=@{Mode=$Mode;SavedWidth=$width;SavedHeight=$height;SavedAbsoluteMouse=$absolute}
if($primary){$displayArgs.PrimaryWidth=$primary.width;$displayArgs.PrimaryHeight=$primary.height}
$display=New-VmctlStreamingDisplayPlan @displayArgs
$width=$display.width;$height=$display.height
$absolute=$display.absoluteMouse
if($fps -lt 10 -or $fps -gt 480 -or $width -lt 320 -or $width -gt 16384 -or $height -lt 240 -or $height -gt 16384){throw 'Saved streaming dimensions or frame rate are invalid.'}
# A CLI list/quit process is never a stream. Give outstanding helpers time to
# finish rather than adopting their PID or terminating them.
$helperDeadline=(Get-Date).AddSeconds(15)
do {
    $processes=@(Get-Process Moonlight -ErrorAction SilentlyContinue | Where-Object {-not $_.HasExited})
    $helpers=@($processes|Where-Object {
        $line=(Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine
        (Get-VmctlMoonlightProcessRole -CommandLine $line -ServerUuid $uuid) -eq 'helper'
    })
    if(-not $helpers.Count){break}
    if((Get-Date) -ge $helperDeadline){throw 'A Moonlight CLI helper is still running; wait for that command to finish before opening a stream.'}
    Start-Sleep -Milliseconds 250
}while($true)
$alreadyOpen=$false;$logPath=''
# A paused Apollo desktop survives even when the Moonlight process is gone.
$restartVirtualDisplay=($Reconnect -and $Application -eq 'Virtual Display' -and $previousApplication -eq 'Virtual Display' -and $saved -and $saved.serverUuid -ieq $uuid)
if($processes.Count) {
    if($processes.Count -ne 1){throw 'Multiple Moonlight processes require review.'}
    $process=$processes[0]
    $savedMatches=($saved -and $saved.serverUuid -ieq $uuid -and $saved.pid -eq $process.Id -and $saved.startTicks -eq $process.StartTime.ToUniversalTime().Ticks)
    $commandLine=(Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)").CommandLine
    $role=Get-VmctlMoonlightProcessRole -CommandLine $commandLine -ServerUuid $uuid
    if($role -ne 'stream'){throw 'The open Moonlight process is not a stream for this VM; close its window first.'}
    $previousMode=if($savedMatches -and $saved.PSObject.Properties.Name -contains 'mode'){[string]$saved.mode}else{'windowed'}
    if(-not $Reconnect -and ($previousMode -ne $Mode -or ($Mode -eq 'fullscreen' -and (-not $savedMatches -or $saved.resolution -ne $display.resolution)))){throw 'Changing the display mode or primary monitor resolution of an open stream requires -Reconnect.'}
    if(-not $Reconnect -and $Mode -eq 'fullscreen' -and ($saved.absoluteMouse -or $saved.PSObject.Properties.Name -notcontains 'captureSystemKeys' -or $saved.captureSystemKeys -ne 'always')){throw 'Updating fullscreen input capture requires -Reconnect.'}
    if($PSBoundParameters.ContainsKey('Fps') -and -not $Reconnect -and (-not $savedMatches -or [int]$saved.fps -ne $fps)){throw 'Changing the frame rate of an open stream requires -Reconnect.'}
    if($savedMatches -and -not $Reconnect){
        $fps=[int]$saved.fps
        # Report the running stream, even if global preferences changed meanwhile.
        $dimensions=[regex]::Match([string]$saved.resolution,'^(\d+)x(\d+)$')
        if(-not $dimensions.Success){throw 'Saved active streaming resolution is invalid; use -Reconnect.'}
        $width=[int]$dimensions.Groups[1].Value;$height=[int]$dimensions.Groups[2].Value
    }
    if($savedMatches){$logPath=[string]$saved.logPath}
    else {
        $legacy=@(Get-ChildItem -LiteralPath $reportDirectory -Filter '*.stderr.log' -File|Where-Object {$_.CreationTimeUtc -ge $process.StartTime.ToUniversalTime().AddSeconds(-1)}|Sort-Object CreationTimeUtc)
        if($legacy.Count){$logPath=$legacy[0].FullName}
    }
    $alreadyOpen=$true
    if($Reconnect -or $process.MainWindowTitle -eq 'Moonlight') {
        # Apollo's resume keeps the old virtual monitor dimensions. Recreate
        # our desktop application so the launch request configures the guest.
        $restartVirtualDisplay=($restartVirtualDisplay -or ($Application -eq 'Virtual Display' -and $previousApplication -eq 'Virtual Display' -and $savedMatches))
        $null=$process.CloseMainWindow()
        if(-not $process.WaitForExit(15000)){throw 'The matching Moonlight stream did not close cleanly.'}
        $process=$null;$alreadyOpen=$false;$logPath=''
    }
}
if(-not $alreadyOpen) {
    if($Application -eq 'Virtual Display'){
        $displayStatusArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'Get-StreamingStatus.ps1'),'-Vm',$Vm,'-VmName',$VmName,'-Diagnostics')
        if($VmId){$displayStatusArgs+=@('-VmId',$VmId)}
        $displayStatusResult=Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') $displayStatusArgs -TimeoutSeconds 45
        if($displayStatusResult.ExitCode -ne 0){throw "Cannot inspect automatic guest display configuration: $($displayStatusResult.Stderr)"}
        $settings=($displayStatusResult.Stdout|ConvertFrom-Json).diagnostics.videoSettings
        $expectedDisplay=if($settings.headless_mode -eq 'enabled' -and $settings.adapter_name -match '^NVIDIA '){'ensure_only_display'}else{'ensure_primary'}
        if($settings.dd_configuration_option -ne $expectedDisplay -or $settings.dd_resolution_option -ne 'auto' -or $settings.dd_refresh_rate_option -ne 'auto'){
            $fixArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'Get-StreamingStatus.ps1'),'-Vm',$Vm,'-VmName',$VmName,'-Mode','display-fix')
            if($VmId){$fixArgs+=@('-VmId',$VmId)}
            $fix=Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') $fixArgs -TimeoutSeconds 90
            if($fix.ExitCode -ne 0){throw "Cannot configure automatic guest resolution: $($fix.Stderr)"}
            # Apollo's restart already ends the old desktop streaming session.
            $restartVirtualDisplay=$false
        }
    }
    if($changingApplication -or $restartVirtualDisplay) {
        # These two desktop applications have no user game process to terminate.
        # End the paused virtual-display application before opening the console.
        $quit=Invoke-VmctlProcess $moonlight @('quit',$uuid) -TimeoutSeconds 30
        if($quit.ExitCode -ne 0){throw "Could not end the previous desktop stream: $($quit.Stderr)"}
        # Apollo restores the previous Windows topology asynchronously after
        # quitting. Do not let that restoration overwrite the next display.
        Start-Sleep -Milliseconds 3500
    }
    $list=Invoke-VmctlProcess $moonlight @('list',$uuid) -TimeoutSeconds 45
    if($list.ExitCode -ne 0 -or $list.Stdout -notmatch ('(?m)^\s*'+[regex]::Escape($Application)+'\s*\r?$')){throw "The paired application '$Application' is unavailable: $($list.Stderr)"}
    # ShellExecute detaches the GUI from redirected CLI pipes; Moonlight supplies
    # its own TEMP log. Inherited pipes can otherwise leave the caller stuck.
    $mouseOption=if($absolute){'--absolute-mouse'}else{'--no-absolute-mouse'}
    $displayOption=if($Mode -eq 'fullscreen'){'--capture-system-keys always'}else{''}
    $bitrateOption=if($manualBitrate -ge 500 -and $manualBitrate -le 500000){"--bitrate $manualBitrate"}else{''}
    # Apollo applies automatic resolution/refresh only when the client sends
    # the game-optimization flag, even for a virtual desktop application.
    $resolutionOption=if($Application -eq 'Virtual Display'){'--game-optimization'}else{''}
    # Let Moonlight use the user's codec and bitrate preferences, including AV1.
    $arguments="stream $uuid `"$Application`" --resolution ${width}x${height} --fps $fps $bitrateOption $mouseOption --display-mode $($display.displayMode) $displayOption $resolutionOption"
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
$record=@{vm=$Vm;serverUuid=$uuid;application=$Application;pid=$process.Id;startTicks=$process.StartTime.ToUniversalTime().Ticks;resolution="${width}x${height}";fps=$fps;absoluteMouse=$absolute;logPath=$logPath;mode=$Mode;displayMode=$display.displayMode}
$record.imageVerified=$false
$record.captureSystemKeys=$display.captureSystemKeys
if($Mode -eq 'fullscreen'){$record.releaseCaptureShortcut='Ctrl+Alt+Shift+Z'}
$record|ConvertTo-Json|Set-Content -LiteralPath $activePath
$deadline=(Get-Date).AddSeconds(30)
$receivingSince=$null
do {
    $process.Refresh()
    if(-not $logPath){
        $logs=@(Get-ChildItem -LiteralPath $env:TEMP -Filter 'Moonlight-*.log' -File|Where-Object {$_.CreationTimeUtc -ge $process.StartTime.ToUniversalTime().AddSeconds(-0.5)}|Sort-Object CreationTimeUtc)
        if($logs.Count){$logPath=$logs[0].FullName}
    }
    if($process.HasExited){
        $record.logPath=$logPath;$record.streamWindowOpen=$false;$record.videoDeliveryVerified=$false
        $record.streamState='exited';$record.exitCode=$process.ExitCode
        $record|ConvertTo-Json|Set-Content -LiteralPath $activePath
        $details=if($logPath){"see $logPath"}else{"no Moonlight log was created; diagnostic: $activePath"}
        throw "Moonlight exited while opening the stream (exit $($process.ExitCode)); $details"
    }
    $log=if($logPath -and (Test-Path -LiteralPath $logPath)){Get-Content -LiteralPath $logPath -Raw}else{''}
    $evidence=Get-VmctlStreamEvidence -WindowTitle $process.MainWindowTitle -HostName $hosts[0].hostname -Log $log
    if($evidence.disconnected){
        $record.logPath=$logPath;$record.streamWindowOpen=$false;$record.videoDeliveryVerified=$false
        $record.streamState='disconnected';$record.failure=$evidence.failure
        $record|ConvertTo-Json|Set-Content -LiteralPath $activePath
        throw "Moonlight disconnected during startup: $($evidence.failure); see $logPath"
    }
    if($process.MainWindowHandle -ne 0 -and $evidence.ready){
        if($null -eq $receivingSince){$receivingSince=Get-Date}
        # First packets preceded a disconnect by three seconds in the failing
        # login capture. Observe startup before reporting video reception.
        if(((Get-Date)-$receivingSince).TotalSeconds -ge 8){break}
    }else{$receivingSince=$null}
    Start-Sleep -Milliseconds 250
} while((Get-Date) -lt $deadline)
if($process.MainWindowHandle -eq 0 -or -not $evidence.ready -or $null -eq $receivingSince -or ((Get-Date)-$receivingSince).TotalSeconds -lt 8){throw "The matching Moonlight window is not receiving video yet; see $logPath"}
$record.logPath=$logPath;$record.windowTitle=$process.MainWindowTitle;$record.windowHandle=$process.MainWindowHandle.ToInt64()
if($Mode -eq 'fullscreen'){Set-VmctlStreamOnPrimaryMonitor -WindowHandle $process.MainWindowHandle}
$record.streamWindowOpen=$true;$record.videoDeliveryVerified=$true;$record.alreadyOpen=$alreadyOpen
$record.streamState='receiving';$record.startupObservationSeconds=8
if($Application -eq 'Virtual Display'){
    $statusArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'Get-StreamingStatus.ps1'),'-Vm',$Vm,'-VmName',$VmName,'-Diagnostics')
    if($VmId){$statusArgs+=@('-VmId',$VmId)}
    $statusResult=Invoke-VmctlProcess (Join-Path $PSHOME 'pwsh.exe') $statusArgs -TimeoutSeconds 45
    if($statusResult.ExitCode -ne 0){throw "Cannot verify the guest display resolution: $($statusResult.Stderr)"}
    $status=$statusResult.Stdout|ConvertFrom-Json
    $capture=Get-VmctlCapturedResolution -Lines $status.diagnostics.log -NotBefore $process.StartTime
    $record.guestResolution=$capture
    $record.guestResolutionVerified=($capture -eq "${width}x${height}")
    $record|ConvertTo-Json|Set-Content -LiteralPath $activePath
    if(-not $record.guestResolutionVerified){throw "Guest desktop capture is '$capture', expected '${width}x${height}'. The stream is scaled; the requested resolution is not verified."}
}
if($PSBoundParameters.ContainsKey('Fps')){
    # Store this VM's cadence after successful startup; other Moonlight hosts
    # and global preferences keep their existing settings.
    $binding|Add-Member -NotePropertyName fps -NotePropertyValue $fps -Force
    $binding|ConvertTo-Json|Set-Content -LiteralPath $bindingPath -Encoding utf8
}
$record|ConvertTo-Json|Set-Content -LiteralPath $activePath
$record|ConvertTo-Json
}finally{
    if($lockTaken){$launchLock.ReleaseMutex()}
    $launchLock.Dispose()
}
