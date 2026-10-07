#requires -Version 7.2
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../src/Vmctl.psm1') -Force
$paths=Get-VmctlBrokerPaths
$config=Get-Content -LiteralPath $paths.Config -Raw|ConvertFrom-Json
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if($identity.User.Value -ne $config.userSid -or -not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Agent : compte eleve attendu.'}
# An explicit same-SID ACL permits the normal token to reach the elevated agent.
# CurrentUserOnly also compares elevation level on Windows, which would block this IPC.
$options=[IO.Pipes.PipeOptions]::Asynchronous
$security=[IO.Pipes.PipeSecurity]::new()
$security.SetAccessRuleProtection($true,$false)
$security.SetOwner($identity.User)
$security.AddAccessRule([IO.Pipes.PipeAccessRule]::new($identity.User,[IO.Pipes.PipeAccessRights]::ReadWrite,[Security.AccessControl.AccessControlType]::Allow))
while($true){
    if(Test-Path -LiteralPath $paths.Disabled){break}
    $pipe=[IO.Pipes.NamedPipeServerStreamAcl]::Create($paths.Pipe,[IO.Pipes.PipeDirection]::InOut,1,[IO.Pipes.PipeTransmissionMode]::Byte,$options,4096,4096,$security,[IO.HandleInheritability]::None,[IO.Pipes.PipeAccessRights]::ChangePermissions)
    try {
        # This file is writable only by Administrators/SYSTEM. Clients verify the pipe PID.
        @{pid=$PID;startedAt=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath $paths.Status
        $connection=$pipe.WaitForConnectionAsync()
        while(-not $connection.Wait(250)){if(Test-Path -LiteralPath $paths.Disabled){return}}
        $connection.GetAwaiter().GetResult()
        $writer=[IO.BinaryWriter]::new($pipe,[Text.UTF8Encoding]::new($false),$true)
        try {
            $json=Read-VmctlPipeMessage -Pipe $pipe
            try {
                # Reload the actual repository for every operation; no installed source snapshot.
                Import-Module (Join-Path $PSScriptRoot '../src/Vmctl.psm1') -Force
                if(Test-Path -LiteralPath $paths.Disabled){throw 'Mode privilegie desactive.'}
                $request=$json|ConvertFrom-Json -AsHashtable
                $result=Invoke-VmctlBrokerOperation $request
            }catch{$result=@{ExitCode=1;Stdout='';Stderr=$_.Exception.Message}}
            $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $result -Depth 12 -Compress))
            $writer.Write([int]$bytes.Length);$writer.Write($bytes);$writer.Flush()
            $request=$null;$json=$null
        } finally {$writer.Dispose()}
    }catch{
        # Keep listening after a disconnected/malformed client, without replaying its action.
    }finally{$pipe.Dispose()}
}
