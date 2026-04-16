<#
.SYNOPSIS
    Stop and unregister a postgres Windows service. Idempotent - succeeds
    if the service is already gone.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BinDir,
    [Parameter(Mandatory)][string]$ServiceName
)

$ErrorActionPreference = "Stop"

$pgCtl = Join-Path $BinDir "pg_ctl.exe"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    Write-Host "Service $ServiceName does not exist; nothing to remove."
    return
}

if ($svc.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status -eq "Stopped") { break }
        Start-Sleep -Milliseconds 500
    }
}

if (Test-Path $pgCtl) {
    & $pgCtl unregister -N $ServiceName
    # Tolerate non-zero exit; sc.exe fallback below
}

# Belt-and-braces: ensure service is removed even if pg_ctl unregister failed
$null = sc.exe delete $ServiceName
