#requires -Version 7.2
[CmdletBinding()]
param([string]$ResultPath)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Installation unique : executer ce script depuis PowerShell 7 administrateur.'}
$sid=$identity.User.Value
$repo=Split-Path $PSScriptRoot -Parent
$state=Join-Path $env:ProgramData "vmctl\broker\$sid"
$taskName="vmctl-Broker-$sid"
function Set-ProtectedDirectory([string]$Path){
    $null=New-Item -ItemType Directory -Path $Path -Force
    if((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dossier installation lie refuse.'}
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($s in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($s),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}
if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $taskName;Start-Sleep -Seconds 2}
Set-ProtectedDirectory $state
# Enabling explicitly trusts this checkout and runtime to run elevated. No source copy.
$config=@{schemaVersion=1;userSid=$sid;repoRoot=$repo;runtime=(Join-Path $PSHOME 'pwsh.exe');transport='local-named-pipe';privilege='current-user-highest';installedAt=[DateTime]::UtcNow.ToString('o')}
$config|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $state 'configuration.json')
$action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File "'+(Join-Path $repo 'scripts\Start-AdminBroker.ps1')+'"')
$principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $sid
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$null=Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force
# Delegate only reading/running the installed task, not editing its privileged action.
$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
$task=$scheduler.GetFolder('\').GetTask($taskName)
$task.SetSecurityDescriptor("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGX;;;$sid)",0)
Start-ScheduledTask -TaskName $taskName
$result=[pscustomobject]@{installed=$true;task=$taskName;repoRoot=$repo;userSid=$sid;uacRequiredForVmOperations=$false}|ConvertTo-Json
if($ResultPath){$result|Set-Content -LiteralPath $ResultPath}
$result
