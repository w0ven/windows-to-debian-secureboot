#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/W2D.psm1') -Force
if (!('W2D.Sha512Crypt' -as [type])) { Add-Type -Path (Join-Path $root 'lib/Sha512Crypt.cs') }
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Reject([scriptblock]$Action,[string]$Message) {
    $failure=$null
    try { & $Action | Out-Null } catch { $failure=$_ }
    Assert ($null -ne $failure) "Expected failure: $Message"
    Assert ($failure.Exception.Message.Contains($Message)) "Unexpected failure: $($failure.Exception.Message)"
}
function Read-Ast([string]$Path) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert (!$errors) "Parse failure: $Path : $errors"
    return $ast
}
function Find-Statement($Statements,[string]$Marker) {
    $found=@(for ($i=0; $i -lt $Statements.Count; $i++) { if ($Statements[$i].Extent.Text.Contains($Marker)) { $i } })
    Assert ($found.Count -eq 1) "Cannot uniquely locate: $Marker"
    return $found[0]
}
$install=Read-Ast (Join-Path $root 'Install-Debian.ps1')
$module=Read-Ast (Join-Path $root 'lib/W2D.psm1')
$defaultsIndex=Find-Statement $install.EndBlock.Statements '-Quick cannot be combined'
$defaults=[scriptblock]::Create($install.ParamBlock.Extent.Text+"`n"+$install.EndBlock.Statements[$defaultsIndex].Extent.Text+'; [pscustomobject]@{Mode=$Mode; Dns=$DnsServers; Port=$SshPort}')
Assert ((& $defaults).Mode -eq 'Check') 'Existing default mode changed'
Assert ((& $defaults -Quick).Mode -eq 'AutoInstall') 'Quick must select automatic installation'
Assert ((& $defaults -Quick -Mode AutoInstall).Mode -eq 'AutoInstall') 'Explicit automatic mode rejected'
Assert ((& $defaults -Quick -DnsServers 192.0.2.53 -SshPort 2222).Dns[0] -eq '192.0.2.53') 'Explicit DNS lost'
Assert ((& $defaults -Quick -SshPort 2222).Port -eq 2222) 'Explicit SSH port lost'
Reject { & $defaults -Quick -Mode Test } '-Quick cannot be combined'
Reject { & $defaults -Quick -Mode Check } '-Quick cannot be combined'

$seen=@{}
foreach ($i in 1..32) {
    $password=New-W2dRandomPassword
    Assert ($password -cmatch '^[A-Za-z0-9+/]{24}$') 'Generated password must be 24 printable ASCII characters'
    Assert ([Convert]::FromBase64String($password).Length -eq 18) 'Expected 144 bits of random password material'
    Assert (!$seen.ContainsKey($password)) 'Duplicate generated password'
    $seen[$password]=$true
}
$password=$null; $seen=$null

# Replace console state only; exercise the real prompt and rejection logic without a live terminal.
$confirm=$module.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Confirm-W2dQuickInstall'},$true)
Assert ($null -ne $confirm) 'Quick confirmation function missing'
. ([scriptblock]::Create($confirm.Extent.Text.Replace('[Console]::IsInputRedirected','$script:redirected').Replace('[Environment]::UserInteractive','$script:interactive')))
$statements=$install.EndBlock.Statements
$start=Find-Statement $statements 'Choose only one recovery declaration.'
$end=Find-Statement $statements 'Protect-W2dDirectory $work'
$source=($statements[$start..($end-1)] | ForEach-Object { $_.Extent.Text }) -join "`n"
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
Assert (!$errors) 'Extracted preparation source must parse'
$allowed=@('Join-Path','Test-Path','Write-Host','Write-Warning','Read-Host','New-W2dRandomPassword','Confirm-W2dQuickInstall','Add-Type')
foreach ($command in $ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)) {
    Assert ($allowed -contains $command.GetCommandName()) "Unexpected command before staging: $($command.GetCommandName())"
}
Assert (!$source.Contains('[W2D.Firmware]')) 'No firmware dependency permitted in prompt tests'
$prepare=[scriptblock]::Create('[CmdletBinding(SupportsShouldProcess=$true)]param()'+"`n"+$source+'; $script:staged=$true; [pscustomobject]@{Hash=$passwordHash; Cleared=($null -eq $generated)}')
& {
    $bootstrap=Read-Ast (Join-Path $root 'quick.ps1')
    $body=$bootstrap.Find({param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst]},$true).ScriptBlock.EndBlock.Statements
    $first=Find-Statement $body 'An earlier installation attempt exists'
    $run=[scriptblock]::Create(($body[$first..($body.Count-1)] | ForEach-Object { $_.Extent.Text }) -join "`n")
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('w2d-bootstrap-test-'+[guid]::NewGuid().ToString('N'))
    $oldTemp=$env:TEMP; $oldProgramData=$env:ProgramData; $oldTls=[Net.ServicePointManager]::SecurityProtocol
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $fixture=Join-Path $temp 'windows-to-debian-secureboot-main'
        New-Item -ItemType Directory -Path $fixture | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture 'Install-Debian.ps1') -Encoding UTF8 -Value 'param([switch]$Quick) if (!$Quick) { throw "Quick switch missing" }; $global:W2dQuickBootstrapTestCalls++'
        $archive=Join-Path $temp 'fixture.zip'
        Compress-Archive -LiteralPath $fixture -DestinationPath $archive
        $env:TEMP=$temp; $env:ProgramData=$temp
        $global:W2dQuickBootstrapTestCalls=0
        $downloadFails=$false
        function Invoke-WebRequest {
            param([switch]$UseBasicParsing,[string]$Uri,[string]$OutFile,[int]$TimeoutSec)
            Assert ($Uri -ceq 'https://github.com/w0ven/windows-to-debian-secureboot/archive/refs/heads/main.zip') 'Unexpected repository URL'
            if ($downloadFails) { throw 'synthetic download failure' }
            Copy-Item -LiteralPath $archive -Destination $OutFile
        }
        function Set-ExecutionPolicy {
            param([string]$Scope,[string]$ExecutionPolicy,[switch]$Force)
            Assert ($Scope -eq 'Process' -and $ExecutionPolicy -eq 'Bypass' -and $Force) 'Execution policy must be process-only'
        }
        & $run
        Assert ($global:W2dQuickBootstrapTestCalls -eq 1) 'Archive entry must receive Quick exactly once'
        $downloadFails=$true
        Reject { & $run } 'synthetic download failure'
        Assert ($global:W2dQuickBootstrapTestCalls -eq 1) 'Download failure must not invoke installation'
        New-Item -ItemType Directory -Path (Join-Path $temp 'W2D') | Out-Null
        Reject { & $run } 'An earlier installation attempt exists'
        Assert ($global:W2dQuickBootstrapTestCalls -eq 1) 'Existing staging must not invoke installation'
    } finally {
        $env:TEMP=$oldTemp; $env:ProgramData=$oldProgramData; [Net.ServicePointManager]::SecurityProtocol=$oldTls
        Remove-Item -LiteralPath $temp -Recurse -Force
        Remove-Variable -Name W2dQuickBootstrapTestCalls -Scope Global -ErrorAction SilentlyContinue
    }
}
function Join-Path { param($Path,$ChildPath) return "$Path/$ChildPath" }
function Test-Path { param($LiteralPath) return $script:existing }
function Write-Host {
    param([Parameter(Position=0)]$Object,[string]$ForegroundColor)
    $line=$Object -join ' '
    if ($line.StartsWith('NEW ROOT PASSWORD: ')) { $script:shownPassword=$line.Substring(19) }
    $script:messages.Add($line)
}
function Write-Warning { param([string]$Message) $script:messages.Add($Message) }
function Read-Host {
    param([string]$Prompt,[switch]$AsSecureString)
    $script:messages.Add($Prompt); $script:prompts++
    Assert ($script:answers.Count -gt 0) 'Unexpected extra prompt'
    $answer=$script:answers.Dequeue()
    if ($AsSecureString) { return ConvertTo-SecureString $answer -AsPlainText -Force }
    return $answer
}
function Reset-Case {
    $script:redirected=$false; $script:interactive=$true; $script:existing=$false; $script:staged=$false
    $script:Quick=$true; $script:Mode='AutoInstall'; $script:NoReboot=$false
    $script:RecoveryAvailable=$false; $script:AcceptNoRecovery=$false; $script:SshPort=2222
    $script:plan=[pscustomobject]@{DiskNumber=7; DiskBytes=32GB; IPAddress='192.0.2.100'}
    $script:generated=$null; $script:shownPassword=$null; $script:prompts=0
    $script:answers=New-Object 'System.Collections.Generic.Queue[object]'
    $script:messages=New-Object 'System.Collections.Generic.List[string]'
}
Reset-Case
$answers.Enqueue('')
$result=& $prepare
Assert ($staged -and $prompts -eq 1) 'Quick must proceed after exactly one confirmation'
Assert ($shownPassword.Length -eq 24 -and $result.Cleared) 'Password must be shown then cleared from preparation variable'
Assert ($result.Hash -cmatch '^\$6\$') 'Quick must produce SHA-512 crypt, not plaintext'
Assert ([W2D.Sha512Crypt]::Hash($shownPassword,$result.Hash.Split('$')[2]) -ceq $result.Hash) 'Displayed password must match installer hash'
$text=$messages -join "`n"
Assert ($text.Contains('system disk 7') -and $text.Contains('ssh -p 2222 root@192.0.2.100')) 'Confirmation must identify actual disk and SSH endpoint'
Assert ($text.Contains('inaccessible') -and $text.Contains('ALL partitions and data')) 'Risk and destructive effect must be explicit'
Assert ($text.Contains('password saved') -and $text.Contains('loss-of-access risk accepted')) 'Enter must authorize the complete operation'
foreach ($answer in @('q','no','yes',' ',$null)) {
    Reset-Case; $answers.Enqueue($answer)
    Reject { & $prepare } 'Cancelled; nothing staged.'
    Assert (!$staged -and $prompts -eq 1) 'Cancellation or EOF must not reach staging'
}
foreach ($kind in @('redirected','noninteractive','existing','WhatIf','conflicting-recovery')) {
    Reset-Case
    switch ($kind) {
        'redirected' { $script:redirected=$true; Reject { & $prepare } 'interactive console' }
        'noninteractive' { $script:interactive=$false; Reject { & $prepare } 'interactive console' }
        'existing' { $script:existing=$true; Reject { & $prepare } 'Staging already exists' }
        'WhatIf' { & $prepare -WhatIf }
        'conflicting-recovery' { $script:RecoveryAvailable=$true; $script:AcceptNoRecovery=$true; Reject { & $prepare } 'Choose only one' }
    }
    Assert (!$staged -and $prompts -eq 0 -and $null -eq $shownPassword) "$kind must neither prompt nor reach staging"
}
Reset-Case; $script:NoReboot=$true; $answers.Enqueue(''); $result=& $prepare
Assert (($messages -join "`n").Contains('NEXT reboot')) 'NoReboot must warn that a future reboot still installs'
Reset-Case; $script:Quick=$false
Reject { & $prepare } 'Confirm provider console'
Assert (!$staged -and $prompts -eq 0) 'Legacy mode must still require recovery declaration'
foreach ($mode in @('Test','AutoInstall')) {
    Reset-Case; $script:Quick=$false; $script:Mode=$mode; $script:RecoveryAvailable=$true
    $answers.Enqueue($(if ($mode -eq 'Test') { 'TEST-BOOT DISK 7' } else { 'AUTO-WIPE DISK 7' }))
    $answers.Enqueue('synthetic-test-password'); $answers.Enqueue('synthetic-test-password')
    $result=& $prepare
    Assert ($staged -and $prompts -eq 3 -and $result.Hash -cmatch '^\$6\$') 'Legacy phrase and repeated password flow changed'
}
Microsoft.PowerShell.Utility\Write-Host 'Quick-entry tests passed: one confirmation, password/hash match, cancellation, console guards, WhatIf, NoReboot, unchanged legacy modes and archive bootstrap. No firmware, disk or reboot operations executed.'
