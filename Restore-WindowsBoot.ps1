#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param()
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this in the original Windows system, not Debian.' }
$admin=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (!$admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as Administrator.' }
Import-Module (Join-Path $PSScriptRoot 'lib/W2D.psm1') -Force
if (!('W2D.Firmware' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'lib/Firmware.cs') }
$work=Join-Path $env:ProgramData 'W2D'; $statePath=Join-Path $work 'state.json'
if (!(Test-Path -LiteralPath $statePath)) { throw 'No recorded trial state. No firmware/files changed. Preserve any staging directory for manual inspection.' }
$state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.Schema -ne 1 -or $state.BootName -notmatch '^Boot00[7-9A-F][0-9A-F]$' -or $state.BootId -lt 112 -or $state.BootId -gt 255 -or $state.BootName -cne ('Boot{0:X4}' -f $state.BootId)) { throw 'Invalid recorded trial identity.' }
[W2D.Firmware]::EnablePrivilege()
$next=[W2D.Firmware]::ReadGlobal('BootNext')
if ($null -ne $next -and ($next.Length -ne 2 -or [BitConverter]::ToUInt16($next,0) -ne $state.BootId)) { throw 'Another BootNext is pending; refusing to modify it.' }
$entry=[W2D.Firmware]::ReadGlobal($state.BootName)
if ($null -ne $entry -and [Convert]::ToBase64String($entry) -cne $state.BootPayload) { throw 'Trial entry content changed; refusing to delete it.' }
if (!$PSCmdlet.ShouldProcess('Recorded W2D trial only','Cancel one-time boot, remove matching trial files, preserve backups and the appended CA')) { return }
$previousPreference=$ErrorActionPreference
try {
    $ErrorActionPreference='Continue'
    & shutdown.exe /a 2>&1 | Out-Null
    $abortCode=$LASTEXITCODE
} finally { $ErrorActionPreference=$previousPreference }
if ($abortCode -ne 0 -and $abortCode -ne 1116) { throw 'Could not cancel a scheduled restart. Cancel it manually before continuing.' }
$next=[W2D.Firmware]::ReadGlobal('BootNext')
$entry=[W2D.Firmware]::ReadGlobal($state.BootName)
if ($null -ne $next) {
    if ($next.Length -ne 2 -or [BitConverter]::ToUInt16($next,0) -ne $state.BootId -or $null -eq $entry -or [Convert]::ToBase64String($entry) -cne $state.BootPayload) { throw 'Boot selection changed; refusing to disarm another entry.' }
    [W2D.Firmware]::DeleteGlobal('BootNext')
}
$espPartition=Get-Partition -DiskNumber $state.DiskNumber | Where-Object { ([guid]$_.Guid).ToString() -eq $state.EspGuid }
if (!$espPartition) { throw 'Original ESP no longer exists. This tool cannot restore an erased Windows installation.' }
$letter=Get-W2dFreeLetter; $mounted=$false
try {
    & mountvol.exe ($letter+':') /S
    if ($LASTEXITCODE -ne 0) { throw 'ESP mount failed.' }
    $mounted=$true; $esp=$letter+':\'
    if (([guid](Get-Partition -DriveLetter $letter).Guid).ToString() -ne $state.EspGuid) { throw 'Mounted ESP mismatch.' }
    if ((Get-FileHash -LiteralPath (Join-Path $esp 'EFI/Microsoft/Boot/bootmgfw.efi') -Algorithm SHA256).Hash -ne $state.WindowsBootHash) { throw 'Windows boot manager changed; manual review required.' }
    $allowed=@('EFI/w2d/shimx64.efi','EFI/w2d/grubx64.efi','EFI/w2d/linux','EFI/w2d/initrd.gz','EFI/w2d/grub.cfg','debian-installer/amd64/grub/grub.cfg')
    foreach ($file in $state.Files) {
        if ($allowed -notcontains $file.Path) { throw 'Unrecognized file path in state; refusing cleanup.' }
        $path=Join-Path $esp $file.Path
        if ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $file.SHA256) { throw "Trial file changed: $($file.Path). Preserve it for inspection." }
    }
    $next=[W2D.Firmware]::ReadGlobal('BootNext')
    if ($null -ne $next) { throw 'A new BootNext appeared during cleanup; refusing further firmware changes.' }
    $entry=[W2D.Firmware]::ReadGlobal($state.BootName)
    if ($null -ne $entry) {
        if ([Convert]::ToBase64String($entry) -cne $state.BootPayload) { throw 'Trial ID was reused during cleanup; not deleting it.' }
        [W2D.Firmware]::DeleteGlobal($state.BootName)
    }
    foreach ($file in $state.Files) { $path=Join-Path $esp $file.Path; if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } }
    foreach ($relative in @('EFI/w2d','debian-installer/amd64/grub','debian-installer/amd64','debian-installer')) {
        $path=Join-Path $esp $relative
        if ((Test-Path -LiteralPath $path) -and @(Get-ChildItem -LiteralPath $path -Force).Count -eq 0) { Remove-Item -LiteralPath $path }
    }
    if ($null -ne [W2D.Firmware]::ReadGlobal($state.BootName)) { throw 'Trial entry deletion did not persist.' }
    $state.Status='Cancelled'; $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    $archive=Join-Path $env:ProgramData ('W2D-cancelled-'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $work -Destination $archive
    Write-Host "Trial cancelled. Backups and diagnostic files preserved at $archive."
    Write-Host 'Windows boot files and permanent BootOrder were not rewritten. The authenticated CA addition is NOT reversed.'
    Write-Warning 'Keep this archive private: it contains the password hash inside the trial initrd.'
} finally { if ($mounted) { & mountvol.exe ($letter+':') /D | Out-Null } }
