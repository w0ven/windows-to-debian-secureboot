#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateSet('Check','Test','AutoInstall')][string]$Mode='Check',
    [int]$InterfaceIndex=0,
    [string]$IPAddress,
    [int]$PrefixLength=0,
    [string]$Gateway,
    [string[]]$DnsServers,
    [ValidatePattern('^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$')][string]$Hostname='debian',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_+/-]{0,63}$')][string]$TimeZone='Asia/Shanghai',
    [ValidateRange(1,65535)][int]$SshPort=22,
    [switch]$RecoveryAvailable,
    [switch]$AcceptNoRecovery,
    [switch]$NoReboot
)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'lib/W2D.psm1') -Force
if (!('W2D.Firmware' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'lib/Firmware.cs') }
$lock=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'assets.lock.json') -Raw | ConvertFrom-Json
if ($lock.schemaVersion -ne 1 -or $lock.distribution -ne 'trixie') { throw 'Unsupported artifact lock.' }
$plan=Get-W2dPlan -InterfaceIndex $InterfaceIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -Gateway $Gateway -DnsServers $DnsServers
[W2D.Firmware]::EnablePrivilege()
$pending=[W2D.Firmware]::ReadGlobal('BootNext')
if ($null -ne $pending) { throw 'Another one-time boot is already pending. Inspect it before continuing.' }
$beforeOrder=[W2D.Firmware]::ReadGlobal('BootOrder')
if ($null -eq $beforeOrder) { throw 'No firmware boot order found.' }
$db=(Get-SecureBootUEFI -Name db).Bytes
$hasCa=[W2D.Firmware]::SignatureEntries($db,$true) -contains $lock.uefiCaSha256
Write-Host "Windows system disk: $($plan.DiskNumber), $([math]::Round($plan.DiskBytes/1GB,2)) GiB"
Write-Host "ESP: $($plan.EspGuid); IPv4: $($plan.IPAddress)/$($plan.PrefixLength); gateway: $($plan.Gateway)"
Write-Host "DNS: $($plan.DnsServers -join ', '); NIC: $($plan.MacAddress); SSH port: $SshPort"
Write-Host "Microsoft UEFI CA 2023 already trusted: $hasCa"
Write-Host 'Static preflight only: firmware acceptance and actual boot cannot be proven without a trial.'
if ($Mode -eq 'Check') { Write-Host 'No files, firmware variables or boot settings changed.'; return }
if ($RecoveryAvailable -and $AcceptNoRecovery) { throw 'Choose only one recovery declaration.' }
if (!$RecoveryAvailable -and !$AcceptNoRecovery) { throw 'Confirm provider console/reset/reinstall access with -RecoveryAvailable, or explicitly accept possible permanent loss of access with -AcceptNoRecovery.' }
$work=Join-Path $env:ProgramData 'W2D'
if (Test-Path -LiteralPath $work) { throw "Staging already exists at $work. Do not rerun blindly; see Restore-WindowsBoot.ps1 and the recovery guide." }
if (!$PSCmdlet.ShouldProcess("Windows system disk $($plan.DiskNumber)","Stage $Mode, possibly append an authenticated trust update, and arm a one-time reboot")) { return }
Write-Warning 'Back up all required data off this VPS first. Local boot backups are NOT a Windows/data restore image and are erased by installation.'
if ($AcceptNoRecovery) { Write-Warning 'A boot or network failure may require the provider. The software watchdog cannot recover firmware/GRUB/kernel hangs.' }
if ($Mode -eq 'AutoInstall') {
    Write-Warning 'AUTO MODE ERASES THE ENTIRE SYSTEM DISK after local disk/network checks. Those checks do NOT prove inbound SSH reachability.'
    $phrase="AUTO-WIPE DISK $($plan.DiskNumber)"
} else {
    Write-Host 'TEST MODE keeps Windows until you SSH into the trial and explicitly run /w2d/install-debian.sh.'
    $phrase="TEST-BOOT DISK $($plan.DiskNumber)"
}
Write-Host 'This will change the Secure Boot trust store if needed, and reboot unless -NoReboot was specified.'
if ((Read-Host "Type exactly: $phrase") -cne $phrase) { throw 'Cancelled; nothing staged.' }
if (!('W2D.Sha512Crypt' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'lib/Sha512Crypt.cs') }
$first=Read-Host 'New Debian root password (16-256 characters; also used for the installer SSH account)' -AsSecureString
$second=Read-Host 'Repeat password' -AsSecureString
$a=[IntPtr]::Zero; $b=[IntPtr]::Zero
try {
    $a=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($first); $b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
    $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($a); $again=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)
    if ($plain.Length -lt 16 -or $plain.Length -gt 256 -or $plain -cne $again -or $plain.Contains([char]0)) { throw 'Passwords must match and contain 16-256 characters without NUL.' }
    $passwordHash=[W2D.Sha512Crypt]::Hash($plain,[W2D.Sha512Crypt]::GenerateSalt())
} finally {
    if ($a -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($a) }
    if ($b -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    $plain=$null; $again=$null; $first.Dispose(); $second.Dispose()
}
Protect-W2dDirectory $work
$mounted=$false; $armed=$false; $state=$null; $letter=$null
try {
    $downloads=Join-Path $work 'downloads'
    Get-W2dDownloads $lock $downloads
    $modeValue=if ($Mode -eq 'AutoInstall') { 'auto' } else { 'test' }
    $settings=[ordered]@{
        MODE=$modeValue; IP_ADDRESS=$plan.IPAddress; PREFIX_LENGTH=[string]$plan.PrefixLength; NETMASK=$plan.Netmask
        GATEWAY=$plan.Gateway; DNS_SERVERS=($plan.DnsServers -join ' '); NIC_MAC=$plan.MacAddress
        HOSTNAME=$Hostname; TIME_ZONE=$TimeZone; SSH_PORT=[string]$SshPort; ROOT_PASSWORD_HASH=$passwordHash
        EXPECTED_ESP_PARTUUID=$plan.EspGuid; EXPECTED_DISK_BYTES=[string]$plan.DiskBytes; FALLBACK_SECONDS='600'
    }
    $config=@(foreach ($name in $settings.Keys) { "$name=$(ConvertTo-W2dShellValue ([string]$settings[$name]))" }) -join "`n"
    $entries=New-Object 'System.Collections.Generic.List[object]'
    $entries.Add([pscustomobject]@{Name='w2d/config.sh'; Mode=33152; Data=[Text.Encoding]::UTF8.GetBytes($config+"`n")})
    foreach ($script in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'linux') -Filter '*.sh' -File) {
        $content=[IO.File]::ReadAllText($script.FullName).Replace("`r`n","`n")
        $entries.Add([pscustomobject]@{Name=('w2d/'+$script.Name); Mode=33216; Data=[Text.Encoding]::UTF8.GetBytes($content)})
    }
    $startup=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'linux/startup.sh')).Replace("`r`n","`n")
    $entries.Add([pscustomobject]@{Name='usr/lib/debian-installer-startup.d/S19w2d'; Mode=33261; Data=[Text.Encoding]::UTF8.GetBytes($startup)})
    foreach ($asset in $lock.assets | Where-Object { $_.role -eq 'udeb' }) {
        $entries.Add([pscustomobject]@{Name=('w2d/packages/'+$asset.name); Mode=33152; Data=[IO.File]::ReadAllBytes((Join-Path $downloads $asset.name))})
    }
    $preseed=@"
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/disable_dhcp boolean true
d-i netcfg/use_autoconfig boolean false
d-i netcfg/get_ipaddress string $($plan.IPAddress)
d-i netcfg/get_netmask string $($plan.Netmask)
d-i netcfg/get_gateway string $($plan.Gateway)
d-i netcfg/get_nameservers string $($plan.DnsServers -join ' ')
d-i netcfg/get_hostname string $Hostname
d-i netcfg/get_domain string
d-i netcfg/confirm_static boolean true
d-i preseed/early_command string /w2d/boot-gate.sh
"@
    $entries.Add([pscustomobject]@{Name='preseed.cfg'; Mode=33152; Data=[Text.Encoding]::UTF8.GetBytes($preseed.Replace("`r`n","`n")+"`n")})
    Write-W2dCpio $entries.ToArray() (Join-Path $work 'overlay.cpio')
    Join-W2dInitrd (Join-Path $downloads 'initrd.gz') (Join-Path $work 'overlay.cpio') (Join-Path $work 'initrd-test.gz')
    $passwordHash=$null; $config=$null; $settings=$null; $entries=$null
    $letter=Get-W2dFreeLetter
    & mountvol.exe ($letter+':') /S
    if ($LASTEXITCODE -ne 0) { throw 'Failed to mount the system ESP.' }
    $mounted=$true; $esp=$letter+':\'
    $actual=Get-Partition -DriveLetter $letter
    if (([guid]$actual.Guid).ToString() -ne $plan.EspGuid -or $actual.DiskNumber -ne $plan.DiskNumber) { throw 'Mounted ESP identity does not match the system disk.' }
    if ((Test-Path (Join-Path $esp 'EFI/w2d')) -or (Test-Path (Join-Path $esp 'debian-installer'))) { throw 'Existing trial/netboot files detected. Refusing to overwrite them.' }
    $required=(Get-Item (Join-Path $work 'initrd-test.gz')).Length+2MB
    foreach ($name in @('linux','shimx64.efi','grubx64.efi')) { $required+=(Get-Item (Join-Path $downloads $name)).Length }
    if ((Get-Volume -DriveLetter $letter).SizeRemaining -lt $required) { throw 'Insufficient free space on the existing ESP. No partition resizing is attempted.' }
    $backup=Join-Path $work 'backup'; New-Item -ItemType Directory -Path $backup | Out-Null
    foreach ($name in @('PK','KEK','db','dbx')) { [IO.File]::WriteAllBytes((Join-Path $backup ($name+'.bin')),(Get-SecureBootUEFI -Name $name).Bytes) }
    & bcdedit.exe /export (Join-Path $backup 'BCD') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'BCD export failed.' }
    & robocopy.exe (Join-Path $esp 'EFI') (Join-Path $backup 'EFI') /E /R:0 /W:0 /NFL /NDL /NJH /NJS /XF BCD BCD.LOG BCD.LOG1 BCD.LOG2 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw 'Boot file backup failed; no boot entry armed.' }
    $windowsBoot=Join-Path $esp 'EFI/Microsoft/Boot/bootmgfw.efi'
    $windowsHash=(Get-FileHash -LiteralPath $windowsBoot -Algorithm SHA256).Hash
    $bootId=$null
    foreach ($id in 112..255) { if ($null -eq [W2D.Firmware]::ReadGlobal(('Boot{0:X4}' -f $id))) { $bootId=$id; break } }
    if ($null -eq $bootId) { throw 'No free trial firmware entry in reserved search range.' }
    if ($plan.EspOffset % $plan.SectorSize -or $plan.EspBytes % $plan.SectorSize) { throw 'ESP geometry is not sector aligned.' }
    $entry=[W2D.Firmware]::BootOption([guid]$plan.EspGuid,$plan.EspPartition,($plan.EspOffset/$plan.SectorSize),($plan.EspBytes/$plan.SectorSize),'\EFI\w2d\shimx64.efi')
    $bootName='Boot{0:X4}' -f $bootId
    $state=[ordered]@{Schema=1; Status='Staging'; EspGuid=$plan.EspGuid; DiskNumber=$plan.DiskNumber; BootName=$bootName; BootId=$bootId; BootPayload=[Convert]::ToBase64String($entry); BeforeBootOrder=[Convert]::ToBase64String($beforeOrder); WindowsBootHash=$windowsHash; Files=@()}
    $statePath=Join-Path $work 'state.json'
    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    New-Item -ItemType Directory -Path (Join-Path $esp 'EFI/w2d'),(Join-Path $esp 'debian-installer/amd64/grub') -Force | Out-Null
    $sources=[ordered]@{'EFI/w2d/shimx64.efi'=(Join-Path $downloads 'shimx64.efi'); 'EFI/w2d/grubx64.efi'=(Join-Path $downloads 'grubx64.efi'); 'EFI/w2d/linux'=(Join-Path $downloads 'linux'); 'EFI/w2d/initrd.gz'=(Join-Path $work 'initrd-test.gz')}
    $grub="set timeout=0`nset default=0`nmenuentry 'Debian 13 controlled trial' {`n linux (`$root)/EFI/w2d/linux auto=true priority=critical DEBIAN_FRONTEND=text net.ifnames=0 biosdevname=0`n initrd (`$root)/EFI/w2d/initrd.gz`n}`n"
    [IO.File]::WriteAllText((Join-Path $work 'grub.cfg'),$grub,[Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $work 'bridge.cfg'),"source (`$root)/EFI/w2d/grub.cfg`n",[Text.Encoding]::ASCII)
    $sources['EFI/w2d/grub.cfg']=Join-Path $work 'grub.cfg'; $sources['debian-installer/amd64/grub/grub.cfg']=Join-Path $work 'bridge.cfg'
    foreach ($relative in $sources.Keys) {
        $expected=(Get-FileHash -LiteralPath $sources[$relative] -Algorithm SHA256).Hash
        $state.Files+=@{Path=$relative; SHA256=$expected}
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
        $destination=Join-Path $esp $relative
        Copy-Item -LiteralPath $sources[$relative] -Destination $destination
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $expected) { throw "ESP readback mismatch: $relative" }
    }
    if ((Get-FileHash -LiteralPath $windowsBoot -Algorithm SHA256).Hash -ne $windowsHash) { throw 'Windows boot manager changed unexpectedly.' }
    if ([W2D.Firmware]::Sha256([W2D.Firmware]::ReadGlobal('BootOrder')) -ne [W2D.Firmware]::Sha256($beforeOrder) -or $null -ne [W2D.Firmware]::ReadGlobal('BootNext')) { throw 'Firmware boot settings changed during preparation.' }
    if (!$hasCa) {
        $currentDb=(Get-SecureBootUEFI -Name db).Bytes
        if ([W2D.Firmware]::Sha256($currentDb) -ne [W2D.Firmware]::Sha256($db)) { throw 'Trust database changed during preparation.' }
        [W2D.Firmware]::AppendAuthenticatedDb([IO.File]::ReadAllBytes((Join-Path $downloads 'DBUpdate3P2023.bin')))
        $afterDb=(Get-SecureBootUEFI -Name db).Bytes
        if ([W2D.Firmware]::SignatureEntries($afterDb,$true) -notcontains $lock.uefiCaSha256) { throw 'Firmware did not retain the required CA; stopping.' }
        $afterEntries=[W2D.Firmware]::SignatureEntries($afterDb,$false)
        foreach ($signature in [W2D.Firmware]::SignatureEntries($db,$false)) { if ($afterEntries -notcontains $signature) { throw 'Existing trust entry missing after append; stopping.' } }
    }
    foreach ($name in @('PK','KEK','dbx')) {
        if ([W2D.Firmware]::Sha256((Get-SecureBootUEFI -Name $name).Bytes) -ne [W2D.Firmware]::Sha256([IO.File]::ReadAllBytes((Join-Path $backup ($name+'.bin'))))) { throw "Unexpected $name change; stopping." }
    }
    if (!(Confirm-SecureBootUEFI)) { throw 'Secure Boot state changed unexpectedly.' }
    if ($null -ne [W2D.Firmware]::ReadGlobal($bootName)) { throw 'Trial entry ID was occupied during preparation.' }
    [W2D.Firmware]::WriteGlobal($bootName,$entry)
    if ([W2D.Firmware]::Sha256([W2D.Firmware]::ReadGlobal($bootName)) -ne [W2D.Firmware]::Sha256($entry)) { throw 'Trial boot entry readback mismatch.' }
    if ($null -ne [W2D.Firmware]::ReadGlobal('BootNext')) { throw 'Another one-time boot appeared before arming; refusing to replace it.' }
    [W2D.Firmware]::WriteGlobal('BootNext',[BitConverter]::GetBytes([uint16]$bootId)); $armed=$true
    if ([BitConverter]::ToUInt16([W2D.Firmware]::ReadGlobal('BootNext'),0) -ne $bootId) { throw 'BootNext readback mismatch.' }
    $state.Status='Armed'; $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8
    & mountvol.exe ($letter+':') /D; if ($LASTEXITCODE -ne 0) { throw 'ESP unmount failed.' }; $mounted=$false
    Write-Host "Trial SSH: ssh -p $SshPort installer@$($plan.IPAddress) (password entered above)"
    Write-Host "Installed SSH: ssh -p $SshPort root@$($plan.IPAddress) (same password)"
    Write-Host "Boot backup: $backup (copy off-machine before allowing disk erase)."
    if ($NoReboot) { Write-Warning 'BootNext IS ARMED. The next reboot enters the selected mode. Run Restore-WindowsBoot.ps1 to cancel it.'; return }
    & shutdown.exe /r /t 15 /d p:4:2 /c 'W2D controlled Debian 13 boot'
    if ($LASTEXITCODE -ne 0) { throw 'Reboot scheduling failed.' }
    Write-Host 'Reboot scheduled in 15 seconds. This is not yet proof of Linux boot or installation success.'
} catch {
    if ($armed -and $null -ne $state) {
        try {
            $next=[W2D.Firmware]::ReadGlobal('BootNext')
            $currentEntry=[W2D.Firmware]::ReadGlobal($state.BootName)
            if ($null -ne $next -and $next.Length -eq 2 -and [BitConverter]::ToUInt16($next,0) -eq $state.BootId -and $null -ne $currentEntry -and [Convert]::ToBase64String($currentEntry) -ceq $state.BootPayload) { [W2D.Firmware]::DeleteGlobal('BootNext') }
            elseif ($null -ne $next) { Write-Warning 'BootNext or the trial entry changed; not deleting another boot selection.' }
        } catch { Write-Warning 'Could not disarm BootNext. Inspect firmware state before any reboot.' }
    }
    Write-Warning "Stopped. Do not blindly rerun or restart. Preserve $work and read docs/recovery.md."
    throw
} finally {
    if ($mounted) { & mountvol.exe ($letter+':') /D | Out-Null }
    $passwordHash=$null; $config=$null; $settings=$null; $entries=$null
}
