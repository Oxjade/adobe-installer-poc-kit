param(
    [string]$InstallerPath,
    [switch]$SkipHeavy,
    [string]$Only
)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'Adobe Acrobat installer - PoC kit'
Write-Host 'Authorized testing only. This launches the real installer and may modify the system.' -ForegroundColor Yellow
Write-Host 'Use a snapshot/backup. Tests try to stop the installer early, but state may still change.' -ForegroundColor Yellow
Require-Admin
Ensure-Results
Remove-Item -LiteralPath (Join-Path $ResultsDir 'results.txt') -ErrorAction SilentlyContinue

$tests = @(
    @{ Id = 'ACRO-02'; File = 'Test-01-Timestamp.ps1';   Heavy = $false },
    @{ Id = 'ACRO-08'; File = 'Test-02-ASLR.ps1';        Heavy = $false },
    @{ Id = 'ACRO-01'; File = 'Test-03-EnvPath.ps1';     Heavy = $true  },
    @{ Id = 'ACRO-09'; File = 'Test-04-CLIPath.ps1';     Heavy = $true  },
    @{ Id = 'ACRO-03'; File = 'Test-05-IniMsiexec.ps1';  Heavy = $true  },
    @{ Id = 'ACRO-10'; File = 'Test-06-PassToSetup.ps1'; Heavy = $true  },
    @{ Id = 'ACRO-05'; File = 'Test-07-WebMsiPath.ps1';  Heavy = $true  },
    @{ Id = 'ACRO-06'; File = 'Test-08-LogLink.ps1';     Heavy = $true  },
    @{ Id = 'ACRO-07'; File = 'Test-09-PipeSquat.ps1';   Heavy = $true  }
)

foreach ($t in $tests) {
    if ($Only -and ($t.Id -notlike $Only)) { continue }
    if ($SkipHeavy -and $t.Heavy) { Write-Host "SKIP $($t.Id) (heavy)" -ForegroundColor DarkGray; continue }
    $path = Join-Path $PSScriptRoot $t.File
    try {
        & $path -InstallerPath $InstallerPath
    } catch {
        Write-Warning "$($t.Id) failed: $($_.Exception.Message)"
        Emit-Result $t.Id 'ERROR' $_.Exception.Message
    }
}

$lines = @()
$rf = Join-Path $ResultsDir 'results.txt'
if (Test-Path -LiteralPath $rf) { $lines = @(Get-Content -LiteralPath $rf) }
$rows = @()
foreach ($l in $lines) {
    if ($l -like 'RESULT|*') {
        $p = $l -split '\|', 4
        $rows += [pscustomobject]@{ Id = $p[1]; Status = $p[2]; Note = $p[3] }
    }
}

$md = @()
$md += '# PoC Results'
$md += ''
$md += ('Generated: ' + (Get-Date -Format o))
$md += ''
$md += '| Finding | Status | Evidence / note |'
$md += '|---|---|---|'
foreach ($r in $rows) {
    $note = ($r.Note -replace '\|', '/')
    $md += ('| {0} | {1} | {2} |' -f $r.Id, $r.Status, $note)
}
$conf = @($rows | Where-Object { $_.Status -eq 'CONFIRMED' }).Count
$unc  = @($rows | Where-Object { $_.Status -eq 'UNCONFIRMED' }).Count
$err  = @($rows | Where-Object { $_.Status -eq 'ERROR' }).Count
$md += ''
$md += ("CONFIRMED: $conf   UNCONFIRMED: $unc   ERROR: $err")
$md += ''
$md += 'Evidence logs: acro01-process.log, acro01-evidence.txt, acro03-process.log, acro04-process.log, acro07-pipe.txt, loglink-target.txt, AdobeSFX*.log in %TEMP%.'
$md | Set-Content -LiteralPath (Join-Path $ResultsDir 'report.md') -Encoding UTF8

Write-Header 'Summary'
$md | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host ("Report written to: {0}" -f (Join-Path $ResultsDir 'report.md')) -ForegroundColor Cyan
