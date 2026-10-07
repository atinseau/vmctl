#requires -Version 5.1
#requires -RunAsAdministrator
param([ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,14}$')][string]$CloneName='win-vm-2',[string]$SourceName='win-vm-1')
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -ine $SourceName){throw 'Clone initialization requires the original Windows source name.'}
$root=Join-Path $env:ProgramFiles 'Apollo\config'
$backup=Join-Path $root ('before-clone-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $backup
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @('S-1-5-18','S-1-5-32-544')){
    $identity=New-Object Security.Principal.SecurityIdentifier($sid)
    $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $backup -AclObject $acl
$service=Get-Service ApolloService
Stop-Service ApolloService -Force
$service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))
$confPath=Join-Path $root 'sunshine.conf'
Copy-Item -LiteralPath $confPath -Destination (Join-Path $backup 'sunshine.conf')
foreach($item in @('sunshine_state.json','credentials')){
    $path=Join-Path $root $item
    if(Test-Path -LiteralPath $path){Move-Item -LiteralPath $path -Destination (Join-Path $backup $item)}
}
$conf=[IO.File]::ReadAllText($confPath)
if($conf -match '(?m)^\s*sunshine_name\s*='){$conf=[regex]::Replace($conf,'(?m)^\s*sunshine_name\s*=.*$',('sunshine_name = '+$CloneName))}
else{$conf+="`r`nsunshine_name = $CloneName`r`n"}
[IO.File]::WriteAllText($confPath,$conf,(New-Object Text.UTF8Encoding($false)))
Rename-Computer -NewName $CloneName -Force
@{cloneName=$CloneName;apolloIdentityReset=$true;restrictedBackup=$backup;restartRequired=$true;profile=(Get-CimInstance Win32_UserProfile|Where-Object LocalPath -eq 'C:\Users\admin'|Select-Object LocalPath,SID)}|ConvertTo-Json -Depth 3
