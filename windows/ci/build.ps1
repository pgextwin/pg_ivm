[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [string]$UpstreamDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
$vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "vswhere.exe was not found: $vswhere"
}

$vsRoot = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1).Trim()
if ([string]::IsNullOrWhiteSpace($vsRoot)) {
    throw "Visual Studio with the C++ x64 toolchain was not found."
}

$vsDevCmd = Join-Path $vsRoot "Common7\Tools\VsDevCmd.bat"
if (-not (Test-Path $vsDevCmd)) {
    throw "VsDevCmd.bat was not found: $vsDevCmd"
}

$control = Get-Content (Join-Path $UpstreamDir "pg_ivm.control") -Raw
if ($control -notmatch "default_version\s*=\s*'([^']+)'") {
    throw "Could not determine pg_ivm version from pg_ivm.control."
}
$version = $Matches[1]
if ($version -ne "1.16") {
    throw "Unexpected pg_ivm version: $version"
}

$python = (Get-Command python.exe -ErrorAction Stop).Source
& $python -m pip install --disable-pip-version-check --quiet "meson==1.8.3" "ninja==1.11.1.4"
if ($LASTEXITCODE -ne 0) {
    throw "Failed to install pinned Meson/Ninja tooling."
}

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$buildDir = Join-Path $tempRoot "pg_ivm-build"
if (Test-Path $buildDir) {
    Remove-Item $buildDir -Recurse -Force
}

$cmdFile = Join-Path $tempRoot "pg_ivm-build.cmd"
@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
set "PATH=$PgRoot\bin;%PATH%"
"$python" -m mesonbuild.mesonmain setup "$buildDir" "$UpstreamDir" --backend ninja --buildtype=release
if errorlevel 1 exit /b %errorlevel%
"$python" -m mesonbuild.mesonmain compile -C "$buildDir"
if errorlevel 1 exit /b %errorlevel%
"@ | Set-Content -Path $cmdFile -Encoding ascii

& cmd.exe /d /c $cmdFile
if ($LASTEXITCODE -ne 0) {
    throw "pg_ivm upstream Meson/MSVC build failed with exit code $LASTEXITCODE."
}

$dllItem = Get-ChildItem -Path $buildDir -Recurse -File -Filter "pg_ivm.dll" | Select-Object -First 1
if ($null -eq $dllItem) {
    throw "Meson completed but pg_ivm.dll was not found in the build tree."
}

$dllOut = Join-Path $UpstreamDir "pg_ivm.dll"
Copy-Item $dllItem.FullName $dllOut -Force

$dumpbin = (Get-Command dumpbin.exe -ErrorAction SilentlyContinue)
if ($null -ne $dumpbin) {
    Write-Host "----- pg_ivm.dll exports -----"
    & $dumpbin.Source /exports $dllOut
    Write-Host "------------------------------"
}

Write-Host "Built pg_ivm $version using the upstream Meson/MSVC Windows path."
