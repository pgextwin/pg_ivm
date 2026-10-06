[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamRepository,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamRef,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamVersion,

    [Parameter(Mandatory = $true)]
    [int]$PostgreSqlMajor,

    [Parameter(Mandatory = $true)]
    [string]$PostgreSqlMinor,

    [string]$DistDir = "dist"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$assetName = "pg_ivm-$UpstreamRef-pg$PostgreSqlMajor-windows-x64"
$stage = Join-Path $DistDir $assetName
$zipPath = Join-Path $DistDir "$assetName.zip"

if (Test-Path $stage) {
    Remove-Item $stage -Recurse -Force
}
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

New-Item -ItemType Directory -Force -Path (Join-Path $stage "lib") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage "share\extension") | Out-Null

Copy-Item (Join-Path $UpstreamDir "pg_ivm.dll") (Join-Path $stage "lib\pg_ivm.dll")
Copy-Item (Join-Path $UpstreamDir "pg_ivm.control") (Join-Path $stage "share\extension\pg_ivm.control")
Copy-Item (Join-Path $UpstreamDir "pg_ivm--*.sql") (Join-Path $stage "share\extension\")
Copy-Item (Join-Path $UpstreamDir "LICENSE") (Join-Path $stage "LICENSE")
Copy-Item (Join-Path $UpstreamDir "README.md") (Join-Path $stage "UPSTREAM-README.md")

$metadataScript = Join-Path $UpstreamDir "scripts\pg_ivm_dump_metadata"
if (Test-Path $metadataScript) {
    New-Item -ItemType Directory -Force -Path (Join-Path $stage "upstream-scripts") | Out-Null
    Copy-Item $metadataScript (Join-Path $stage "upstream-scripts\pg_ivm_dump_metadata")
}

$upstreamSha = (& git -C $UpstreamDir rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstreamSha)) {
    throw "Failed to resolve the pinned upstream commit SHA."
}

@"
pg_ivm Windows binary package
=============================

Upstream repository: $UpstreamRepository
Upstream ref:        $UpstreamRef
Upstream commit:     $upstreamSha
pg_ivm version:      $UpstreamVersion
PostgreSQL major:    $PostgreSqlMajor
PostgreSQL tested:   $PostgreSqlMinor
Architecture:        Windows x64
Compiler:            MSVC
License:             PostgreSQL-style; see LICENSE

This is an unofficial pgextwin Windows package built from the official pg_ivm source.
For correct immediate view maintenance, preload pg_ivm using shared_preload_libraries
or session_preload_libraries as documented by upstream.
"@ | Set-Content -Path (Join-Path $stage "PACKAGE-INFO.txt") -Encoding utf8

Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zipPath -CompressionLevel Optimal
if (-not (Test-Path $zipPath)) {
    throw "Expected package was not produced: $zipPath"
}
