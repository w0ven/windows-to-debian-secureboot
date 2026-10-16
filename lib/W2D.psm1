Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function ConvertTo-W2dIPv4 {
    param([string]$Address)
    if ($Address -notmatch '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$') { throw "Invalid IPv4 address: $Address" }
    $parts = @($Address.Split('.') | ForEach-Object { [int]$_ })
    if (@($parts | Where-Object { $_ -gt 255 }).Count) { throw "Invalid IPv4 address: $Address" }
    return [uint64]($parts[0] * 16777216L + $parts[1] * 65536L + $parts[2] * 256L + $parts[3])
}
function ConvertTo-W2dNetmask {
    param([int]$PrefixLength)
    if ($PrefixLength -lt 1 -or $PrefixLength -gt 30) { throw 'v1 supports IPv4 prefixes /1 through /30, not /31, /32 or routed/off-link gateways.' }
    $mask = 4294967295L - [uint64]([math]::Pow(2,32-$PrefixLength)-1)
    return ((24,16,8,0 | ForEach-Object { [string](($mask -shr $_) -band 255) }) -join '.')
}
function Assert-W2dNetwork {
    param([string]$IPAddress,[int]$PrefixLength,[string]$Gateway,[string[]]$DnsServers)
    $ip = ConvertTo-W2dIPv4 $IPAddress; $gw = ConvertTo-W2dIPv4 $Gateway
    $mask = ConvertTo-W2dIPv4 (ConvertTo-W2dNetmask $PrefixLength)
    $network = $ip -band $mask; $broadcast = $network + (4294967295L - $mask)
    if ($ip -eq $network -or $ip -eq $broadcast -or $gw -eq $network -or $gw -eq $broadcast -or $ip -eq $gw) { throw 'Invalid host or gateway address for the selected subnet.' }
    if (($ip -shr 24) -in @(0,127) -or ($ip -shr 24) -ge 224 -or ($ip -shr 16) -eq 43518) { throw 'Loopback, link-local and multicast addresses are unsupported.' }
    if (($gw -band $mask) -ne $network) { throw 'Off-link gateway detected. This version deliberately refuses that network layout.' }
    if (!$DnsServers -or $DnsServers.Count -gt 4) { throw 'Specify between one and four IPv4 DNS resolvers.' }
    foreach ($dns in $DnsServers) {
        $n = ConvertTo-W2dIPv4 $dns
        if (($n -shr 24) -in @(0,127) -or ($n -shr 24) -ge 224 -or ($n -shr 16) -eq 43518) { throw 'DNS must not be a local stub, link-local or multicast address.' }
    }
}
function ConvertTo-W2dShellValue {
    param([string]$Value)
    if ($Value.Contains("`r") -or $Value.Contains("`n") -or $Value.Contains([char]0) -or $Value.Contains("'")) { throw 'Unsafe shell configuration value.' }
    return "'$Value'"
}
function New-W2dRandomPassword {
    $bytes=New-Object byte[] 18
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
        return [Convert]::ToBase64String($bytes)
    } finally {
        $rng.Dispose()
        [Array]::Clear($bytes,0,$bytes.Length)
    }
}
function Confirm-W2dQuickInstall {
    param([int]$DiskNumber,[uint64]$DiskBytes,[string]$IPAddress,[int]$SshPort,[string]$Password,[switch]$NoReboot)
    if ([Console]::IsInputRedirected -or ![Environment]::UserInteractive) { throw 'Quick installation requires an interactive console. Do not pipe a confirmation into it.' }
    Write-Host ''
    Write-Warning "ERASE WINDOWS: ALL partitions and data on system disk $DiskNumber ($([math]::Round($DiskBytes/1GB,2)) GiB) will be deleted. Back up required data off this VPS first."
    Write-Warning 'This may update Secure Boot trust. Boot/network failure can leave this VPS inaccessible; without provider recovery access you may be unable to recover it.'
    Write-Warning 'Local network checks cannot prove inbound SSH access. Allow the SSH port in the provider firewall first.'
    Write-Host "Debian 13 login: ssh -p $SshPort root@$IPAddress"
    Write-Host "NEW ROOT PASSWORD: $Password" -ForegroundColor Yellow
    Write-Host 'Save this password on YOUR computer now. It is shown only here, not saved as plaintext by this tool. Do not share this screen or a console transcript.'
    if ($NoReboot) { Write-Warning 'NoReboot: the NEXT reboot will erase this disk and install Debian after checks pass.' }
    else { Write-Host 'After preparation this VPS will reboot automatically, install Debian, then reboot again. No installer SSH step is needed.' }
    $answer=Read-Host "Press ENTER to ERASE DISK $DiskNumber (password saved, data backed up, loss-of-access risk accepted); type anything else to cancel"
    if ($null -eq $answer -or $answer -cne '') { throw 'Cancelled; nothing staged.' }
}
function Get-W2dPlan {
    param([int]$InterfaceIndex,[string]$IPAddress,[int]$PrefixLength,[string]$Gateway,[string[]]$DnsServers)
    if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess) { throw 'Run 64-bit Windows PowerShell as Administrator on the Windows VPS.' }
    $admin = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator privileges are required.' }
    $computer = Get-CimInstance Win32_ComputerSystem
    if ($computer.Manufacturer -ne 'Microsoft Corporation' -or $computer.Model -ne 'Virtual Machine') { throw 'v1 supports Microsoft Hyper-V Generation 2 guests only.' }
    if (@(Get-CimInstance Win32_Processor | Where-Object { $_.Architecture -ne 9 }).Count) { throw 'Only x86-64/AMD64 guests are supported.' }
    if ([uint64]$computer.TotalPhysicalMemory -lt 1536MB) { throw 'At least a 2 GB VPS plan is required.' }
    if (!(Confirm-SecureBootUEFI)) { throw 'This tool is specifically for enabled Secure Boot. Use a normal installer for other machines.' }
    $systemPartition = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':')
    $disk = Get-Disk -Number $systemPartition.DiskNumber
    if ($disk.PartitionStyle -ne 'GPT' -or $disk.IsOffline -or $disk.IsReadOnly -or $disk.Size -lt 16GB) { throw 'A writable GPT Windows system disk of at least 16 GiB is required.' }
    $esp = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' })
    if ($esp.Count -ne 1 -or !$esp[0].Guid) { throw 'Cannot uniquely identify the EFI system partition on the Windows system disk.' }
    try {
        $encrypted = @(Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop | Where-Object { $_.DriveLetter -eq $env:SystemDrive })
        foreach ($volume in $encrypted) {
            $status = Invoke-CimMethod -InputObject $volume -MethodName GetConversionStatus
            if ($status.ReturnValue -ne 0 -or $status.ConversionStatus -ne 0) { throw 'BitLocker/device encryption is present or unknown. Decrypt and independently back up the disk before using this tool.' }
        }
    } catch [Microsoft.Management.Infrastructure.CimException] {
        if ($_.Exception.StatusCode.ToString() -notin @('InvalidNamespace','InvalidClass')) { throw }
    }
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Where-Object { $_.NextHop -ne '0.0.0.0' -and (!$InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) })
    if ($routes.Count -ne 1) { throw 'A unique IPv4 default route is required. Use -InterfaceIndex to select a NIC; multiple gateways are unsupported.' }
    $index = [int]$routes[0].InterfaceIndex
    $addresses = @(Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and (!$IPAddress -or $_.IPAddress -eq $IPAddress) })
    if ($addresses.Count -ne 1) { throw 'Cannot uniquely choose an existing IPv4 address. Specify -IPAddress if needed.' }
    $address = $addresses[0]
    if (!$IPAddress) { $IPAddress = $address.IPAddress }
    if (!$PrefixLength) { $PrefixLength = $address.PrefixLength }
    if (!$Gateway) { $Gateway = $routes[0].NextHop }
    if ($IPAddress -ne $address.IPAddress -or $PrefixLength -ne $address.PrefixLength -or $Gateway -ne $routes[0].NextHop) { throw 'Network overrides must match the currently working Windows connection.' }
    if (!$DnsServers) { $DnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4).ServerAddresses) }
    Assert-W2dNetwork $IPAddress $PrefixLength $Gateway $DnsServers
    $adapters = @(Get-NetAdapter | Where-Object { $_.InterfaceIndex -eq $index })
    if ($adapters.Count -ne 1) { throw 'Cannot uniquely match the selected route to a network adapter.' }
    $mac = $adapters[0].MacAddress.Replace('-',':').ToLowerInvariant()
    if ($mac -notmatch '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' -or $mac -eq '00:00:00:00:00:00' -or $mac -match '^.[13579bdf]:') { throw 'Invalid or multicast NIC MAC address.' }
    [pscustomobject]@{
        DiskNumber=[int]$disk.Number; DiskBytes=[uint64]$disk.Size; SectorSize=[uint64]$disk.LogicalSectorSize
        EspPartition=[uint32]$esp[0].PartitionNumber; EspGuid=([guid]$esp[0].Guid).ToString(); EspOffset=[uint64]$esp[0].Offset; EspBytes=[uint64]$esp[0].Size
        InterfaceIndex=$index; IPAddress=$IPAddress; PrefixLength=$PrefixLength; Netmask=(ConvertTo-W2dNetmask $PrefixLength); Gateway=$Gateway; DnsServers=$DnsServers; MacAddress=$mac
    }
}
function Get-W2dDownloads {
    param($Lock,[string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($asset in $Lock.assets) {
        if ($asset.name -notmatch '^[A-Za-z0-9._+-]+$' -or $asset.sha256 -notmatch '^[a-f0-9]{64}$' -or $asset.url -notmatch '^https://') { throw 'Malformed artifact lock.' }
        $file = Join-Path $Directory $asset.name
        if (!(Test-Path -LiteralPath $file)) {
            Write-Host "Downloading $($asset.name)"
            Invoke-WebRequest -UseBasicParsing -Uri $asset.url -OutFile ($file+'.partial') -TimeoutSec 180
            if ((Get-Item -LiteralPath ($file+'.partial')).Length -ne $asset.size -or (Get-FileHash -LiteralPath ($file+'.partial') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) { throw "Integrity check failed: $($asset.name). Do not disable hash checks; obtain a verified updated release." }
            Move-Item -LiteralPath ($file+'.partial') -Destination $file
        }
        if ((Get-Item -LiteralPath $file).Length -ne $asset.size -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $asset.sha256) { throw "Cached artifact mismatch: $($asset.name)" }
    }
}
function Write-W2dCpio {
    param([object[]]$Entries,[string]$Destination)
    $all = New-Object 'System.Collections.Generic.List[object]'
    $directories = @{}
    foreach ($entry in $Entries) {
        if ($entry.Name -notmatch '^[A-Za-z0-9_./+-]+$' -or $entry.Name.StartsWith('/') -or $entry.Name.Split('/') -contains '..') { throw 'Unsafe cpio entry name.' }
        $parts = $entry.Name.Split('/')
        for ($i=1; $i -lt $parts.Length; $i++) { $directories[($parts[0..($i-1)] -join '/')] = $true }
    }
    foreach ($dir in ($directories.Keys | Sort-Object { $_.Split('/').Count }, { $_ })) { $all.Add([pscustomobject]@{Name=$dir; Mode=16877; Data=[byte[]]@()}) }
    foreach ($entry in $Entries) { $all.Add($entry) }
    $all.Add([pscustomobject]@{Name='TRAILER!!!'; Mode=0; Data=[byte[]]@()})
    $stream = New-Object IO.MemoryStream
    try {
        $ino=0
        foreach ($entry in $all) {
            $ino++; [byte[]]$data=$entry.Data; [byte[]]$name=[Text.Encoding]::UTF8.GetBytes($entry.Name+[char]0)
            $fields=@($ino,$entry.Mode,0,0,1,0,$data.Length,0,0,0,0,$name.Length,0)
            $header=[Text.Encoding]::ASCII.GetBytes('070701'+(($fields | ForEach-Object { '{0:x8}' -f [uint32]$_ }) -join ''))
            $stream.Write($header,0,$header.Length); $stream.Write($name,0,$name.Length)
            while ($stream.Length % 4) { $stream.WriteByte(0) }
            $stream.Write($data,0,$data.Length)
            while ($stream.Length % 4) { $stream.WriteByte(0) }
        }
        [IO.File]::WriteAllBytes($Destination,$stream.ToArray())
    } finally { $stream.Dispose() }
}
function Join-W2dInitrd {
    param([string]$Original,[string]$Cpio,[string]$Destination)
    $output=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew)
    try {
        $input=[IO.File]::OpenRead($Original)
        try { $input.CopyTo($output) } finally { $input.Dispose() }
        $gzip=New-Object IO.Compression.GZipStream($output,[IO.Compression.CompressionMode]::Compress,$true)
        try { $input=[IO.File]::OpenRead($Cpio); try { $input.CopyTo($gzip) } finally { $input.Dispose() } } finally { $gzip.Dispose() }
    } finally { $output.Dispose() }
}
function Protect-W2dDirectory {
    param([string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity=New-Object Security.Principal.SecurityIdentifier($sid)
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Directory -AclObject $acl
}
function Get-W2dEspVolume {
    param([string]$VolumePath,[int]$DiskNumber,[string]$EspGuid)
    if ($VolumePath -notmatch '^\\\\\?\\Volume\{[0-9a-f-]{36}\}\\$') { throw 'Invalid mounted volume path.' }
    $partitions=@(Get-Partition -DiskNumber $DiskNumber | Where-Object { @($_.AccessPaths) -contains $VolumePath })
    if ($partitions.Count -ne 1 -or ([guid]$partitions[0].Guid).ToString() -ne ([guid]$EspGuid).ToString() -or $partitions[0].GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') { throw 'Mounted ESP identity does not match the system disk.' }
    $volumes=@(Get-Volume -Path $VolumePath)
    if ($volumes.Count -ne 1 -or $volumes[0].Path -ne $VolumePath) { throw 'Cannot uniquely identify the mounted ESP volume.' }
    return $volumes[0]
}
function Get-W2dFreeLetter {
    foreach ($letter in @('S','T','U','V','W','X','Y','Z')) { if (!(Test-Path ($letter+':\')) -and !(Get-PSDrive -Name $letter -ErrorAction SilentlyContinue)) { return $letter } }
    throw 'No free temporary drive letter for the ESP.'
}
Export-ModuleMember -Function *-W2d*
