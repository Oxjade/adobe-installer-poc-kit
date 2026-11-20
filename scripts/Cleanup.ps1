param([switch]$UninstallEvil)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'Cleanup'
Require-Admin

# 1) HKCU environment override (only if it points into this kit)
$cur = (Get-ItemProperty -Path 'HKCU:\Environment' -Name CommonProgramW6432 -ErrorAction SilentlyContinue).CommonProgramW6432
if ($cur -and ($cur -like "*$KitRoot*")) {
    Remove-ItemProperty -Path 'HKCU:\Environment' -Name CommonProgramW6432 -ErrorAction SilentlyContinue
    Write-Host 'Removed HKCU CommonProgramW6432 override.' -ForegroundColor Green
}

# 2) work dir
if (Test-Path -LiteralPath $WorkDir) {
    Remove-Item -Recurse -Force -LiteralPath $WorkDir -ErrorAction SilentlyContinue
    Write-Host 'Removed work dir.' -ForegroundColor Green
}

# 3) marker
Remove-Marker
Write-Host 'Removed C:\poc-marker.txt (if present).'

# 4) benign PoC MSI
if ($UninstallEvil) {
    & msiexec.exe /x $EvilProductCode /qn 2>$null | Out-Null
    Write-Host 'Requested uninstall of the PoC MSI.' -ForegroundColor Green
}
if (Test-Path -LiteralPath 'C:\Program Files\PoC') {
    Remove-Item -Recurse -Force -LiteralPath 'C:\Program Files\PoC' -ErrorAction SilentlyContinue
    Write-Host 'Removed C:\Program Files\PoC.' -ForegroundColor Green
}

# 5) %TEMP% log link
$link = Join-Path ([IO.Path]::GetTempPath()) 'AdobeSFX.log'
Try-RemoveFile $link
Write-Host 'Removed %TEMP%\AdobeSFX.log link (if present).'

# 6) WebMsiPath leftovers pointing into the kit
foreach ($k in @('HKLM:\SOFTWARE\Adobe\Adobe ARM\1.0\ARM', 'HKCU:\SOFTWARE\Adobe\Adobe ARM\1.0\ARM')) {
    $v = (Get-ItemProperty -Path $k -Name WebMsiPath -ErrorAction SilentlyContinue).WebMsiPath
    if ($v -and ($v -like "*$KitRoot*")) {
        Remove-ItemProperty -Path $k -Name WebMsiPath -ErrorAction SilentlyContinue
        Write-Host "Removed WebMsiPath from $k" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Cleanup complete. If the Adobe installer completed on its own, uninstall Acrobat manually.' -ForegroundColor Yellow
