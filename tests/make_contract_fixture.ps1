param([Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'lib/W2D.psm1') -Force
Add-Type -Path (Join-Path $root 'lib/Sha512Crypt.cs')
$plan=[pscustomobject]@{IPAddress='192.0.2.100';PrefixLength=24;Netmask='255.255.255.0';Gateway='192.0.2.1';DnsServers=@('1.1.1.1','8.8.8.8');MacAddress='02:00:00:00:00:01';EspGuid='12345678-1234-1234-1234-123456789012';DiskBytes=34359738368L}
$modeValue='test';$Hostname='debian';$TimeZone='Asia/Shanghai';$SshPort=2222
$passwordHash=[W2D.Sha512Crypt]::Hash('Synthetic-contract-only-2026','ContractSalt1234')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Install-Debian.ps1'),[ref]$tokens,[ref]$errors)
if ($errors) { throw 'Launcher parse error' }
foreach ($name in @('$settings','$config')) {
    $assignment=$ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq $name},$true) | Select-Object -First 1
    if (!$assignment) { throw "Missing producer assignment: $name" }
    . ([scriptblock]::Create($assignment.Extent.Text))
}
$entry=[pscustomobject]@{Name='w2d/config.sh';Mode=33152;Data=[Text.Encoding]::UTF8.GetBytes($config+"`n")}
Write-W2dCpio @($entry) $Destination
Write-Host 'Generated synthetic contract fixture from the actual launcher assignments.'
