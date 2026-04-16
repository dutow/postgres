<#
.SYNOPSIS
    Run meson setup on pg_tde, pointing pg_config at a staged PG install.
.DESCRIPTION
    pg_tde is an out-of-tree meson project that discovers PostgreSQL via
    pg_config. This script locates pg_config.exe under a previously-staged
    PG prefix, wires vcpkg pkgconfig/prefix paths the same way the main
    configure.ps1 does, and runs meson setup against the pg_tde source tree.
.OUTPUTS
    PSCustomObject with SourceDir, BuildDir, PgConfig.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $SourceDir    = (Join-Path $PSScriptRoot '../../../../pg_tde'),
    [string]   $BuildDir     = 'pg_tde_build',
    [Parameter(Mandatory)][string] $StagePrefix,
    [string[]] $MesonArgs    = @()
)

. (Join-Path $PSScriptRoot '../vcpkg.ps1')

# --- 1. Resolve and validate SourceDir ---
$resolvedSource = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceDir)
if (-not (Test-Path (Join-Path $resolvedSource 'meson.build'))) {
    throw "pg_tde meson.build not found at '$resolvedSource/meson.build'. Clone percona/pg_tde there, or pass -SourceDir."
}

# --- 2. Resolve pg_config from StagePrefix ---
$pgConfig = Join-Path $StagePrefix 'bin/pg_config.exe'
if (-not (Test-Path $pgConfig)) {
    throw "pg_config.exe not found at '$pgConfig'. Did you run ci/windows/scripts/stage.ps1 first?"
}

# --- 3. Discover vcpkg (same pattern as main configure.ps1) ---
$vcpkg         = Get-VcpkgInstallRoot
$installRoot   = $vcpkg.InstallRoot
$pkgConfigPath = $vcpkg.PkgConfigPath

Write-Host "pg_tde source:      $resolvedSource"
Write-Host "pg_config:          $pgConfig"
Write-Host "vcpkg install root: $installRoot"

$env:CMAKE_PREFIX_PATH = $installRoot
$env:PKG_CONFIG_PATH   = $pkgConfigPath
Add-VcpkgBinToPath -BinDir $vcpkg.BinDir -Persist

# --- 4. meson setup ---
# Pass source dir as a positional arg rather than cd'ing into it, so the
# build dir lives at CWD (matching build.ps1/test.ps1/stage.ps1 defaults).
$mesonSetupArgs = @(
    'setup', $BuildDir, $resolvedSource,
    '--buildtype=debugoptimized',
    "--pkg-config-path=$pkgConfigPath",
    "--cmake-prefix-path=$installRoot",
    "-Dpg_config=$pgConfig"
)
$mesonSetupArgs += $MesonArgs

if ($PSCmdlet.ShouldProcess("meson setup $BuildDir (pg_tde)", 'Run meson setup')) {
    Write-Host "Running: meson $($mesonSetupArgs -join ' ')"
    & meson @mesonSetupArgs
    if ($LASTEXITCODE -ne 0) {
        throw "meson setup failed with exit code $LASTEXITCODE"
    }
}

[PSCustomObject]@{
    SourceDir = $resolvedSource
    BuildDir  = $BuildDir
    PgConfig  = $pgConfig
}
