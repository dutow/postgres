<#
.SYNOPSIS
    Run meson test on pg_tde. Returns exit code; does NOT throw on test failure.
.NOTES
    Callers that want to fail the build on test failure should check $LASTEXITCODE
    or the return value and exit/throw themselves.
#>
[CmdletBinding()]
param(
    [string]   $BuildDir          = 'pg_tde_build',
    [int]      $NumProcesses      = 4,
    [double]   $TimeoutMultiplier = 1.0,
    [string[]] $Suite             = @(),
    [string[]] $MesonArgs         = @()
)

. (Join-Path $PSScriptRoot '../vcpkg.ps1')

# Put vcpkg bin on PATH so pg_tde TAP tests can load libcurl/libssl/libcrypto etc.
try {
    $vcpkg = Get-VcpkgInstallRoot
    Add-VcpkgBinToPath -BinDir $vcpkg.BinDir
} catch {
    Write-Warning "vcpkg bin discovery failed; pg_tde tests will rely on existing PATH: $_"
}

$mesonTestArgs = @(
    'test',
    '-C', $BuildDir,
    '--num-processes', $NumProcesses,
    '--print-errorlogs',
    '--timeout-multiplier', $TimeoutMultiplier
)

foreach ($s in $Suite) {
    $mesonTestArgs += '--suite'
    $mesonTestArgs += $s
}
$mesonTestArgs += $MesonArgs

Write-Host "Running: meson $($mesonTestArgs -join ' ')"
& meson @mesonTestArgs

return $LASTEXITCODE
