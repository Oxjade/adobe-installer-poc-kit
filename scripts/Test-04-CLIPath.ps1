param([string]$InstallerPath, [int]$TimeoutSeconds = 45)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-09 - Command-line output-folder override (INSTALLPATH)'
Require-Admin
Ensure-Results

$inst = Get-InstallerPath $InstallerPath
$variants = @(
    @{ Name = '-o <dir>';            Args = @('-o', '__DIR__') },
    @{ Name = '-o<dir>';             Args = @('-o__DIR__') },
    @{ Name = '/_o <dir>';           Args = @('/_o', '__DIR__') },
    @{ Name = '-outputFolder <dir>'; Args = @('-outputFolder', '__DIR__') }
)

$success = $null
foreach ($v in $variants) {
    $root = Join-Path $WorkDir ('acro09-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $attacker = Join-Path $root 'Common Files\Adobe'
    New-Item -ItemType Directory -Force -Path $attacker | Out-Null
    $targetTree = Join-Path $attacker 'Adobe\Acrobat\Setup'

    $argsList = @()
    foreach ($a in $v.Args) { $argsList += ($a -replace '__DIR__', $attacker) }

    Write-Host ("Trying: {0}" -f $v.Name) -ForegroundColor Cyan
    $proc = Start-Process -FilePath $inst -ArgumentList $argsList -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $hit = $false
    $logHit = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $targetTree) { $hit = $true; break }
        $lt = Read-TextShared (Get-SfxLogPath)
        if ($lt -match ('outputFolder_\s*:\s*' + [regex]::Escape($attacker))) { $logHit = $true; break }
        if ($proc.HasExited) { break }
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Seconds 1
    if ($proc -and -not $proc.HasExited) { Stop-Tree $proc.Id }
    Get-Process setup,msiexec -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }

    if ($hit -or $logHit) {
        $why = @()
        if ($hit) { $why += 'directory tree created' }
        if ($logHit) { $why += 'AdobeSFX log shows outputFolder_ set' }
        $success = @{ Name = $v.Name; Dir = $attacker; Why = ($why -join ', ') }
        break
    }
}

if ($success) {
    Emit-Result 'ACRO-09' 'CONFIRMED' ("switch '{0}' controls INSTALLPATH ({1}); dir={2}" -f $success.Name, $success.Why, $success.Dir)
} else {
    Emit-Result 'ACRO-09' 'UNCONFIRMED' 'no tested command-line switch overrode outputFolder_/INSTALLPATH'
}
