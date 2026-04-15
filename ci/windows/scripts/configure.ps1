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

# --- 1. Discover vcpkg install root ---
$installRoot = $null
$checked     = [System.Collections.Generic.List[string]]::new()

foreach ($candidate in @($env:VCPKG_INSTALLED_DIR, $env:VCPKG_MANIFEST_INSTALL_DIR)) {
    if ($candidate) {
        $checked.Add($candidate)
        if ((Test-Path $candidate) -and (Test-Path (Join-Path $candidate 'x64-windows/lib/pkgconfig'))) {
            # These env vars already point at the triplet parent; x64-windows is a subdir
            $installRoot = Join-Path $candidate 'x64-windows'
            break
        }
        # Maybe they already point directly at x64-windows
        if ((Test-Path $candidate) -and (Test-Path (Join-Path $candidate 'lib/pkgconfig'))) {
            $installRoot = $candidate
            break
        }
    }
}

if (-not $installRoot) {
    # Recursive search under GHA roots and CWD fallback
    $searchRoots = @($env:GITHUB_WORKSPACE, $env:RUNNER_TEMP, (Get-Location).Path) |
        Where-Object { $_ -and (Test-Path $_) }
    $searchRoots | ForEach-Object { $checked.Add($_) }

    $found = $searchRoots |
        ForEach-Object {
            Get-ChildItem -Path $_ -Recurse -Filter 'x64-windows' -Directory `
                          -ErrorAction SilentlyContinue -Depth 5
        } |
        Where-Object { Test-Path (Join-Path $_.FullName 'lib/pkgconfig') } |
        Select-Object -First 1

    if ($found) { $installRoot = $found.FullName }
}

if (-not $installRoot) {
    $msg  = "Could not locate vcpkg x64-windows install tree.`n"
    $msg += "Locations checked:`n"
    $checked | ForEach-Object { $msg += "  $_`n" }
    $msg += "Set VCPKG_INSTALLED_DIR or VCPKG_MANIFEST_INSTALL_DIR, or run vcpkg install first."
    throw $msg
}

$pkgConfigPath = Join-Path $installRoot 'lib/pkgconfig'

Write-Host "vcpkg install root: $installRoot"
Write-Host "pkg-config path:    $pkgConfigPath"
Write-Host ".pc files found:    $((Get-ChildItem "$pkgConfigPath/*.pc" -ErrorAction SilentlyContinue).Count)"

# --- 2. Export env for downstream steps in the same process ---
$env:CMAKE_PREFIX_PATH = $installRoot
$env:PKG_CONFIG_PATH   = $pkgConfigPath

# --- 3. Put vcpkg bin on PATH ---
$vcpkgBin = Join-Path $installRoot 'bin'
if (Test-Path $vcpkgBin) {
    if ($env:GITHUB_PATH) {
        Add-Content -Path $env:GITHUB_PATH -Value $vcpkgBin
        Write-Host "Added to GITHUB_PATH: $vcpkgBin"
    } else {
        $env:PATH = "$vcpkgBin;$env:PATH"
        Write-Host "Prepended to PATH: $vcpkgBin"
    }
    Write-Host "DLLs present: $((Get-ChildItem "$vcpkgBin/*.dll" -ErrorAction SilentlyContinue).Count)"
} else {
    Write-Warning "vcpkg bin directory not found at $vcpkgBin — tests will likely fail with missing DLLs"
}

# --- 4. meson setup ---
$mesonSetupArgs = @(
    'setup', $BuildDir,
    '--buildtype=release',
    "--prefix=$Prefix",
    "--pkg-config-path=$pkgConfigPath",
    "--cmake-prefix-path=$installRoot",
    '-Dssl=openssl',
    '-Dicu=enabled',
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
