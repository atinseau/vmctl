#requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/Vmctl.psm1') -Force
$passed = 0
function Assert-Direct([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "ECHEC : $Name" }
    $script:passed++
    Write-Output "OK : $Name"
}
$target = @{os='windows';hypervisor='hyperv';vmName='win-vm'}
Assert-Direct ((Get-VmctlTransport $target) -eq 'psdirect') 'Hyper-V Windows utilise Direct sans adresse reseau'
Assert-Direct ((Get-VmctlTarget @{targets=@{test=$target}} test).vmName -eq 'win-vm') 'Configuration Direct sans host acceptee'
Assert-Direct ((Get-VmctlTransport @{os='linux';hypervisor='hyperv'}) -eq 'ssh') 'Linux conserve SSH'
Assert-Direct ((Get-VmctlTransport @{os='windows';hypervisor='none'}) -eq 'ssh') 'Windows hors Hyper-V conserve SSH'
Assert-Direct ((Get-VmctlTransport @{os='windows';hypervisor='hyperv';transport='ssh'}) -eq 'ssh') 'SSH explicite conserve'
try { $null = Get-VmctlTarget @{targets=@{test=@{os='linux';hypervisor='hyperv';vmName='test';transport='psdirect'}}} test; throw 'Accepted' }
catch { Assert-Direct ($_.Exception.Message -match 'psdirect exige') 'Direct Linux refuse' }
$scratch = Join-Path $root ('work/direct-tests-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$runtime = Join-Path $PSHOME 'pwsh.exe'
$config = Join-Path $scratch 'targets.json'
$result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',(Join-Path $root 'vmctl.ps1'),'register','-Vm','test','-Os','windows','-Hypervisor','hyperv','-Config',$config)
Assert-Direct ($result.ExitCode -eq 0) 'register Hyper-V sans adresse SSH'
$result = Invoke-VmctlProcess $runtime @('-NoProfile','-File',(Join-Path $root 'bin/vmctl.ps1'),'list','-Config',$config)
Assert-Direct ($result.ExitCode -eq 0 -and $result.Stdout -match 'psdirect') 'Lanceur global et list affichent Direct'
$plans = & (Get-Module Vmctl) {
    param($directTarget,$source)
    $original = (Get-Command Invoke-VmctlDirect).ScriptBlock
    function Invoke-VmctlDirect {
        param($Target,$Request,$Credential,$CredentialFile,$TimeoutSeconds)
        return $Request
    }
    try {
        Invoke-VmctlCommand $directTarget 'Write-Output "direct"' -CredentialFile 'fixture.clixml'
        Invoke-VmctlUpload $directTarget $source 'C:/Temp/file.txt' -CredentialFile 'fixture.clixml'
    } finally { Set-Item Function:Invoke-VmctlDirect $original }
} $target $config
Assert-Direct ($plans[0].action -eq 'exec' -and $plans[0].script -eq 'Write-Output "direct"') 'exec est route vers Direct, sans SSH'
Assert-Direct ($plans[1].action -eq 'upload' -and $plans[1].source -eq $config) 'upload est route vers Direct, sans SCP'
# Execute the actual guest-side child-process script locally, without claiming guest access.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scripts/Invoke-PowerShellDirect.ps1'),[ref]$tokens,[ref]$errors)
if ($errors) { throw 'Worker Direct invalide' }
$vmAssignment = $ast.Find({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$vm'},$true)
$lookup = [scriptblock]::Create($vmAssignment.Extent.Text)
$count = & {
    param($lookup)
    function Get-VM { param($Id,$Name) [pscustomobject]@{Name='win-vm';Id=[Guid]::NewGuid();State='Running'} }
    $request = @{vmId=[Guid]::NewGuid().ToString();vmName='win-vm'}
    . $lookup
    $vm.Count
} $lookup
Assert-Direct ($count -eq 1) 'Une seule VM reste un tableau sous StrictMode'
$invoke = $ast.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Command'},$true)
$guest = $invoke.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] } | Select-Object -First 1
$guestScript = [scriptblock]::Create($guest.ScriptBlock.Extent.Text.Trim().Substring(1).TrimEnd().TrimEnd('}'))
function Invoke-GuestFixture($Plan, [string]$Code) {
    $body = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guestScript.ToString()))
    $wrapper = @'
$ErrorActionPreference='Stop'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
try {
    $request=[Console]::In.ReadToEnd() | ConvertFrom-Json
    $guest=[scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__BODY__')))
    & $guest $request.shell $request.runner $request.code $request.asFile | ConvertTo-Json -Compress
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper.Replace('__BODY__',$body)))
    $request = @{shell=$Plan.Shell;runner=$Plan.EncodedCommand;code=$Code;asFile=$Plan.AsFile} | ConvertTo-Json -Compress
    $local = Invoke-VmctlProcess powershell.exe @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -InputText $request
    if ($local.ExitCode -ne 0) { throw $local.Stderr }
    return $local.Stdout | ConvertFrom-Json
}
foreach ($case in @(
    @{code='Write-Output ''élève "quotes" $literal & |''';exit=0;output='élève "quotes" $literal & |'},
    @{code='exit 23';exit=23;output=''},
    @{code='cmd.exe /c exit 7';exit=7;output=''},
    @{code='throw "direct-test-error"';exit=1;error='direct-test-error'}
)) {
    $plan = New-VmctlWindowsExecution $target $case.code
    $result = Invoke-GuestFixture $plan $case.code
    Assert-Direct ($result.ExitCode -eq $case.exit) "Processus invite conserve le code $($case.exit)"
    if ($case.ContainsKey('output')) { Assert-Direct ($result.Stdout.TrimEnd() -eq $case.output) 'stdout intact' }
    if ($case.ContainsKey('error')) { Assert-Direct ($result.Stderr -match $case.error) 'stderr intact' }
}
$code = 'Write-Output $PSCommandPath'
$plan = New-VmctlWindowsExecution $target $code -AsFile
$result = Invoke-GuestFixture $plan $code
Assert-Direct ($result.ExitCode -eq 0 -and $result.Stdout -match 'vmctl-.*\.ps1') 'run Direct utilise un fichier temporaire'
Assert-Direct (-not (Test-Path -LiteralPath $result.Stdout.Trim())) 'run Direct nettoie son fichier'
# Verify Windows PowerShell 5.1 can decrypt a PS7 DPAPI credential, without printing a secret.
$password = ConvertTo-SecureString 'vmctl-fixture-only' -AsPlainText -Force
$encrypted = ConvertFrom-SecureString $password
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('$ErrorActionPreference="Stop"; $env:PSModulePath=Join-Path $PSHOME "Modules"; $secret=ConvertTo-SecureString ([Console]::In.ReadToEnd()); if ((New-Object Management.Automation.PSCredential("fixture",$secret)).GetNetworkCredential().Password -eq "vmctl-fixture-only") {exit 0}; exit 1'))
$result = Invoke-VmctlProcess powershell.exe @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -InputText $encrypted
Assert-Direct ($result.ExitCode -eq 0) 'DPAPI compatible PS7 vers Windows PowerShell 5.1'
Write-Output "$passed verifications locales Direct reussies. Aucun acces a une VM."
