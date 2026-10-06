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

$pgConfig = Join-Path $PgRoot "bin\pg_config.exe"
$pgVersionText = (& $pgConfig --version).Trim()
if ($LASTEXITCODE -ne 0 -or $pgVersionText -notmatch '^PostgreSQL\s+(\d+)\.(\d+)') {
    throw "Could not determine PostgreSQL major/minor from pg_config: '$pgVersionText'"
}
$pgMajor = [int]$Matches[1]
$pgMinor = [int]$Matches[2]

# PostgreSQL 14's Windows import library does not expose two backend data
# symbols referenced by pg_ivm's copied PG14 compatibility code. Replace those
# data references in the disposable upstream checkout with equivalent behavior
# that uses only exported functions/local ObjectAddress initialization.
if ($pgMajor -eq 14) {
    $createAsPath = Join-Path $UpstreamDir "createas.c"
    $createAsText = Get-Content $createAsPath -Raw
    $invalidObjectPattern = 'if\s*\(CreateTableAsRelExists\(stmt\)\)\s*return\s+InvalidObjectAddress\s*;'
    $invalidMatches = [regex]::Matches($createAsText, $invalidObjectPattern)
    if ($invalidMatches.Count -ne 1) {
        throw "Expected exactly one CreateTableAsRelExists/InvalidObjectAddress block in createas.c, found $($invalidMatches.Count)."
    }
    $invalidReplacement = @'
if (CreateTableAsRelExists(stmt))
        {
            ObjectAddressSet(address, InvalidOid, InvalidOid);
            return address;
        }
'@
    $createAsText = [regex]::Replace(
        $createAsText,
        $invalidObjectPattern,
        $invalidReplacement.TrimEnd(),
        [Text.RegularExpressions.RegexOptions]::Singleline
    )

    $coreExistsCall = "if (CreateTableAsRelExists(stmt))"
    if (-not $createAsText.Contains($coreExistsCall)) {
        throw "Expected CreateTableAsRelExists call was not found after the PG14 patch."
    }
    $createAsText = $createAsText.Replace(
        $coreExistsCall,
        "if (pgextwin_CreateTableAsRelExists(stmt))"
    )

    $execMarker = @'
/*
 * ExecCreateImmv -- execute a create_immv() function
'@
    if (-not $createAsText.Contains($execMarker)) {
        throw "Expected ExecCreateImmv marker was not found in createas.c."
    }
    $localExistsHelper = @'
/*
 * Windows compatibility helper for PostgreSQL 14.
 *
 * PostgreSQL 14's backend exposes CreateTableAsRelExists(), but pg_ivm's
 * copied CREATE AS path is more reliable on Windows when the same check stays
 * inside the extension DLL. This is equivalent to the PostgreSQL 14 logic for
 * the create_immv() call path.
 */
static bool
pgextwin_CreateTableAsRelExists(CreateTableAsStmt *ctas)
{
    Oid nspid;
    Oid oldrelid;
    IntoClause *into = ctas->into;

    nspid = RangeVarGetCreationNamespace(into->rel);
    oldrelid = get_relname_relid(into->rel->relname, nspid);

    if (OidIsValid(oldrelid))
    {
        if (!ctas->if_not_exists)
            ereport(ERROR,
                    (errcode(ERRCODE_DUPLICATE_TABLE),
                     errmsg("relation \"%s\" already exists",
                            into->rel->relname)));

        ereport(NOTICE,
                (errcode(ERRCODE_DUPLICATE_TABLE),
                 errmsg("relation \"%s\" already exists, skipping",
                        into->rel->relname)));
        return true;
    }

    return false;
}

'@
    $createAsText = $createAsText.Replace($execMarker, $localExistsHelper + $execMarker)
    [IO.File]::WriteAllText($createAsPath, $createAsText, [Text.UTF8Encoding]::new($false))

    $pgIvmPath = Join-Path $UpstreamDir "pg_ivm.c"
    $pgIvmText = Get-Content $pgIvmPath -Raw
    $qcMarker = "QueryCompletion qc;"
    if (-not $pgIvmText.Contains($qcMarker)) {
        throw "Expected QueryCompletion declaration was not found in pg_ivm.c."
    }
    $pgIvmText = $pgIvmText.Replace($qcMarker, "QueryCompletion qc = {0};")
    [IO.File]::WriteAllText($pgIvmPath, $pgIvmText, [Text.UTF8Encoding]::new($false))

    $ruleutils14Path = Join-Path $UpstreamDir "ruleutils_14.c"
    $ruleutils14Text = Get-Content $ruleutils14Path -Raw
    $quoteMarker = "if (quote_all_identifiers)"
    $quoteCount = ([regex]::Matches($ruleutils14Text, [regex]::Escape($quoteMarker))).Count
    if ($quoteCount -ne 1) {
        throw "Expected exactly one quote_all_identifiers reference in ruleutils_14.c, found $quoteCount."
    }
    if (-not $ruleutils14Text.Contains('#include "utils/guc.h"')) {
        $includeMarker = '#include "utils/fmgroids.h"'
        if (-not $ruleutils14Text.Contains($includeMarker)) {
            throw "Expected utils/fmgroids.h include was not found in ruleutils_14.c."
        }
        $ruleutils14Text = $ruleutils14Text.Replace(
            $includeMarker,
            $includeMarker + [Environment]::NewLine + '#include "utils/guc.h"'
        )
    }
    $ruleutils14Text = $ruleutils14Text.Replace(
        $quoteMarker,
        'if (strcmp(GetConfigOption("quote_all_identifiers", false, false), "on") == 0)'
    )
    [IO.File]::WriteAllText($ruleutils14Path, $ruleutils14Text, [Text.UTF8Encoding]::new($false))

    Write-Host "Applied PostgreSQL 14 Windows data-symbol compatibility edits."
}

# PostgreSQL 14/15 do not automatically export SQL-callable extension
# functions the way newer PostgreSQL Windows headers do. Generate an explicit
# DEF file from upstream PG_FUNCTION_INFO_V1 declarations. Using the same DEF
# on every supported major also gives us a stable, auditable export surface.
$exports = @("Pg_magic_func", "_PG_init")
foreach ($sourceFile in Get-ChildItem -Path $UpstreamDir -File -Filter "*.c") {
    $source = Get-Content $sourceFile.FullName -Raw
    foreach ($match in [regex]::Matches($source, 'PG_FUNCTION_INFO_V1\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)')) {
        $functionName = $match.Groups[1].Value
        $exports += $functionName
        $exports += "pg_finfo_$functionName"
    }
}
$exports = @($exports | Sort-Object -Unique)

$defPath = Join-Path $UpstreamDir "pg_ivm.pgextwin.def"
(@("LIBRARY pg_ivm", "EXPORTS") + @($exports | ForEach-Object { "    $_" })) |
    Set-Content -Path $defPath -Encoding ascii

$mesonPath = Join-Path $UpstreamDir "meson.build"
$mesonText = Get-Content $mesonPath -Raw
$moduleMarker = @'
shared_module(module_name,
  pg_ivm_sources,
'@
$moduleReplacement = @'
shared_module(module_name,
  pg_ivm_sources,
  vs_module_defs: 'pg_ivm.pgextwin.def',
'@
if (-not $mesonText.Contains($moduleMarker)) {
    throw "Expected upstream shared_module block was not found in meson.build."
}
$mesonText = $mesonText.Replace($moduleMarker, $moduleReplacement)
[IO.File]::WriteAllText($mesonPath, $mesonText, [Text.UTF8Encoding]::new($false))

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

$dumpCmd = Join-Path $tempRoot "pg_ivm-dump-exports.cmd"
@"
@echo off
call "$vsDevCmd" -arch=x64 -host_arch=x64 >nul
if errorlevel 1 exit /b %errorlevel%
dumpbin /nologo /exports "$dllOut"
"@ | Set-Content -Path $dumpCmd -Encoding ascii

$exportOutput = @(& cmd.exe /d /c $dumpCmd)
if ($LASTEXITCODE -ne 0) {
    throw "dumpbin failed while validating pg_ivm.dll exports."
}
$exportText = $exportOutput -join [Environment]::NewLine
Write-Host "----- pg_ivm.dll exports -----"
$exportOutput | ForEach-Object { Write-Host $_ }
Write-Host "------------------------------"

foreach ($requiredExport in $exports) {
    if ($exportText -notmatch "(?m)\b$([regex]::Escape($requiredExport))\b") {
        throw "Required DLL export was not found: $requiredExport"
    }
}

Write-Host "Built pg_ivm $version for PostgreSQL $pgMajor.$pgMinor with exports: $($exports -join ', ')"
