<#
.SYNOPSIS
    Run meson test. Returns exit code; does NOT throw on test failure.
.OUTPUTS
    Sets $LASTEXITCODE to the meson test exit code. Returns it as int.
.NOTES
    Callers that want to fail the build on test failure should check $LASTEXITCODE
    or the return value and exit/throw themselves.
#>
[CmdletBinding()]
param(
    [string]   $BuildDir          = 'build',
    [int]      $NumProcesses      = 4,
    [double]   $TimeoutMultiplier = 0.3,
    [string[]] $Suite             = @(),
    [string[]] $MesonArgs         = @()
)

. $PSScriptRoot/vcpkg.ps1

# Ensure vcpkg bin is on PATH so tmp_install postgres.exe can load libxml2.dll,
# lz4.dll, zstd.dll, etc. In CI this duplicates configure.ps1's GITHUB_PATH
# write; locally (where steps share a single shell) this is the only thing
# that puts the DLLs on PATH.
try {
    $vcpkg = Get-VcpkgInstallRoot
    Add-VcpkgBinToPath -BinDir $vcpkg.BinDir
} catch {
    Write-Warning "vcpkg bin discovery failed; tests will rely on existing PATH: $_"
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

# Intentionally not throwing — caller inspects $LASTEXITCODE
return $LASTEXITCODE
