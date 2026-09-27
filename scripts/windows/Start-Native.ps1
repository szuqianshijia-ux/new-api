param(
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot '..\..\..\new-api-runtime'),
    [ValidateRange(1024, 65535)][int]$Port = 3000
)

$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath($RuntimeDirectory)
$exe = Join-Path $runtime 'new-api-loopback.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "Build the native binary first: $exe" }
$version = & $exe --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch 'native-loopback') {
    throw 'This launcher requires the native-loopback build with BIND_ADDRESS support.'
}
$listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
if ($listeners.Count) { throw "Port $Port is already in use. Inspect the existing service before restarting." }

New-Item -ItemType Directory -Force (Join-Path $runtime 'data'), (Join-Path $runtime 'logs') | Out-Null
$secretFile = Join-Path $runtime 'session-secret.xml'
if (-not (Test-Path -LiteralPath $secretFile)) {
    if (Test-Path -LiteralPath (Join-Path $runtime 'data\new-api.db')) {
        throw 'Database exists but its original session-secret.xml is missing. Restore the original secret before starting.'
    }
    $secret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    ConvertTo-SecureString $secret -AsPlainText -Force | Export-Clixml -LiteralPath $secretFile
}
$secureSecret = Import-Clixml -LiteralPath $secretFile
$env:SESSION_SECRET = [Net.NetworkCredential]::new('', $secureSecret).Password
$env:CRYPTO_SECRET = $env:SESSION_SECRET
$env:BIND_ADDRESS = '127.0.0.1'
$env:PORT = "$Port"
$env:SQLITE_PATH = Join-Path $runtime 'data\new-api.db'
$env:SQL_DSN = ''
$env:LOG_SQL_DSN = ''
$env:REDIS_CONN_STRING = ''
$env:ENABLE_PPROF = 'false'
$env:DEBUG = 'false'
$env:GIN_MODE = 'release'
$env:TRUSTED_PROXIES = 'none'
$process = Start-Process -FilePath $exe -WorkingDirectory $runtime -WindowStyle Hidden -PassThru `
    -ArgumentList @('--port', "$Port", '--log-dir', './logs') `
    -RedirectStandardOutput (Join-Path $runtime 'logs\stdout.log') `
    -RedirectStandardError (Join-Path $runtime 'logs\stderr.log')
Remove-Item Env:SESSION_SECRET, Env:CRYPTO_SECRET

$deadline = [DateTime]::UtcNow.AddSeconds(90)
try {
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "New API exited. Check $runtime\logs\stderr.log" }
        $bound = @(Get-NetTCPConnection -State Listen -OwningProcess $process.Id -ErrorAction SilentlyContinue)
        if ($bound | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') }) {
            throw 'New API bound to a non-loopback address.'
        }
        try {
            $status = Invoke-RestMethod "http://127.0.0.1:$Port/api/status" -TimeoutSec 2
            if ($status.success -and ($bound | Where-Object LocalPort -eq $Port)) {
                Write-Output "New API is ready: http://127.0.0.1:$Port (PID $($process.Id))"
                return
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'New API did not become healthy within 90 seconds.'
} catch {
    if (-not $process.HasExited) { Stop-Process -Id $process.Id }
    throw
}
