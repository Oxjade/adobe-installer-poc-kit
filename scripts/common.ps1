$ErrorActionPreference = 'Stop'

$script:ScriptsDir  = $PSScriptRoot
$script:KitRoot     = Split-Path -Parent $PSScriptRoot
$script:PayloadDir  = Join-Path $KitRoot 'payload'
$script:ResultsDir  = Join-Path $KitRoot 'results'
$script:WorkDir     = Join-Path $KitRoot 'work'

$script:InstallerName   = 'AcroRdrDCx642600322110_en_US.exe'
$script:InstallerSha256 = 'a7149f099dba2f868b65c2e4d62149fe411490fbb622192725fcc9ecfaa03852'
$script:EvilMsi         = Join-Path $PayloadDir 'evil.msi'
$script:EvilProductCode = '{6CB989C9-2495-492C-8594-1EF4F46D95BB}'
$script:Marker          = 'C:\poc-marker.txt'
$script:PipeName        = '32B6B37A-4A7D-4e00-95F2-6F0BF3DE3E00'

function Write-Header([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkGray
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        throw 'This test must run from an elevated PowerShell (Run as administrator).'
    }
}

function Ensure-Results {
    if (-not (Test-Path -LiteralPath $ResultsDir)) {
        New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    }
}

function Emit-Result([string]$Id, [string]$Status, [string]$Note) {
    $line = "RESULT|$Id|$Status|$Note"
    $color = 'Gray'
    if ($Status -eq 'CONFIRMED')      { $color = 'Green' }
    elseif ($Status -eq 'UNCONFIRMED') { $color = 'Yellow' }
    elseif ($Status -eq 'REJECTED')    { $color = 'DarkGray' }
    Write-Host $line -ForegroundColor $color
    Ensure-Results
    Add-Content -LiteralPath (Join-Path $ResultsDir 'results.txt') -Value $line
}

function Get-InstallerPath([string]$Path) {
    if ($Path) {
        if (Test-Path -LiteralPath $Path) { return (Resolve-Path -LiteralPath $Path).Path }
        throw "Installer not found: $Path"
    }
    $p = Join-Path $KitRoot $InstallerName
    if (Test-Path -LiteralPath $p) { return $p }
    throw "Installer not found. Put $InstallerName in $KitRoot or pass -InstallerPath."
}

function Assert-InstallerHash([string]$Path) {
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLower()
    if ($h -ne $InstallerSha256) {
        Write-Warning "SHA256 mismatch: $h (expected $InstallerSha256)"
    } else {
        Write-Host 'Installer SHA256 OK' -ForegroundColor Green
    }
    return $h
}

function Test-Marker {
    if (-not (Test-Path -LiteralPath $Marker)) { return $null }
    return (Get-Content -LiteralPath $Marker -Raw -ErrorAction SilentlyContinue)
}

function Remove-Marker {
    if (Test-Path -LiteralPath $Marker) {
        Remove-Item -LiteralPath $Marker -Force -ErrorAction SilentlyContinue
    }
}

function Stop-Tree([int]$ProcessId) {
    if ($ProcessId -gt 0) {
        & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
    }
}

function Get-SfxLogPath {
    $tmp = [IO.Path]::GetTempPath()
    $candidates = Get-ChildItem -LiteralPath $tmp -Filter 'AdobeSFX*.log' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending
    if ($candidates) { return $candidates[0].FullName }
    return (Join-Path $tmp 'AdobeSFX.log')
}

function Read-TextShared([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $sr = New-Object IO.StreamReader($fs)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch {
        return ''
    }
}

function Watch-Processes {
    param(
        [string]$LogPath,
        [int]$TimeoutSeconds = 120,
        [int]$RootPid = 0,
        [scriptblock]$StopWhen,
        [switch]$KillOnStop
    )
    $seen = @{}
    $capturedPids = New-Object System.Collections.Generic.List[int]
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $procs = Get-CimInstance Win32_Process -Filter "Name='setup.exe' OR Name='msiexec.exe'" -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if (-not $seen.ContainsKey($p.ProcessId)) {
                $seen[$p.ProcessId] = $true
                $capturedPids.Add([int]$p.ProcessId)
                $line = ('[{0}] {1} PID {2} :: {3}' -f (Get-Date -Format o), $p.Name, $p.ProcessId, $p.CommandLine)
                Add-Content -LiteralPath $LogPath -Value $line -ErrorAction SilentlyContinue
                Write-Host $line -ForegroundColor DarkYellow
            }
        }
        $stop = $false
        if ($StopWhen) {
            try { $stop = [bool](& $StopWhen) } catch { $stop = $false }
        }
        if ($stop) { break }
        if ($RootPid -gt 0) {
            if (-not (Get-Process -Id $RootPid -ErrorAction SilentlyContinue)) { break }
        }
        Start-Sleep -Milliseconds 150
    }
    if ($KillOnStop) {
        if ($RootPid -gt 0) { Stop-Tree $RootPid }
        foreach ($id in $capturedPids) {
            if (Get-Process -Id $id -ErrorAction SilentlyContinue) { Stop-Tree $id }
        }
    }
    return $capturedPids
}

function Try-RemoveFile([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { }
    }
}
