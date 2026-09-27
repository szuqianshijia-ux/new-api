param(
    [string]$GoPath = 'go',
    [string]$BunPath = 'bun',
    [string]$RuntimeDirectory = (Join-Path $PSScriptRoot '..\..\..\new-api-runtime')
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runtime = [IO.Path]::GetFullPath($RuntimeDirectory)
New-Item -ItemType Directory -Force $runtime | Out-Null
$revision = git -C $root rev-parse --short HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine source revision.' }
$version = "native-loopback-$revision"
Push-Location (Join-Path $root 'web')
try {
    & $BunPath install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Frontend dependency installation failed.' }
    $env:VITE_REACT_APP_VERSION = $version
    & $BunPath --bun run build
    if ($LASTEXITCODE -ne 0) { throw 'Frontend build failed.' }
} finally { Pop-Location }
Push-Location $root
try {
    $env:CGO_ENABLED = '0'
    & $GoPath build -ldflags "-s -w -X github.com/QuantumNous/new-api/common.Version=$version" -o (Join-Path $runtime 'new-api-loopback.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Backend build failed.' }
    Get-FileHash (Join-Path $runtime 'new-api-loopback.exe')
} finally { Pop-Location }
