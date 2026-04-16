<#
.SYNOPSIS
    Discover vcpkg install root, set environment, and run meson setup.
.OUTPUTS
    PSCustomObject with InstallRoot, PkgConfigPath, BuildDir.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $BuildDir     = 'build',
    [string]   $Prefix       = 'C:/pgsql-stage',
    [string]   $ExtraVersion = '',
    [string[]] $MesonArgs    = @()
)

. $PSScriptRoot/vcpkg.ps1

# --- 1. Discover vcpkg install root (throws with a helpful message on failure) ---
$vcpkg         = Get-VcpkgInstallRoot
$installRoot   = $vcpkg.InstallRoot
$pkgConfigPath = $vcpkg.PkgConfigPath

Write-Host "vcpkg install root: $installRoot"
Write-Host "pkg-config path:    $pkgConfigPath"
Write-Host ".pc files found:    $((Get-ChildItem "$pkgConfigPath/*.pc" -ErrorAction SilentlyContinue).Count)"

# --- 2. Export env for meson setup ---
$env:CMAKE_PREFIX_PATH = $installRoot
$env:PKG_CONFIG_PATH   = $pkgConfigPath

# --- 3. Put vcpkg bin on PATH so downstream steps find runtime DLLs ---
Add-VcpkgBinToPath -BinDir $vcpkg.BinDir -Persist
Write-Host "DLLs present in vcpkg bin: $((Get-ChildItem "$($vcpkg.BinDir)/*.dll" -ErrorAction SilentlyContinue).Count)"

# --- 4. meson setup ---
$mesonSetupArgs = @(
    'setup', $BuildDir,
    '--buildtype=debugoptimized',
    "--prefix=$Prefix",
    "--pkg-config-path=$pkgConfigPath",
    "--cmake-prefix-path=$installRoot",
    '-Dssl=none',
    '-Dicu=disabled',
    '-Dzlib=enabled',
    '-Dzstd=enabled',
    '-Dlz4=enabled',
    '-Dlibxml=enabled',
    '-Dlibxslt=enabled',
    '-Dldap=auto',
    '-Dplperl=disabled',
    '-Dplpython=disabled',
    '-Dpltcl=disabled'
)

if ($ExtraVersion) {
    $mesonSetupArgs += "-Dextra_version=$ExtraVersion"
}
$mesonSetupArgs += $MesonArgs

if ($PSCmdlet.ShouldProcess("meson setup $BuildDir", 'Run meson setup')) {
    Write-Host "Running: meson $($mesonSetupArgs -join ' ')"
    & meson @mesonSetupArgs
    if ($LASTEXITCODE -ne 0) {
        throw "meson setup failed with exit code $LASTEXITCODE"
    }
}

[PSCustomObject]@{
    InstallRoot   = $installRoot
    PkgConfigPath = $pkgConfigPath
    BuildDir      = $BuildDir
}
