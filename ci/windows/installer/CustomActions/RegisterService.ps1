<#
.SYNOPSIS
    Register postgres as a Windows service via pg_ctl, start it, and wait
    for pg_isready to succeed (30 second deadline).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BinDir,
    [Parameter(Mandatory)][string]$DataDir,
    [Parameter(Mandatory)][string]$ServiceName,
    [string]$Account = "NT AUTHORITY\NetworkService"
)

$ErrorActionPreference = "Stop"

$pgCtl = Join-Path $BinDir "pg_ctl.exe"
if (-not (Test-Path $pgCtl)) { throw "pg_ctl.exe not found at $pgCtl" }

& $pgCtl register -N $ServiceName -D $DataDir -S auto -U $Account
if ($LASTEXITCODE -ne 0) { throw "pg_ctl register failed with exit code $LASTEXITCODE" }

Start-Service -Name $ServiceName

$pgIsready = Join-Path $BinDir "pg_isready.exe"
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    & $pgIsready -d postgres
    if ($LASTEXITCODE -eq 0) { return }
    Start-Sleep -Milliseconds 500
}
throw "Service $ServiceName did not become ready within 30 seconds"
