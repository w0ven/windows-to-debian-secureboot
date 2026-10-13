$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/W2D.psm1') -Force
if (!('W2D.Firmware' -as [type])) { Add-Type -Path (Join-Path $root 'lib/Firmware.cs') }
function Assert($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Reject([scriptblock]$Action,[string]$Message) { $failed=$false; try { & $Action | Out-Null } catch { $failed=$true }; Assert $failed $Message }
foreach ($file in Get-ChildItem $root -Recurse -Include *.ps1,*.psm1) {
    $tokens=$null; $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
    Assert (!$errors) "PowerShell parse failure: $($file.FullName): $errors"
}
Assert ((ConvertTo-W2dNetmask 24) -eq '255.255.255.0') 'IPv4 /24 mask'
Assert ((ConvertTo-W2dNetmask 30) -eq '255.255.255.252') 'IPv4 /30 mask'
Assert ((ConvertTo-W2dIPv4 '192.0.2.100') -eq 3221226084L) 'IPv4 integer'
Assert-W2dNetwork '192.0.2.100' 24 '192.0.2.1' @('1.1.1.1','8.8.8.8')
Reject { Assert-W2dNetwork '192.0.2.100' 32 '192.0.2.1' @('1.1.1.1') } '/32 must fail'
Reject { Assert-W2dNetwork '192.0.2.100' 24 '198.51.100.1' @('1.1.1.1') } 'Off-link gateway must fail'
Reject { Assert-W2dNetwork '192.0.2.0' 24 '192.0.2.1' @('1.1.1.1') } 'Network address must fail'
Reject { Assert-W2dNetwork '192.0.2.255' 24 '192.0.2.1' @('1.1.1.1') } 'Broadcast address must fail'
Reject { Assert-W2dNetwork '192.0.2.100' 24 '192.0.2.1' @('127.0.0.53') } 'Stub DNS must fail'
Reject { ConvertTo-W2dIPv4 '999.0.0.1' } 'Invalid IPv4 must fail'
Reject { ConvertTo-W2dIPv4 '192.0.02.1' } 'Ambiguous leading-zero octet must fail before Linux startup'
Reject { ConvertTo-W2dShellValue "test`nMODE=auto" } 'Shell newline injection must fail'
Reject { ConvertTo-W2dShellValue "a'b" } 'Shell quoting injection must fail'
Assert ((ConvertTo-W2dShellValue '192.0.2.1') -ceq "'192.0.2.1'") 'Shell quoting'
$guid=[guid]'12345678-1234-1234-1234-123456789012'
$option=[W2D.Firmware]::BootOption($guid,1,2048,204800,'\EFI\w2d\shimx64.efi')
Assert ([BitConverter]::ToUInt32($option,0) -eq 1) 'Active boot option'
$description=[Text.Encoding]::Unicode.GetBytes("W2D Debian 13 trial`0")
$start=6+$description.Length
Assert ([BitConverter]::ToUInt32($option,$start+4) -eq 1) 'GPT partition number'
Assert ([BitConverter]::ToUInt64($option,$start+8) -eq 2048) 'GPT start LBA'
Assert ([BitConverter]::ToUInt64($option,$start+16) -eq 204800) 'GPT size LBA'
$gbytes=New-Object byte[] 16; [Array]::Copy($option,$start+24,$gbytes,0,16)
Assert ((New-Object Guid(,$gbytes)) -eq $guid) 'GPT GUID byte order'
Assert ([BitConverter]::ToUInt16($option,4) -eq ($option.Length-$start)) 'EFI device path length'
Reject { [W2D.Firmware]::BootOption($guid,1,2048,0,'\EFI\w2d\shimx64.efi') } 'Empty ESP must fail'
Reject { [W2D.Firmware]::SignatureEntries([byte[]]@(1,2,3),$false) } 'Truncated EFI signature list must fail'
$ms=New-Object IO.MemoryStream; $bw=New-Object IO.BinaryWriter($ms)
$bw.Write(([guid]'a159c0a5-e494-4aa7-87b5-ab155c2bf072').ToByteArray());$bw.Write([uint32]47);$bw.Write([uint32]0);$bw.Write([uint32]19);$bw.Write($guid.ToByteArray());$bw.Write([byte[]]@(1,2,3));$bw.Flush()
$esl=$ms.ToArray();$bw.Dispose();$ms.Dispose()
$certs=[W2D.Firmware]::SignatureEntries($esl,$true)
Assert ($certs.Length -eq 1 -and $certs[0] -eq [W2D.Firmware]::Sha256([byte[]]@(1,2,3))) 'EFI certificate extraction'
$bad=$esl.Clone();[Array]::Copy([BitConverter]::GetBytes([uint32]0),0,$bad,16,4)
Reject { [W2D.Firmware]::SignatureEntries($bad,$false) } 'Zero-size EFI list must fail without looping'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('w2d-test-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $temp | Out-Null
try {
    $cpio=Join-Path $temp 'overlay.cpio';$joined=Join-Path $temp 'joined.gz';$original=Join-Path $temp 'original'
    $entry=[pscustomobject]@{Name='w2d/config.sh';Mode=33152;Data=[Text.Encoding]::UTF8.GetBytes("MODE='test'`n")}
    Write-W2dCpio @($entry) $cpio
    $bytes=[IO.File]::ReadAllBytes($cpio);$offset=0;$found=$false
    while ($offset -lt $bytes.Length) {
        Assert ([Text.Encoding]::ASCII.GetString($bytes,$offset,6) -eq '070701') 'CPIO magic'
        $header=[Text.Encoding]::ASCII.GetString($bytes,$offset,110)
        $mode=[Convert]::ToUInt32($header.Substring(14,8),16);$size=[Convert]::ToInt32($header.Substring(54,8),16);$namesize=[Convert]::ToInt32($header.Substring(94,8),16)
        $name=[Text.Encoding]::UTF8.GetString($bytes,$offset+110,$namesize-1)
        $dataStart=[int]([math]::Ceiling(($offset+110+$namesize)/4.0)*4)
        if ($name -eq 'w2d/config.sh') { Assert ($mode -eq 33152) 'Config must be root-only'; Assert ([Text.Encoding]::UTF8.GetString($bytes,$dataStart,$size) -ceq "MODE='test'`n") 'CPIO payload';$found=$true }
        if ($name -eq 'TRAILER!!!') { break }
        $offset=[int]([math]::Ceiling(($dataStart+$size)/4.0)*4)
    }
    Assert $found 'CPIO config not found'
    [IO.File]::WriteAllBytes($original,[byte[]]@(10,20,30))
    Join-W2dInitrd $original $cpio $joined
    $joinedBytes=[IO.File]::ReadAllBytes($joined);Assert ($joinedBytes[0] -eq 10 -and $joinedBytes[3] -eq 31 -and $joinedBytes[4] -eq 139) 'Original prefix plus gzip overlay'
    $input=New-Object IO.MemoryStream(,$joinedBytes);$input.Position=3
    $gz=New-Object IO.Compression.GZipStream($input,[IO.Compression.CompressionMode]::Decompress);$output=New-Object IO.MemoryStream
    $gz.CopyTo($output);Assert ([W2D.Firmware]::Sha256($output.ToArray()) -eq [W2D.Firmware]::Sha256($bytes)) 'Overlay gzip round trip';$gz.Dispose();$input.Dispose();$output.Dispose()
    Reject { Join-W2dInitrd $original $cpio $joined } 'Existing initrd must not be overwritten blindly'
    Reject { Write-W2dCpio @([pscustomobject]@{Name='../escape';Mode=33152;Data=[byte[]]@(1)}) (Join-Path $temp 'bad') } 'CPIO traversal must fail'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
Write-Host 'Windows pure-logic and format tests passed; no firmware, partitions or boot settings were modified.'
