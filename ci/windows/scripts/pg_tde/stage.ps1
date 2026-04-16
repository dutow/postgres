<#
.SYNOPSIS
    Install pg_tde into an existing staged PG tree via meson install --destdir.
.DESCRIPTION
    Unlike the main ci/windows/scripts/stage.ps1, this script does not copy
    runtime DLLs - the main stage step already dropped them into the staged
    bin/ directory. pg_tde's meson install adds pg_tde.dll, frontend .exes,
    and share/extension/pg_tde* files alongside PG's own artifacts, so the
    existing wix heat harvest picks them up automatically.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$DestDir,
    [string]$BuildDir = 'pg_tde_build'
)

$ninjaFile = Join-Path $BuildDir 'build.ninja'
if (-not (Test-Path $ninjaFile)) {
    throw "build.ninja not found in '$BuildDir'. Run ci/windows/scripts/pg_tde/configure.ps1 and build.ps1 first."
}

if ($PSCmdlet.ShouldProcess($DestDir, "meson install --destdir (pg_tde)")) {
    & meson install -C "$BuildDir" --destdir "$DestDir"
    if ($LASTEXITCODE -ne 0) {
        throw "pg_tde meson install failed with exit code $LASTEXITCODE"
    }
    Write-Host "pg_tde staged into: $DestDir"
}
