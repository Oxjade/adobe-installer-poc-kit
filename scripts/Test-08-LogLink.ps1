param([string]$InstallerPath, [int]$TimeoutSeconds = 60)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-06 - predictable %TEMP% log file (reparse/hardlink)'
Require-Admin
Ensure-Results

$inst = Get-InstallerPath $InstallerPath
$temp = [IO.Path]::GetTempPath()
$link = Join-Path $temp 'AdobeSFX.log'
$target = Join-Path $ResultsDir 'loglink-target.txt'
Set-Content -LiteralPath $target -Value 'ORIGINAL-CONTENT' -Encoding ASCII
Try-RemoveFile $link

$created = $false
try {
    New-Item -ItemType HardLink -Path $link -Target $target -ErrorAction Stop | Out-Null
    $created = $true
    Write-Host "hardlink created: $link -> $target"
} catch {
    Write-Warning "hardlink failed: $($_.Exception.Message)"
}
if (-not $created) {
    try {
        New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
        $created = $true
        Write-Host "symlink created: $link -> $target"
    } catch {
        Write-Warning "symlink failed: $($_.Exception.Message)"
    }
}

if (-not $created) {
    Emit-Result 'ACRO-06' 'UNCONFIRMED' 'could not create hardlink/symlink (privilege or filesystem restriction)'
    return
}

$proc = Start-Process -FilePath $inst -PassThru
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$changed = $false
while ((Get-Date) -lt $deadline) {
    $c = Get-Content -LiteralPath $target -Raw -ErrorAction SilentlyContinue
    if ($c -and ($c -notmatch '^ORIGINAL-CONTENT')) { $changed = $true; break }
    if ($proc.HasExited) { break }
    Start-Sleep -Milliseconds 200
}
if ($proc -and -not $proc.HasExited) { Stop-Tree $proc.Id }
Get-Process setup,msiexec -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }

if ($changed) {
    Emit-Result 'ACRO-06' 'CONFIRMED' 'elevated SFX followed the %TEMP%\AdobeSFX.log link and modified the target file'
} else {
    Emit-Result 'ACRO-06' 'UNCONFIRMED' 'target not modified within timeout (log may use CREATE_NEW or a different name)'
}

Try-RemoveFile $link
