param([string]$InstallerPath)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-02 - Authenticode timestamp verification'

$targets = @()
try { $targets += (Get-InstallerPath $InstallerPath) } catch { Write-Warning $_.Exception.Message }
$setup = Join-Path $PayloadDir 'setup.exe'
if (Test-Path -LiteralPath $setup) { $targets += $setup }

$anyTs = $false
foreach ($f in $targets) {
    $sig = Get-AuthenticodeSignature -LiteralPath $f
    $ts = $sig.TimeStamperCertificate
    $tsText = '<none>'
    if ($ts) { $tsText = $ts.Subject; $anyTs = $true }
    Write-Host ("File       : {0}" -f $f)
    Write-Host ("  Status   : {0}" -f $sig.Status)
    Write-Host ("  Signer   : {0}" -f $sig.SignerCertificate.Subject)
    Write-Host ("  Timestamp: {0}" -f $tsText)
}

if ($anyTs) {
    Emit-Result 'ACRO-02' 'REJECTED' 'RFC3161 timestamp present on signed binaries (earlier false positive corrected)'
} else {
    Emit-Result 'ACRO-02' 'UNCONFIRMED' 'no timestamp certificate found'
}
