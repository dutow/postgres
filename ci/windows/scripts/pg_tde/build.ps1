<#
.SYNOPSIS
    Build pg_tde with ninja.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BuildDir = 'pg_tde_build'
)

$ninjaFile = Join-Path $BuildDir 'build.ninja'
if (-not (Test-Path $ninjaFile)) {
    throw "build.ninja not found in '$BuildDir'. Run ci/windows/scripts/pg_tde/configure.ps1 first."
}

if ($PSCmdlet.ShouldProcess($BuildDir, 'Run ninja (pg_tde)')) {
    & ninja -C "$BuildDir"
    if ($LASTEXITCODE -ne 0) {
        throw "ninja build failed with exit code $LASTEXITCODE"
    }
}
