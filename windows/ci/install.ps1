[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$dll = Join-Path $UpstreamDir "pg_ivm.dll"
$control = Join-Path $UpstreamDir "pg_ivm.control"
$extensionDir = Join-Path $PgRoot "share\extension"

foreach ($path in @($dll, $control)) {
    if (-not (Test-Path $path)) {
        throw "Required pg_ivm file was not found: $path"
    }
}

Copy-Item $dll (Join-Path $PgRoot "lib\pg_ivm.dll") -Force
Copy-Item $control (Join-Path $extensionDir "pg_ivm.control") -Force
Copy-Item (Join-Path $UpstreamDir "pg_ivm--*.sql") $extensionDir -Force
