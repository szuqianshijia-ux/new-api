param(
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot '..\..\..\new-api-runtime'),
    [ValidateRange(1024, 65535)][int]$Port = 3000,
    [ValidateRange(5, 300)][int]$PollSeconds = 15
)

$ErrorActionPreference = 'Stop'
$runtime = [IO.Path]::GetFullPath($RuntimeDirectory)
$launcher = Join-Path $PSScriptRoot 'Start-Native.ps1'
$logDirectory = Join-Path $runtime 'logs'
$watchdogLog = Join-Path $logDirectory 'watchdog.log'

New-Item -ItemType Directory -Force $logDirectory | Out-Null
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "New API launcher not found: $launcher"
}

function Write-WatchdogLog([string]$Message) {
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $watchdogLog -Value "[$timestamp] $Message" -Encoding UTF8
}

$lastState = $null
Write-WatchdogLog "watchdog started for http://127.0.0.1:$Port"

while ($true) {
    $healthy = $false
    try {
        $status = Invoke-RestMethod "http://127.0.0.1:$Port/api/status" -TimeoutSec 3
        $healthy = $status.success -eq $true
    } catch {
        $healthy = $false
    }

    if ($healthy) {
        if ($lastState -ne 'healthy') {
            Write-WatchdogLog 'New API is healthy.'
            $lastState = 'healthy'
        }
    } else {
        $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
        if ($listeners.Count -gt 0) {
            if ($lastState -ne 'unhealthy-listener') {
                Write-WatchdogLog "Port $Port is listening but New API is unhealthy; leaving the listener untouched."
                $lastState = 'unhealthy-listener'
            }
        } else {
            Write-WatchdogLog 'New API is down; starting it.'
            try {
                $result = & $launcher -RuntimeDirectory $runtime -Port $Port 2>&1
                Write-WatchdogLog ($result -join ' ')
                $lastState = 'started'
            } catch {
                Write-WatchdogLog "start failed: $($_.Exception.Message)"
                $lastState = 'start-failed'
            }
        }
    }

    Start-Sleep -Seconds $PollSeconds
}
