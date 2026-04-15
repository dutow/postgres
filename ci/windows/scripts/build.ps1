<#
.SYNOPSIS
    Build with ninja.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BuildDir = 'build'
)

$ninjaFile = Join-Path $BuildDir 'build.ninja'
if (-not (Test-Path $ninjaFile)) {
    throw "build.ninja not found in '$BuildDir'. Run configure.ps1 first."
}

if ($PSCmdlet.ShouldProcess($BuildDir, 'Run ninja')) {
    & ninja -C $BuildDir
    if ($LASTEXITCODE -ne 0) {
        throw "ninja build failed with exit code $LASTEXITCODE"
    }
}
