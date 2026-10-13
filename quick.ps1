& {
    $ErrorActionPreference='Stop'
    $ProgressPreference='SilentlyContinue'
    if ($PSVersionTable.PSVersion -lt [version]'5.1' -or $env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess) { throw 'Open 64-bit Windows PowerShell 5.1 as Administrator on the Windows VPS to be erased.' }
    $admin=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (!$admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open Windows PowerShell as Administrator and try again.' }
    if (Test-Path -LiteralPath (Join-Path $env:ProgramData 'W2D')) { throw 'An earlier installation attempt exists in ProgramData\W2D. Do not rerun blindly; see the repository recovery guide.' }
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $folder=Join-Path $env:TEMP ('w2d-source-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $zip=Join-Path $folder 'source.zip'
    $source=Join-Path $folder 'source'
    Write-Host 'Downloading Windows-to-Debian from github.com/w0ven/windows-to-debian-secureboot ...'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/w0ven/windows-to-debian-secureboot/archive/refs/heads/main.zip' -OutFile $zip -TimeoutSec 180
    Expand-Archive -LiteralPath $zip -DestinationPath $source
    $entry=Join-Path $source 'windows-to-debian-secureboot-main/Install-Debian.ps1'
    if (!(Test-Path -LiteralPath $entry)) { throw 'The downloaded archive does not contain Install-Debian.ps1.' }
    Write-Host "Source retained at: $source"
    Set-ExecutionPolicy -Scope Process Bypass -Force
    & $entry -Quick
}
