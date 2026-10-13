#Requires -Version 5.1
# Run with powershell.exe/pwsh -NoProfile -File tests/test_boot_state.ps1.
# Executes source-derived production control flow with in-memory dependencies only.
# No production module/native Firmware type is loaded; all OS/file mutations are mocked.
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent

function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Read-SourceAst([string]$Path) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert (!$errors) "Parse failure: $Path : $errors"
    return $ast
}
function Find-Statement($Statements,[string]$Marker) {
    $indices=@(for ($i=0; $i -lt $Statements.Count; $i++) {
        if ($Statements[$i].Extent.Text.Contains($Marker)) { $i }
    })
    Assert ($indices.Count -eq 1) "Expected one source statement containing: $Marker"
    return $indices[0]
}
function New-SafeBlock([string]$Text,[switch]$Advanced) {
    # Change the dependency type, NOT the conditions/ordering being tested.
    $text=$Text.Replace('[W2D.Firmware]','[W2D.BootStateTestFirmware]')
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    Assert (!$errors) "Extracted source parse failure: $errors"
    # Fail closed if future source changes introduce an unmocked side effect.
    $commands=@('Where-Object','Out-Null','Write-Host','Write-Warning','shutdown.exe',
        'mountvol.exe','Get-Partition','Get-W2dFreeLetter','Get-FileHash','Join-Path',
        'Test-Path','Remove-Item','Get-ChildItem','ConvertTo-Json','Set-Content','Move-Item','Get-Date')
    foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true)) {
        Assert ($commands -contains $node.GetCommandName()) "Unmocked command in source: $($node.Extent.Text)"
    }
    $types=@('W2D.BootStateTestFirmware','BitConverter','Convert','guid','uint16')
    foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.TypeExpressionAst] -or $n -is [Management.Automation.Language.TypeConstraintAst]},$true)) {
        Assert ($types -contains $node.TypeName.FullName) "Unmocked type in source: $($node.Extent.Text)"
    }
    if ($Advanced) { $text="[CmdletBinding(SupportsShouldProcess=`$true,ConfirmImpact='Low')]param()`n"+$text }
    return [scriptblock]::Create($text)
}

$installAst=Read-SourceAst (Join-Path $root 'Install-Debian.ps1')
$restoreAst=Read-SourceAst (Join-Path $root 'Restore-WindowsBoot.ps1')
$installTries=@($installAst.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.TryStatementAst] -and $_.Body.Extent.Text.Contains("::WriteGlobal('BootNext'")
})
Assert ($installTries.Count -eq 1) 'Cannot uniquely locate production installation try/catch'
$installTry=$installTries[0]; $statements=$installTry.Body.Statements
$initial=Find-Statement $statements 'Firmware boot settings changed during preparation.'
$armStart=Find-Statement $statements 'Trial entry ID was occupied during preparation.'
$armEnd=Find-Statement $statements 'BootNext readback mismatch.'
Assert ($initial -lt $armStart -and $armStart -lt $armEnd) 'Installation source ordering changed'
$initialCheck=New-SafeBlock $statements[$initial].Extent.Text
$armBlock=New-SafeBlock (($statements[$armStart..$armEnd] | ForEach-Object { $_.Extent.Text }) -join "`n")
Assert ($installTry.CatchClauses.Count -eq 1) 'Unexpected installation catch structure'
# Use the entire real catch, including its final rethrow, with an injected failure.
$rollbackBlock=New-SafeBlock ("try { throw 'injected staging failure' } catch "+$installTry.CatchClauses[0].Body.Extent.Text)
$restoreStatements=$restoreAst.EndBlock.Statements
$restoreStart=Find-Statement $restoreStatements '[W2D.Firmware]::EnablePrivilege()'
# Includes initial checks, ShouldProcess, shutdown cancellation, and all cleanup/finally.
$restoreBlock=New-SafeBlock (($restoreStatements[$restoreStart..($restoreStatements.Count-1)] | ForEach-Object { $_.Extent.Text }) -join "`n") -Advanced

if (!('W2D.BootStateTestFirmware' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Security.Cryptography;
namespace W2D {
    public static class BootStateTestFirmware {
        public static Dictionary<string, byte[]> Vars = new Dictionary<string, byte[]>();
        public static Dictionary<string, int> Reads = new Dictionary<string, int>();
        public static List<string> Trace = new List<string>();
        class Drift { public string Observed, Changed; public int Number; public byte[] Value; }
        static List<Drift> drifts = new List<Drift>();
        public static void Reset() { Vars.Clear(); Reads.Clear(); Trace.Clear(); drifts.Clear(); }
        public static void AddDrift(string observed, int number, string changed, byte[] value) {
            drifts.Add(new Drift { Observed=observed, Number=number, Changed=changed, Value=value });
        }
        public static void EnablePrivilege() { Trace.Add("privilege:mock"); }
        public static byte[] ReadGlobal(string key) {
            int number = Reads.ContainsKey(key) ? Reads[key]+1 : 1; Reads[key]=number;
            Trace.Add("read:"+key);
            foreach (Drift d in drifts) {
                if (d.Observed==key && d.Number==number) {
                    if (d.Value==null) Vars.Remove(d.Changed); else Vars[d.Changed]=(byte[])d.Value.Clone();
                    Trace.Add("drift:"+d.Changed);
                }
            }
            return Vars.ContainsKey(key) ? (byte[])Vars[key].Clone() : null;
        }
        public static void WriteGlobal(string key, byte[] data) {
            Trace.Add("write:"+key); Vars[key]=(byte[])data.Clone();
        }
        public static void DeleteGlobal(string key) { Trace.Add("delete:"+key); Vars.Remove(key); }
        public static string Sha256(byte[] data) {
            using (SHA256 hash=SHA256.Create()) { return Convert.ToBase64String(hash.ComputeHash(data)); }
        }
    }
}
'@
}

# These functions shadow every native or mutating command admitted by New-SafeBlock.
# Join-Path is also mocked so synthetic S:\ paths need no real PSDrive on Linux.
function shutdown.exe {
    Assert ($args.Count -eq 1 -and $args[0] -eq '/a') 'Only mocked shutdown /a is permitted'
    [W2D.BootStateTestFirmware]::Trace.Add('shutdown:abort')
    $script:LASTEXITCODE=$script:shutdownExit
}
function mountvol.exe {
    Assert ($args.Count -eq 2 -and $args[0] -eq 'S:' -and $args[1] -in @('/S','/D')) 'Unexpected mountvol invocation'
    [W2D.BootStateTestFirmware]::Trace.Add('mount:'+ $args[1])
    $script:LASTEXITCODE=0
}
function Get-Partition {
    param($DiskNumber,$DriveLetter)
    [W2D.BootStateTestFirmware]::Trace.Add('partition')
    if (!$script:partitionMissing) { [pscustomobject]@{Guid=$script:state.EspGuid; DiskNumber=$script:state.DiskNumber} }
}
function Get-W2dFreeLetter { return 'S' }
function Join-Path { param([string]$Path,[string]$ChildPath) return $Path.TrimEnd('/','\')+'/'+$ChildPath }
function Test-Path { param([string]$LiteralPath) return $LiteralPath.EndsWith('EFI/w2d/shimx64.efi') }
function Get-FileHash {
    param([string]$LiteralPath,[string]$Algorithm)
    [W2D.BootStateTestFirmware]::Trace.Add('hash')
    if ($script:hashFailure) { throw 'injected hash failure' }
    if ($LiteralPath.EndsWith('bootmgfw.efi')) { return [pscustomobject]@{Hash=$script:state.WindowsBootHash} }
    return [pscustomobject]@{Hash='trial-file-hash'}
}
function Remove-Item { param([string]$LiteralPath,[switch]$Force) [W2D.BootStateTestFirmware]::Trace.Add('file:remove') }
function Get-ChildItem { param([string]$LiteralPath,[switch]$Force) return @() }
function Set-Content {
    param([Parameter(ValueFromPipeline=$true)]$Value,[string]$LiteralPath,[string]$Encoding)
    process { [W2D.BootStateTestFirmware]::Trace.Add('state:save') }
}
function Move-Item { param([string]$LiteralPath,[string]$Destination) [W2D.BootStateTestFirmware]::Trace.Add('work:archive') }
function Get-Date { param([string]$Format) return '20000101-000000' }
function Write-Host { param([Parameter(ValueFromRemainingArguments=$true)]$Object) }
function Write-Warning { param([string]$Message) [W2D.BootStateTestFirmware]::Trace.Add('warning') }

function Reset-Case {
    [W2D.BootStateTestFirmware]::Reset()
    $script:shutdownExit=0; $script:LASTEXITCODE=0; $script:hashFailure=$false; $script:partitionMissing=$false
    $script:bootName='Boot0070'; $script:bootId=112; $script:entry=[byte[]]@(1,2,3)
    $script:ownNext=[BitConverter]::GetBytes([uint16]112)
    $script:foreignNext=[BitConverter]::GetBytes([uint16]153)
    $script:foreignEntry=[byte[]]@(9,8,7)
    $script:beforeOrder=[byte[]]@(0,0); $script:armed=$true
    $script:state=[pscustomobject]@{
        Schema=1; Status='Armed'; BootId=$script:bootId; BootName=$script:bootName
        BootPayload=[Convert]::ToBase64String($script:entry); DiskNumber=0
        EspGuid='12345678-1234-1234-1234-123456789012'; WindowsBootHash='windows-file-hash'
        Files=@([pscustomobject]@{Path='EFI/w2d/shimx64.efi'; SHA256='trial-file-hash'})
    }
    $script:work='memory:/W2D'; $script:statePath='memory:/W2D/state.json'
    [W2D.BootStateTestFirmware]::Vars['BootOrder']=$script:beforeOrder
    [W2D.BootStateTestFirmware]::Vars[$script:bootName]=$script:entry
    [W2D.BootStateTestFirmware]::Vars['BootNext']=$script:ownNext
}
function Assert-Bytes([string]$Name,[byte[]]$Expected) {
    $actual=$null
    if ([W2D.BootStateTestFirmware]::Vars.ContainsKey($Name)) { $actual=[W2D.BootStateTestFirmware]::Vars[$Name] }
    if ($null -eq $Expected) { Assert ($null -eq $actual) "$Name should be absent"; return }
    Assert ($null -ne $actual) "$Name should exist"
    Assert ([Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($Expected)) "$Name bytes changed unexpectedly"
}
function Assert-NoTrace([string[]]$Events) {
    foreach ($event in $Events) { Assert (![W2D.BootStateTestFirmware]::Trace.Contains($event)) "Unexpected operation: $event" }
}
function Assert-Before([string]$First,[string]$Second) {
    $a=[W2D.BootStateTestFirmware]::Trace.IndexOf($First); $b=[W2D.BootStateTestFirmware]::Trace.IndexOf($Second)
    Assert ($a -ge 0 -and $b -gt $a) "Expected $First before $Second"
}
function Expect-Throw([scriptblock]$Action,[string]$Message) {
    $failure=$null
    try { & $Action | Out-Null } catch { $failure=$_ }
    Assert ($null -ne $failure) "Expected failure: $Message"
    Assert ($failure.Exception.Message.Contains($Message)) "Unexpected failure: $($failure.Exception.Message)"
}
$script:passed=0
function Case([string]$Name,[scriptblock]$Action) {
    Reset-Case
    try { & $Action; $script:passed++; Microsoft.PowerShell.Utility\Write-Host "PASS $Name" }
    catch { throw "FAIL $Name : $($_.Exception.Message)" }
}

Case 'install normal arm after two empty BootNext checks' {
    [W2D.BootStateTestFirmware]::Vars.Remove('BootNext') | Out-Null
    [W2D.BootStateTestFirmware]::Vars.Remove($bootName) | Out-Null
    $armed=$false
    . $initialCheck; . $armBlock
    Assert $armed 'Successful arm must set rollback flag'
    Assert-Bytes 'BootNext' $ownNext; Assert-Bytes $bootName $entry
    Assert ([W2D.BootStateTestFirmware]::Reads['BootNext'] -eq 3) 'Expect preflight, fresh check, then readback'
    Assert-Before 'write:Boot0070' 'write:BootNext'
}
Case 'install refuses BootNext appearing on second read' {
    [W2D.BootStateTestFirmware]::Vars.Remove('BootNext') | Out-Null
    [W2D.BootStateTestFirmware]::Vars.Remove($bootName) | Out-Null
    [W2D.BootStateTestFirmware]::AddDrift('BootNext',2,'BootNext',$foreignNext)
    . $initialCheck
    Expect-Throw { . $armBlock } 'Another one-time boot appeared before arming'
    Assert-Bytes 'BootNext' $foreignNext; Assert-NoTrace @('write:BootNext','delete:BootNext')
}
Case 'rollback removes matching own BootNext and rethrows failure' {
    Expect-Throw $rollbackBlock 'injected staging failure'
    Assert-Bytes 'BootNext' $null; Assert-Bytes $bootName $entry
    Assert-NoTrace @('delete:Boot0070')
}
Case 'rollback preserves BootNext when entry number is reused' {
    [W2D.BootStateTestFirmware]::Vars[$bootName]=$foreignEntry
    Expect-Throw $rollbackBlock 'injected staging failure'
    Assert-Bytes 'BootNext' $ownNext; Assert-Bytes $bootName $foreignEntry
    Assert-NoTrace @('delete:BootNext','delete:Boot0070')
}
Case 'rollback preserves another BootNext number' {
    [W2D.BootStateTestFirmware]::Vars['BootNext']=$foreignNext
    Expect-Throw $rollbackBlock 'injected staging failure'
    Assert-Bytes 'BootNext' $foreignNext; Assert-NoTrace @('delete:BootNext')
}
foreach ($length in @(1,3)) {
    Case "rollback preserves malformed BootNext length $length" {
        $bad=New-Object byte[] $length; $bad[0]=112
        [W2D.BootStateTestFirmware]::Vars['BootNext']=$bad
        Expect-Throw $rollbackBlock 'injected staging failure'
        Assert-Bytes 'BootNext' $bad; Assert-NoTrace @('delete:BootNext')
    }
}
Case 'rollback preserves BootNext if corresponding entry disappeared' {
    [W2D.BootStateTestFirmware]::Vars.Remove($bootName) | Out-Null
    Expect-Throw $rollbackBlock 'injected staging failure'
    Assert-Bytes 'BootNext' $ownNext; Assert-NoTrace @('delete:BootNext')
}
foreach ($code in @(0,1116)) {
    Case "restore normal path with shutdown exit $code" {
        $script:shutdownExit=$code
        & $restoreBlock -Confirm:$false
        Assert-Bytes 'BootNext' $null; Assert-Bytes $bootName $null
        Assert-Before 'shutdown:abort' 'delete:BootNext'
        Assert-Before 'delete:BootNext' 'partition'
        Assert-Before 'partition' 'mount:/S'
        Assert-Before 'mount:/S' 'hash'
        Assert-Before 'hash' 'delete:Boot0070'
        Assert-Before 'delete:Boot0070' 'file:remove'
        Assert-Before 'file:remove' 'work:archive'
        Assert-Before 'work:archive' 'mount:/D'
        Assert ($state.Status -eq 'Cancelled') 'Restore must mark state cancelled'
    }
}
Case 'restore cancellation failure stops before disarm and slow checks' {
    $script:shutdownExit=5
    Expect-Throw { & $restoreBlock -Confirm:$false } 'Could not cancel a scheduled restart'
    Assert-Bytes 'BootNext' $ownNext; Assert-Bytes $bootName $entry
    Assert-NoTrace @('delete:BootNext','delete:Boot0070','partition','mount:/S','hash','file:remove','work:archive')
}
Case 'restore preserves foreign BootNext appearing on second read' {
    [W2D.BootStateTestFirmware]::AddDrift('BootNext',2,'BootNext',$foreignNext)
    Expect-Throw { & $restoreBlock -Confirm:$false } 'Boot selection changed'
    Assert-Bytes 'BootNext' $foreignNext; Assert-Bytes $bootName $entry
    Assert-NoTrace @('delete:BootNext','delete:Boot0070','partition','mount:/S','hash')
}
Case 'restore preserves reused entry appearing on second read' {
    [W2D.BootStateTestFirmware]::AddDrift($bootName,2,$bootName,$foreignEntry)
    Expect-Throw { & $restoreBlock -Confirm:$false } 'Boot selection changed'
    Assert-Bytes 'BootNext' $ownNext; Assert-Bytes $bootName $foreignEntry
    Assert-NoTrace @('delete:BootNext','delete:Boot0070','partition','hash')
}
Case 'restore refuses disarm when entry disappears on second read' {
    [W2D.BootStateTestFirmware]::AddDrift($bootName,2,$bootName,$null)
    Expect-Throw { & $restoreBlock -Confirm:$false } 'Boot selection changed'
    Assert-Bytes 'BootNext' $ownNext; Assert-NoTrace @('delete:BootNext','partition','hash')
}
Case 'restore preserves new BootNext appearing during file checks' {
    [W2D.BootStateTestFirmware]::AddDrift('BootNext',3,'BootNext',$foreignNext)
    Expect-Throw { & $restoreBlock -Confirm:$false } 'A new BootNext appeared during cleanup'
    Assert-Bytes 'BootNext' $foreignNext; Assert-Bytes $bootName $entry
    Assert-Before 'hash' 'drift:BootNext'
    Assert-NoTrace @('delete:Boot0070','file:remove','state:save','work:archive')
    Assert ([W2D.BootStateTestFirmware]::Trace.Contains('mount:/D')) 'Failure must unmount mocked ESP'
}
Case 'restore preserves entry reused during file checks' {
    [W2D.BootStateTestFirmware]::AddDrift($bootName,3,$bootName,$foreignEntry)
    Expect-Throw { & $restoreBlock -Confirm:$false } 'Trial ID was reused during cleanup'
    Assert-Bytes 'BootNext' $null; Assert-Bytes $bootName $foreignEntry
    Assert-Before 'hash' 'drift:Boot0070'
    Assert-NoTrace @('delete:Boot0070','file:remove','state:save','work:archive')
}
Case 'restore has already cancelled and disarmed before hash failure' {
    $script:hashFailure=$true
    Expect-Throw { & $restoreBlock -Confirm:$false } 'injected hash failure'
    Assert-Bytes 'BootNext' $null; Assert-Bytes $bootName $entry
    Assert-Before 'shutdown:abort' 'delete:BootNext'; Assert-Before 'delete:BootNext' 'hash'
    Assert-NoTrace @('delete:Boot0070','file:remove','work:archive')
}
Case 'restore has already cancelled and disarmed before missing ESP failure' {
    $script:partitionMissing=$true
    Expect-Throw { & $restoreBlock -Confirm:$false } 'Original ESP no longer exists'
    Assert-Bytes 'BootNext' $null; Assert-Bytes $bootName $entry
    Assert-Before 'shutdown:abort' 'delete:BootNext'; Assert-Before 'delete:BootNext' 'partition'
    Assert-NoTrace @('mount:/S','hash','delete:Boot0070')
}
Case 'restore handles an already consumed BootNext' {
    [W2D.BootStateTestFirmware]::Vars.Remove('BootNext') | Out-Null
    & $restoreBlock -Confirm:$false
    Assert-Bytes 'BootNext' $null; Assert-Bytes $bootName $null
    Assert-NoTrace @('delete:BootNext')
    Assert-Before 'shutdown:abort' 'partition'
}
Case 'restore WhatIf performs no cancellation or cleanup' {
    & $restoreBlock -WhatIf
    Assert-Bytes 'BootNext' $ownNext; Assert-Bytes $bootName $entry
    Assert-NoTrace @('shutdown:abort','delete:BootNext','delete:Boot0070','partition','mount:/S','hash','file:remove','work:archive')
}
Microsoft.PowerShell.Utility\Write-Host "Boot state regression tests passed: $script:passed (source-derived; no native operations)."
