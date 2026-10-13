# Synthetic test data only. Do not pass or add real passwords to this test suite.
# Windows PowerShell 5.1: powershell -NoProfile -File .\tests\test_crypto.ps1
# PowerShell 7: pwsh -NoProfile -File ./tests/test_crypto.ps1 -RequireOpenSsl
# Frozen independent vectors always run. Live OpenSSL runs when available.
# OpenSSL 3.0.20 on the test host returns <NULL> for empty passwords; those
# frozen expectations are from system crypt(3), and this limitation is reported.
[CmdletBinding()]
param(
    [string] $OpenSslPath = '',
    [switch] $RequireOpenSsl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Assertions = 0

function Assert-True {
    param([bool] $Condition, [string] $Label)
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:Assertions++
}

function Assert-Throws {
    param([scriptblock] $Action, [type] $ExceptionType, [string] $Label)
    $caught = $false
    try { & $Action }
    catch {
        $caught = $true
        $root = $_.Exception.GetBaseException()
        Assert-True ($ExceptionType.IsInstanceOfType($root)) ($Label + ': exception type')
    }
    Assert-True $caught ($Label + ': must reject')
}

function Invoke-OpenSslHash {
    param([string] $Executable, [string] $Password, [string] $Salt, [string] $Id)
    # Salt is whitelisted before constructing arguments. The synthetic password
    # travels only on stdin as raw UTF-8 bytes, never in a process command line.
    if ($Salt -cnotmatch '\A[./0-9A-Za-z]{1,16}\z') { throw 'Invalid test salt.' }
    $process = New-Object System.Diagnostics.Process
    $inputBytes = $null
    try {
        $process.StartInfo.FileName = $Executable
        $process.StartInfo.Arguments = 'passwd -6 -salt ' + $Salt + ' -stdin'
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        if (-not $process.Start()) { throw "OpenSSL failed to start: $Id" }
        $inputBytes = [System.Text.Encoding]::UTF8.GetBytes($Password + "`n")
        $inputStream = $process.StandardInput.BaseStream
        $inputStream.Write($inputBytes, 0, $inputBytes.Length)
        $inputStream.Flush()
        $inputStream.Close()
        $outputText = $process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        # Do not echo stdin or stderr: diagnostics could contain password data.
        if ($process.ExitCode -ne 0) { throw "OpenSSL failed for vector: $Id" }
        return $outputText.TrimEnd([char[]] @([char] 13, [char] 10))
    }
    finally {
        if ($null -ne $inputBytes) { [Array]::Clear($inputBytes, 0, $inputBytes.Length) }
        $process.Dispose()
    }
}

$rootDirectory = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path (Join-Path $rootDirectory 'lib') 'Sha512Crypt.cs'
if ($null -ne ('W2D.Sha512Crypt' -as [type])) {
    throw 'Run this test in a fresh PowerShell process to avoid testing stale Add-Type code.'
}
$compile = @{
    TypeDefinition = [System.IO.File]::ReadAllText($sourcePath)
    Language = 'CSharp'
}
if ((Get-Command Add-Type).Parameters.ContainsKey('CompilerOptions')) {
    $compile.CompilerOptions = @('/langversion:5')
}
else {
    # Windows PowerShell 5.1 uses the .NET Framework CodeDOM compiler.
    $parameters = New-Object System.CodeDom.Compiler.CompilerParameters
    $parameters.GenerateInMemory = $true
    $parameters.CompilerOptions = '/langversion:5'
    [void] $parameters.ReferencedAssemblies.Add('System.dll')
    $compile.CompilerParameters = $parameters
}
Add-Type @compile

$vectorPath = Join-Path $PSScriptRoot 'crypto-vectors.json'
$fixture = [System.IO.File]::ReadAllText($vectorPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
Assert-True ($fixture.rounds -eq 5000) 'fixture uses standard 5000 rounds'
$format = '\A\$6\$[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{85}[./01]\z'
$hashMethod = [W2D.Sha512Crypt].GetMethod('Hash')

if ([string]::IsNullOrEmpty($OpenSslPath)) {
    $command = Get-Command openssl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { $OpenSslPath = $command.Source }
}
if ($RequireOpenSsl -and [string]::IsNullOrEmpty($OpenSslPath)) {
    throw 'OpenSSL is required but was not found. Supply -OpenSslPath.'
}

$liveCount = 0
$emptyOpenSslUnavailable = 0
$hasAscii = $false
$hasUnicode = $false
$hasEmpty = $false
$hasLong = $false
$salts = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($vector in $fixture.vectors) {
    # Only IDs are printed on failure, never passwords or derived buffers.
    $id = [string] $vector.id
    $password = [string] $vector.password
    $salt = [string] $vector.salt
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($password)
    Assert-True ($byteCount -eq $vector.passwordUtf8Bytes) ($id + ': UTF-8 length')
    Assert-True ($vector.expected -cmatch $format) ($id + ': reference format')
    $actual = [W2D.Sha512Crypt]::Hash($password, $salt)
    Assert-True ($actual -ceq $vector.expected) ($id + ': independent known vector')
    Assert-True ($actual -cmatch $format) ($id + ': output format')
    Assert-True ($actual.StartsWith('$6$' + $salt + '$', [StringComparison]::Ordinal)) ($id + ': exact salt')
    Assert-True ($actual -ceq [W2D.Sha512Crypt]::Hash($password, $salt)) ($id + ': deterministic')
    [void] $salts.Add($salt)
    if ($password.Length -eq 0) { $hasEmpty = $true }
    elseif ($password -cmatch '\A[\x00-\x7f]+\z') { $hasAscii = $true }
    else { $hasUnicode = $true }
    if ($byteCount -ge 64) { $hasLong = $true }

    if (-not [string]::IsNullOrEmpty($OpenSslPath)) {
        $independent = Invoke-OpenSslHash $OpenSslPath $password $salt $id
        if ($password.Length -eq 0 -and $independent -ceq '<NULL>') {
            # A reference-tool limitation, not a passing OpenSSL comparison.
            $emptyOpenSslUnavailable++
        }
        else {
            Assert-True ($actual -ceq $independent) ($id + ': live OpenSSL comparison')
            $liveCount++
        }
    }
}
Assert-True ($hasAscii -and $hasUnicode -and $hasEmpty -and $hasLong -and $salts.Count -gt 1) 'required vector coverage'

# Salt validation must reject rather than truncate, normalize, or parse settings.
$badSalts = @('', '12345678901234567', ' bad', 'bad ', 'bad-salt', 'bad_salt',
    '$6$salt$', 'rounds=5000', "salt`n", "salt`r", "salt`t", "a`0b",
    ([string] [char] 0x00e9), ([string] [char] 0xff21))
$badSaltNumber = 0
foreach ($badSalt in $badSalts) {
    $badSaltNumber++
    Assert-Throws { [void] [W2D.Sha512Crypt]::Hash('synthetic-rejection-test', $badSalt) } ([ArgumentException]) ("invalid salt $badSaltNumber")
}
# Exhaust all ASCII characters, checking both allow and deny sides of the alphabet.
for ($code = 0; $code -lt 128; $code++) {
    $character = [string] [char] $code
    if ($character -cmatch '\A[./0-9A-Za-z]\z') {
        $hash = [W2D.Sha512Crypt]::Hash('synthetic-alphabet-test', $character)
        Assert-True ($hash -cmatch $format) ("allowed salt character $code")
    }
    else {
        $badSalt = 'a' + $character + 'b'
        Assert-Throws { [void] [W2D.Sha512Crypt]::Hash('synthetic-rejection-test', $badSalt) } ([ArgumentException]) ("rejected salt character $code")
    }
}
# Reflection preserves null arguments; PowerShell's string binder can turn null into ''.
Assert-Throws { [void] $hashMethod.Invoke($null, [object[]] @($null, 'salt')) } ([ArgumentNullException]) 'null password'
Assert-Throws { [void] $hashMethod.Invoke($null, [object[]] @('synthetic-test', $null)) } ([ArgumentNullException]) 'null salt'
$invalidUtf16 = [string] [char] 0xd800
Assert-Throws { [void] [W2D.Sha512Crypt]::Hash($invalidUtf16, 'salt') } ([System.Text.EncoderFallbackException]) 'invalid UTF-16 password'

$generatedSalts = New-Object 'System.Collections.Generic.HashSet[string]'
for ($i = 0; $i -lt 128; $i++) {
    $generated = [W2D.Sha512Crypt]::GenerateSalt()
    Assert-True ($generated -cmatch '\A[./0-9A-Za-z]{16}\z') 'generated salt format'
    Assert-True ($generatedSalts.Add($generated)) 'generated salt collision smoke check'
}
$generatedHash = [W2D.Sha512Crypt]::Hash('synthetic-generated-salt-test', $generated)
Assert-True ($generatedHash -cmatch $format) 'generated salt is accepted'

Write-Output ("PASS: C#5 compilation; {0} independent vectors; {1} assertions." -f $fixture.vectors.Count, $script:Assertions)
if ([string]::IsNullOrEmpty($OpenSslPath)) {
    Write-Output 'SKIP: live OpenSSL unavailable; frozen independently generated vectors passed.'
}
else {
    Write-Output ("PASS: {0} live OpenSSL comparisons." -f $liveCount)
    if ($emptyOpenSslUnavailable -gt 0) {
        Write-Output ("LIMITATION: OpenSSL returned <NULL> for {0} empty-password vectors; independent frozen crypt(3) expectations passed instead." -f $emptyOpenSslUnavailable)
    }
}
