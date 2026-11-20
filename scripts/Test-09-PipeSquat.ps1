param([string]$InstallerPath, [int]$TimeoutSeconds = 60)

. (Join-Path $PSScriptRoot 'common.ps1')

Write-Header 'ACRO-07 - fixed named pipe squatting'
Require-Admin
Ensure-Results

$inst = Get-InstallerPath $InstallerPath
$pipe = $null
$connected = $false
$data = ''

try {
    $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
        $PipeName,
        [System.IO.Pipes.PipeDirection]::In,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous)
    $wait = $pipe.BeginWaitForConnection($null, $null)

    $proc = Start-Process -FilePath $inst -PassThru
    if ($wait.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))) {
        $pipe.EndWaitForConnection($wait)
        $connected = $true
        Write-Host 'Client connected to squatted pipe.' -ForegroundColor Green
        $buf = New-Object byte[] 4096
        try {
            $readTask = $pipe.ReadAsync($buf, 0, $buf.Length)
            if ($readTask.Wait(5000)) {
                $n = $readTask.Result
                if ($n -gt 0) { $data = [Text.Encoding]::UTF8.GetString($buf, 0, $n) }
            }
        } catch { }
    } else {
        Write-Host 'No client connected within timeout.' -ForegroundColor Yellow
    }
    if ($proc -and -not $proc.HasExited) { Stop-Tree $proc.Id }
    Get-Process setup,msiexec -ErrorAction SilentlyContinue | ForEach-Object { Stop-Tree $_.Id }
} catch {
    Write-Warning $_.Exception.Message
} finally {
    if ($pipe) { $pipe.Dispose() }
}

if ($connected) {
    Set-Content -LiteralPath (Join-Path $ResultsDir 'acro07-pipe.txt') -Value $data -Encoding UTF8
    Emit-Result 'ACRO-07' 'CONFIRMED' ("elevated process connected to squatted pipe; captured {0} bytes" -f $data.Length)
} else {
    Emit-Result 'ACRO-07' 'UNCONFIRMED' 'no connection to the fixed pipe within timeout'
}
