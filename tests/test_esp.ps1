#Requires -Version 5.1
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Reject([scriptblock]$Action,[string]$Message) {
    $failed=$false
    try { & $Action | Out-Null } catch { $failed=$true }
    Assert $failed $Message
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'lib/W2D.psm1'),[ref]$tokens,[ref]$errors)
Assert (!$errors) 'Module parse failure'
$function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-W2dEspVolume'},$true)
Assert ($null -ne $function) 'Mounted ESP helper missing'
. ([scriptblock]::Create($function.Extent.Text))
if (!('W2D.Firmware' -as [type])) { Add-Type -Path (Join-Path $root 'lib/Firmware.cs') }
foreach ($invalid in @($null,'','S:','S:\folder','s:\','\\server\share\','1:\')) {
    Reject { [W2D.Firmware]::VolumeName($invalid) } 'Invalid root must fail before native API access'
}
$script:volumePath='\\?\Volume{12345678-1234-1234-1234-123456789012}\'
$script:guid='98765432-1234-1234-1234-123456789012'
function Reset-Case {
    $script:partitions=@([pscustomobject]@{DiskNumber=0;Guid=$script:guid;GptType='{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}';DriveLetter=$null;AccessPaths=@($script:volumePath)})
    $script:volumes=@([pscustomobject]@{Path=$script:volumePath;SizeRemaining=66063360;DriveLetter=$null})
    $script:volumeReads=0
}
function Get-Partition {
    param([int]$DiskNumber,[string]$DriveLetter)
    Assert (!$DriveLetter) 'Must not query ESP by drive letter'
    return @($script:partitions | Where-Object { $_.DiskNumber -eq $DiskNumber })
}
function Get-Volume {
    param([string]$Path,[string]$DriveLetter)
    Assert (!$DriveLetter -and $Path -eq $script:volumePath) 'Must query the verified native volume path'
    $script:volumeReads++
    return $script:volumes
}
function Invoke-Check { Get-W2dEspVolume -VolumePath $script:volumePath -DiskNumber 0 -EspGuid $script:guid }
Reset-Case
$volume=Invoke-Check
Assert ($volume.SizeRemaining -eq 66063360 -and $null -eq $volume.DriveLetter) 'Letterless ESP must retain actual capacity'
Assert ($script:guid -ne $script:volumePath.Substring(11,36)) 'Fixture must not assume GPT and volume GUIDs are the same'
foreach ($kind in @('wrong-disk','wrong-guid','wrong-type','wrong-path','duplicate','missing')) {
    Reset-Case
    switch ($kind) {
        'wrong-disk' { $script:partitions[0].DiskNumber=1 }
        'wrong-guid' { $script:partitions[0].Guid='11111111-1111-1111-1111-111111111111' }
        'wrong-type' { $script:partitions[0].GptType='{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' }
        'wrong-path' { $script:partitions[0].AccessPaths=@('S:\') }
        'duplicate' { $script:partitions+= $script:partitions[0] }
        'missing' { $script:partitions=@() }
    }
    Reject { Invoke-Check } "$kind ESP must be rejected"
    Assert ($script:volumeReads -eq 0) 'Identity mismatch must stop before capacity query'
}
foreach ($kind in @('wrong-volume','duplicate-volume','missing-volume')) {
    Reset-Case
    switch ($kind) {
        'wrong-volume' { $script:volumes[0].Path='wrong' }
        'duplicate-volume' { $script:volumes+=$script:volumes[0] }
        'missing-volume' { $script:volumes=@() }
    }
    Reject { Invoke-Check } "$kind must be rejected"
}
Reset-Case
Reject { Get-W2dEspVolume -VolumePath 'S:\' -DiskNumber 0 -EspGuid $script:guid } 'Drive paths must not be substituted for native volume identity'
Write-Host 'ESP identity tests passed: letterless volume, disk/GPT/type/path checks, ambiguous/missing volumes and native input validation. No native mount or firmware operations executed.'
