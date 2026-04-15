<#
.SYNOPSIS
    Stage the build via meson install --destdir.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$DestDir,
    [string]$BuildDir = 'build'
)

$ninjaFile = Join-Path $BuildDir 'build.ninja'
if (-not (Test-Path $ninjaFile)) {
    throw "build.ninja not found in '$BuildDir'. Run configure.ps1 and build.ps1 first."
}

if ($PSCmdlet.ShouldProcess($DestDir, "meson install --destdir")) {
    & meson install -C "$BuildDir" --destdir "$DestDir"
    if ($LASTEXITCODE -ne 0) {
        throw "meson install failed with exit code $LASTEXITCODE"
    }
    Write-Host "Staged to: $DestDir"
}
