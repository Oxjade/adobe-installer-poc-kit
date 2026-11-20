param([string]$InstallerPath)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-08 - ASLR / mitigation flags'

function Get-DllCharacteristics([string]$Path) {
    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object System.IO.BinaryReader -ArgumentList $fs
        $fs.Position = 0x3C
        $pe = $br.ReadInt32()
        $fs.Position = $pe + 4 + 20 + 0x46
        return $br.ReadUInt16()
    } finally {
        $fs.Dispose()
    }
}

$targets = @()
try { $targets += (Get-InstallerPath $InstallerPath) } catch { Write-Warning $_.Exception.Message }
$setup = Join-Path $PayloadDir 'setup.exe'
if (Test-Path -LiteralPath $setup) { $targets += $setup }

foreach ($f in $targets) {
    $dc = Get-DllCharacteristics $f
    Write-Host ("{0}`n  DllCharacteristics=0x{1:X4} ASLR={2} NX={3} CFG={4}" -f `
        $f, $dc, [bool]($dc -band 0x40), [bool]($dc -band 0x100), [bool]($dc -band 0x4000))
}

if ($targets.Count -gt 0) {
    $dc = Get-DllCharacteristics $targets[0]
    if (-not ($dc -band 0x40)) {
        Emit-Result 'ACRO-08' 'CONFIRMED' ("DYNAMIC_BASE not set (DllCharacteristics=0x{0:X4}); fixed image base" -f $dc)
    } else {
        Emit-Result 'ACRO-08' 'REJECTED' 'ASLR (DYNAMIC_BASE) is enabled'
    }
} else {
    Emit-Result 'ACRO-08' 'ERROR' 'no target binary found'
}
