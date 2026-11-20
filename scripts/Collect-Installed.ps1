param([string]$Out = 'C:\acrobat-collect')

# Collect installed Acrobat 26.003 artifacts for off-box analysis.
# Run as Administrator in Windows 11. Writes a zip next to $Out.

$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$files = Join-Path $Out 'files'
New-Item -ItemType Directory -Force -Path $files | Out-Null
$log = Join-Path $Out 'collect.log'
function L($m) { $m | Tee-Object -FilePath $log -Append | Out-Host }

L "== Acrobat collector $(Get-Date -Format o) =="
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
L "Admin: $admin"

# --- find install root ---
$roots = New-Object System.Collections.Generic.List[string]
foreach ($k in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Acrobat.exe',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\AcroRd32.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Acrobat.exe',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\AcroRd32.exe')) {
    $p = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'(default)'
    if ($p) { $roots.Add((Split-Path -Parent $p)) }
}
foreach ($d in @('C:\Program Files\Adobe\Acrobat DC\Acrobat','C:\Program Files (x86)\Adobe\Acrobat DC\Acrobat','C:\Program Files\Adobe\Acrobat DC','C:\Program Files (x86)\Adobe\Acrobat DC')) {
    if (Test-Path $d) { $roots.Add($d) }
}
$roots = $roots | Sort-Object -Unique
L ("Install roots: " + ($roots -join ' | '))
if (-not $roots) { L 'Acrobat install not found. Install it (or run the PoC installer) first.' }

# --- service + registry state ---
L '== Services =='
Get-CimInstance Win32_Service |
    Where-Object { $_.PathName -match 'Adobe|ARM|Acrobat' -or $_.Name -match 'Adobe|ARM|Acrobat' } |
    Select-Object Name,DisplayName,State,StartMode,StartName,PathName |
    Format-List | Out-String -Width 300 | Tee-Object -FilePath (Join-Path $Out 'services.txt') | Out-Host

L '== Scheduled tasks =='
Get-ScheduledTask | Where-Object { $_.TaskName -match 'Adobe|ARM|Acrobat' } |
    Select-Object TaskName,TaskPath,State | Format-List | Out-String | Tee-Object -FilePath (Join-Path $Out 'tasks.txt') | Out-Host

L '== Registry exports =='
$regs = @(
    'HKLM\SOFTWARE\Adobe',
    'HKCU\SOFTWARE\Adobe',
    'HKLM\SOFTWARE\Google\Chrome\NativeMessagingHosts',
    'HKCU\SOFTWARE\Google\Chrome\NativeMessagingHosts',
    'HKLM\SOFTWARE\Classes\AppID\{935AF1FC-04A6-4335-8A0A-A2004DBEE584}',
    'HKLM\SOFTWARE\WOW6432Node\Classes\AppID\{935AF1FC-04A6-4335-8A0A-A2004DBEE584}'
)
$i = 0
foreach ($r in $regs) {
    $f = Join-Path $Out ("reg_{0}.txt" -f $i); $i++
    & reg.exe export $r $f /y 2>$null | Out-Null
}

# --- ACLs / interesting paths ---
L '== ACLs / temp paths =='
$aclTargets = @('C:\Windows\Temp','C:\temp','C:\Program Files\Common Files\Adobe\ARM\1.0','C:\ProgramData\Adobe\ARM')
$aclTargets += $roots
$aclOut = Join-Path $Out 'acls.txt'
foreach ($t in ($aclTargets | Sort-Object -Unique)) {
    if (Test-Path $t) {
        "### $t" | Tee-Object -FilePath $aclOut -Append | Out-Host
        & icacls.exe $t 2>&1 | Tee-Object -FilePath $aclOut -Append | Out-Host
    }
}

# --- ArmUI.ini and update state ---
L '== ArmUI.ini / ARM state =='
foreach ($p in @('C:\Windows\Temp\ArmUI.ini','C:\ProgramData\Adobe\ARM\ArmUI.ini','C:\ProgramData\Adobe\ARM')) {
    if (Test-Path $p) {
        L "FOUND: $p"
        if (Test-Path $p -PathType Leaf) {
            Copy-Item $p (Join-Path $Out ('ArmUI_' + [IO.Path]::GetFileName($p))) -Force
            Get-Content $p | Out-String | Tee-Object -FilePath (Join-Path $Out 'ArmUI_content.txt') | Out-Host
        }
    }
}
foreach ($k in @(
    'HKLM:\SOFTWARE\Adobe\Adobe ARM\1.0\ARM',
    'HKCU:\SOFTWARE\Adobe\Adobe ARM\1.0\ARM',
    'HKLM:\SOFTWARE\WOW6432Node\Adobe\Adobe ARM\1.0\ARM')) {
    if (Test-Path $k) {
        "### $k" | Tee-Object -FilePath (Join-Path $Out 'arm_registry.txt') -Append | Out-Host
        Get-ItemProperty $k | Format-List | Out-String | Tee-Object -FilePath (Join-Path $Out 'arm_registry.txt') -Append | Out-Host
    }
}

# --- copy key binaries ---
L '== Copy key binaries =='
$names = @(
    'Acrobat.dll','Acrobat.exe','AcroRd32.exe','acrocef.exe','libcef.dll','chrome_elf.dll',
    'acrobat_sl.exe','acrobroker.exe','AcroBroker.exe','AdobeCollabSync.exe',
    'wcchromenativemessaginghost.exe','manifest.json','Updater.api','plugin.x.manifest',
    'Flash.mpp','CRWindowsClientService.exe','Adobe_Crash_Processor.exe','ADNotificationManager.exe',
    'SingleClientServicesUpdater.exe','armsvc.exe','adobearm.exe','adobearmhelper.exe',
    'ccme_base.dll','ccme_asym.dll','ccme_ecc.dll','ccme_base_non_fips.dll','cryptocme.dll'
)
$searchDirs = @()
$searchDirs += $roots
$searchDirs += 'C:\Program Files\Common Files\Adobe\ARM\1.0'
$searchDirs += 'C:\Program Files (x86)\Common Files\Adobe\ARM\1.0'
$copied = @{}
foreach ($d in ($searchDirs | Sort-Object -Unique)) {
    if (-not (Test-Path $d)) { continue }
    foreach ($n in $names) {
        Get-ChildItem -Path $d -Recurse -File -Filter $n -ErrorAction SilentlyContinue | ForEach-Object {
            $key = $_.FullName.ToLower()
            if ($copied.ContainsKey($key)) { return }
            $copied[$key] = $true
            $dest = Join-Path $files ($_.Name + '__' + ([guid]::NewGuid().ToString('N').Substring(0,6)) )
            Copy-Item $_.FullName $dest -Force
            $sig = Get-AuthenticodeSignature -FilePath $_.FullName
            $row = [pscustomobject]@{
                Name = $_.Name; Path = $_.FullName; Size = $_.Length
                SHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
                Version = $_.VersionInfo.FileVersion; Product = $_.VersionInfo.ProductName
                Signature = $sig.Status; Signer = $sig.SignerCertificate.Subject
                Timestamper = $sig.TimeStamperCertificate.Subject
            }
            $row | Format-List | Out-String -Width 300 | Tee-Object -FilePath (Join-Path $Out 'binaries.txt') -Append | Out-Host
        }
    }
}

# --- native messaging manifests ---
L '== Native messaging manifests =='
Get-ChildItem -Path 'C:\Program Files\Common Files\Adobe','C:\Program Files (x86)\Common Files\Adobe' -Recurse -Filter 'manifest.json' -ErrorAction SilentlyContinue |
    ForEach-Object {
        $dest = Join-Path $Out ('manifest_' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
        Copy-Item $_.FullName $dest -Force
        "### $($_.FullName)" | Tee-Object -FilePath (Join-Path $Out 'manifests.txt') -Append | Out-Host
        Get-Content $_.FullName | Tee-Object -FilePath (Join-Path $Out 'manifests.txt') -Append | Out-Host
    }

# --- zip ---
$zip = "$Out.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $zip -Force
L "Wrote $zip"
