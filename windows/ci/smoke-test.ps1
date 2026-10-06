[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PgRoot,

    [Parameter(Mandatory = $true)]
    [int]$PgPort,

    [Parameter(Mandatory = $true)]
    [int]$PostgreSqlMajor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$initdb = Join-Path $PgRoot "bin\initdb.exe"
$pgCtl = Join-Path $PgRoot "bin\pg_ctl.exe"
$pgIsReady = Join-Path $PgRoot "bin\pg_isready.exe"
$psql = Join-Path $PgRoot "bin\psql.exe"

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$dataDir = Join-Path $tempRoot "pg_ivm-pg$PostgreSqlMajor-data"
$logFile = Join-Path $tempRoot "pg_ivm-pg$PostgreSqlMajor.log"
$setupSql = Join-Path $tempRoot "pg_ivm-pg$PostgreSqlMajor-setup.sql"

if (Test-Path $dataDir) {
    Remove-Item $dataDir -Recurse -Force
}
if (Test-Path $logFile) {
    Remove-Item $logFile -Force
}

& $initdb -D $dataDir -U postgres -A trust --encoding=UTF8 --no-locale
if ($LASTEXITCODE -ne 0) {
    throw "initdb failed."
}

function Show-PostgresLog {
    if (Test-Path $logFile) {
        Write-Host "----- PostgreSQL log -----"
        Get-Content $logFile -Tail 300
        Write-Host "--------------------------"
    }
}

function Wait-Postgres {
    for ($i = 0; $i -lt 45; $i++) {
        & $pgIsReady -h 127.0.0.1 -p $PgPort -q
        if ($LASTEXITCODE -eq 0) {
            return
        }
        Start-Sleep -Seconds 2
    }
    Show-PostgresLog
    throw "Temporary PostgreSQL cluster did not become ready."
}

try {
    $serverOptions = "-p $PgPort -c shared_preload_libraries=pg_ivm"
    & $pgCtl -D $dataDir -l $logFile -o $serverOptions start
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "Failed to start PostgreSQL with pg_ivm preloaded."
    }

    Wait-Postgres

    @'
CREATE EXTENSION pg_ivm;

CREATE TABLE public.pgextwin_ivm_probe (
    id integer PRIMARY KEY,
    payload integer NOT NULL
);

INSERT INTO public.pgextwin_ivm_probe
VALUES (1,10),(2,20),(3,30),(4,40),(5,50);

SELECT pgivm.create_immv(
    'public.pgextwin_ivm_probe_mv',
    'SELECT id, payload FROM public.pgextwin_ivm_probe'
);

INSERT INTO public.pgextwin_ivm_probe VALUES (6,60);
UPDATE public.pgextwin_ivm_probe SET payload = 200 WHERE id = 2;
DELETE FROM public.pgextwin_ivm_probe WHERE id = 1;
'@ | Set-Content -Path $setupSql -Encoding utf8

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -f $setupSql
    if ($LASTEXITCODE -ne 0) {
        Show-PostgresLog
        throw "pg_ivm functional setup failed."
    }

    $count = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT count(*) FROM public.pgextwin_ivm_probe_mv;") | Select-Object -Last 1).Trim()
    $sum = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT sum(payload) FROM public.pgextwin_ivm_probe_mv;") | Select-Object -Last 1).Trim()
    $row2 = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT payload FROM public.pgextwin_ivm_probe_mv WHERE id = 2;") | Select-Object -Last 1).Trim()
    $row1 = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT count(*) FROM public.pgextwin_ivm_probe_mv WHERE id = 1;") | Select-Object -Last 1).Trim()
    $definition = ((& $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -Atqc "SELECT pgivm.get_immv_def('public.pgextwin_ivm_probe_mv'::regclass);") | Select-Object -Last 1).Trim()

    if ($count -ne "5") {
        throw "Unexpected IMMV row count after incremental changes: $count"
    }
    if ($sum -ne "380") {
        throw "Unexpected IMMV payload sum after incremental changes: $sum"
    }
    if ($row2 -ne "200") {
        throw "IMMV did not reflect UPDATE for id=2: $row2"
    }
    if ($row1 -ne "0") {
        throw "IMMV did not reflect DELETE for id=1."
    }
    if ([string]::IsNullOrWhiteSpace($definition) -or $definition -notmatch "pgextwin_ivm_probe") {
        throw "pgivm.get_immv_def did not return the expected definition: $definition"
    }

    & $psql -h 127.0.0.1 -p $PgPort -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP TABLE public.pgextwin_ivm_probe_mv; DROP TABLE public.pgextwin_ivm_probe; DROP EXTENSION pg_ivm;"
    if ($LASTEXITCODE -ne 0) {
        throw "pg_ivm smoke-test cleanup failed."
    }
}
catch {
    Show-PostgresLog
    throw
}
finally {
    if (Test-Path (Join-Path $dataDir "postmaster.pid")) {
        & $pgCtl -D $dataDir -m fast stop
    }
}
