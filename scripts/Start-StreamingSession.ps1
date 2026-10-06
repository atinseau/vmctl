#requires -Version 7.2
#requires -RunAsAdministrator
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_.-]*$')][string]$Vm,
    [Parameter(Mandatory)][string]$Config,
    [Parameter(Mandatory)][string]$ReportDirectory,
    [string]$UserName,[string]$CredentialFile,[switch]$Open
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Vmctl.psm1') -Force
$target=Get-VmctlTarget (Read-VmctlConfig $Config) $Vm
$directory=Join-Path (Get-VmctlDataRoot) ('work\setup-session-'+[guid]::NewGuid().ToString('N'))
$sessionRoot=Join-Path (Get-VmctlDataRoot) 'streaming-sessions'
$null=New-Item -ItemType Directory -Path $directory,$sessionRoot,$ReportDirectory -Force
$acl=Get-Acl -LiteralPath $directory
$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18')){
    $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $directory -AclObject $acl
$sessionPath=Join-Path $sessionRoot "$Vm.json"
$expires=[DateTimeOffset]::UtcNow.AddMinutes(30)
$ownsCredential=(-not $CredentialFile)
$session=@{vm=$Vm;vmName=$target.vmName;vmId=$(if($target.ContainsKey('vmId')){$target.vmId}else{''});pid=$PID;startTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;directory=$directory;expires=$expires.ToString('o');statusFile=(Join-Path $ReportDirectory 'streaming-status.json');state='starting'}
function Save-Session([string]$State){$session.state=$State;$json=$session|ConvertTo-Json;$json|Set-Content -LiteralPath $sessionPath -Encoding utf8;$json|Set-Content -LiteralPath (Join-Path $directory 'session.json') -Encoding utf8}
try {
    Save-Session 'awaitingCredentials'
    if($ownsCredential){
        if(-not $UserName){$UserName=if($target.ContainsKey('user')){$target.user}else{'vmctl-admin'}}
        $CredentialFile=Join-Path $directory 'guest-credential.clixml'
        $winps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $entry=Invoke-VmctlProcess $winps @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'Request-StreamingCredential.ps1'),'-UserName',$UserName,'-Destination',$CredentialFile) -TimeoutSeconds 900
        if($entry.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $CredentialFile)){throw 'VM credential entry failed or was cancelled.'}
    }
    do {
        Save-Session 'running'
        $arguments=@{Vm=$Vm;Config=$Config;ReportDirectory=$ReportDirectory;CredentialFile=$CredentialFile;Open=[bool]$Open}
        try {
            & (Join-Path $PSScriptRoot 'Install-StreamingStack.ps1') @arguments
            Save-Session 'completed'
            return
        } catch {
            Save-Session 'waiting-retry'
            Write-Warning ('Setup stopped; rerun vmctl streaming-install to reuse this session: '+$_.Exception.Message)
        }
        $retryPath=Join-Path $directory 'retry.json'
        while([DateTimeOffset]::UtcNow -lt $expires -and -not(Test-Path -LiteralPath $retryPath)){Start-Sleep -Milliseconds 500}
        if([DateTimeOffset]::UtcNow -ge $expires){throw 'Setup session expired after 30 minutes.'}
        $retry=Get-Content -LiteralPath $retryPath -Raw|ConvertFrom-Json
        $Open=[bool]$retry.open
        Remove-Item -LiteralPath $retryPath
    } while($true)
} catch {Save-Session 'failed';throw}
finally {
    if($ownsCredential -and $CredentialFile -and (Test-Path -LiteralPath $CredentialFile)){Remove-Item -LiteralPath $CredentialFile -Force}
}
