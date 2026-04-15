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
