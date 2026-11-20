param([string]$InstallerPath, [int]$TimeoutSeconds = 8)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-10 - passToSetup_ command-line option'
Require-Admin
Ensure-Results

$inst = Get-InstallerPath $InstallerPath
$val = 'POCPASS=1'
$variants = @('-p', '-passToSetup', '-passToSetup_', '-setupArgs', '-args')

foreach ($sw in $variants) {
    Write-Host ("Trying switch: {0} {1}" -f $sw, $val) -ForegroundColor Cyan
    $proc = Start-Process -FilePath $inst -ArgumentList @($sw, $val) -PassThru
    Start-Sleep -Seconds $TimeoutSeconds
    $logText = Read-TextShared (Get-SfxLogPath)
    $hit = $false
    if ($logText) {
        $hit = $logText -match ('passToSetup_?\s*:\s*' + [regex]::Escape($val))
    }
    if ($proc -and -not $proc.HasExited) { Stop-Tree $proc.Id }
    Get-Process setup,msiexec -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }
    if ($hit) {
        Emit-Result 'ACRO-10' 'CONFIRMED' ("SFX parsed '{0}' and set passToSetup_={1} (AdobeSFX log)" -f $sw, $val)
        return
    }
}

Emit-Result 'ACRO-10' 'UNCONFIRMED' 'no candidate switch set passToSetup_ in the log (static data flow remains; switch spelling unproven)'
