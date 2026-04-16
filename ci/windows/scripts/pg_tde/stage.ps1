<#
.SYNOPSIS
    Install pg_tde into the staged PG tree it was configured against.
.DESCRIPTION
    pg_tde's meson.build derives install_dir from pg_config (--bindir,
    --libdir, --sharedir), which return absolute paths into the staged PG
    tree picked at configure time. So a plain `meson install` (no
    --destdir) drops pg_tde.dll, frontend .exes, and share/extension/pg_tde*
    files alongside PG's own artifacts already in that tree.

    Using --destdir would prepend it to those absolute paths, nesting the
    files under destdir + the entire stage prefix path - not what we want.

    This script does not copy runtime DLLs - the main
    ci/windows/scripts/stage.ps1 already dropped them into the staged bin/
    directory, and the existing wix heat harvest picks pg_tde's additions
    up automatically.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BuildDir = 'pg_tde_build'
)

$ninjaFile = Join-Path $BuildDir 'build.ninja'
if (-not (Test-Path $ninjaFile)) {
    throw "build.ninja not found in '$BuildDir'. Run ci/windows/scripts/pg_tde/configure.ps1 and build.ps1 first."
}

if ($PSCmdlet.ShouldProcess($BuildDir, "meson install (pg_tde)")) {
    & meson install -C "$BuildDir"
    if ($LASTEXITCODE -ne 0) {
        throw "pg_tde meson install failed with exit code $LASTEXITCODE"
    }
    Write-Host "pg_tde installed from: $BuildDir"
}
