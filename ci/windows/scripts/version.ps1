<#
.SYNOPSIS
    Parse version information from meson.build and produce artifact name fields.
.OUTPUTS
    PSCustomObject with Version, ShortSha, ArtifactName, MsiVersion.
#>
[CmdletBinding()]
param(
    [string]$MesonBuild = (Join-Path $PSScriptRoot '../../../meson.build'),
    [string]$CommitSha  = '',
    [string]$Tag        = ''
)

$mesonFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MesonBuild)
if (-not (Test-Path $mesonFile)) {
    throw "meson.build not found at: $mesonFile"
}

$content = Get-Content $mesonFile -Raw
if ($content -notmatch "version:\s*'([^']+)'") {
    throw "Could not parse version from meson.build at: $mesonFile"
}
$version = $Matches[1]

$shortSha = if ($CommitSha) { $CommitSha.Substring(0, [Math]::Min(7, $CommitSha.Length)) } else { '' }

if ($Tag) {
    # Strip leading 'v' and anything after the first non-numeric/dot character
    $msiVersion = $Tag -replace '^v', ''
    $msiVersion = if ($msiVersion -match '^([\d.]+)') { $Matches[1] } else { $msiVersion }
    $artifactName = "percona-postgresql-18-$Tag-x64.msi"
} else {
    $msiVersion  = $version
    $artifactName = "percona-postgresql-18-$version-$shortSha-x64.msi"
}

[PSCustomObject]@{
    Version      = $version
    ShortSha     = $shortSha
    ArtifactName = $artifactName
    MsiVersion   = $msiVersion
}
