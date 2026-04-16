<#
.SYNOPSIS
    Stage the build via meson install --destdir, then copy vcpkg runtime DLLs
    next to the installed binaries so the tree is self-contained for the MSI.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$DestDir,
    [string]$BuildDir = 'build'
)

. $PSScriptRoot/vcpkg.ps1

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

# Locate the staged bin dir by finding postgres.exe (meson strips drive letter
# from --prefix, so the exact layout under $DestDir depends on the prefix).
$postgresExe = Get-ChildItem -Path $DestDir -Recurse -Filter 'postgres.exe' `
                             -ErrorAction SilentlyContinue |
               Select-Object -First 1

if (-not $postgresExe) {
    Write-Warning "postgres.exe not found under $DestDir — skipping runtime DLL copy"
    return
}

$stagedBin = $postgresExe.Directory.FullName

if ($PSCmdlet.ShouldProcess($stagedBin, 'Copy vcpkg runtime DLLs')) {
    try {
        $vcpkg = Get-VcpkgInstallRoot
    } catch {
        Write-Warning "Could not locate vcpkg install tree; staged binaries will fail to load runtime DLLs: $_"
        return
    }

    $dlls = Get-ChildItem -Path $vcpkg.BinDir -Filter '*.dll' -ErrorAction SilentlyContinue
    foreach ($dll in $dlls) {
        Copy-Item -Path $dll.FullName -Destination $stagedBin -Force
    }
    Write-Host "Copied $($dlls.Count) runtime DLL(s) from $($vcpkg.BinDir) to $stagedBin"
}
