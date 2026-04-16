<#
.SYNOPSIS
    Shared helpers for locating a vcpkg install root and wiring its bin
    directory onto PATH.
.DESCRIPTION
    Dot-source this file to get Get-VcpkgInstallRoot and Add-VcpkgBinToPath.
    Used by configure.ps1, stage.ps1, and test.ps1 so they all agree on where
    vcpkg put its DLLs - tests need them on PATH, staging copies them into the
    install prefix so the MSI is self-contained.
#>

function Get-VcpkgInstallRoot {
    [CmdletBinding()]
    param(
        [string]$Triplet = 'x64-windows'
    )

    $checked     = [System.Collections.Generic.List[string]]::new()
    $installRoot = $null

    foreach ($candidate in @($env:VCPKG_INSTALLED_DIR, $env:VCPKG_MANIFEST_INSTALL_DIR)) {
        if (-not $candidate) { continue }
        $checked.Add($candidate)

        # Env var may point at the parent of the triplet dir or at it directly
        if ((Test-Path $candidate) -and (Test-Path (Join-Path $candidate "$Triplet/lib/pkgconfig"))) {
            $installRoot = Join-Path $candidate $Triplet
            break
        }
        if ((Test-Path $candidate) -and (Test-Path (Join-Path $candidate 'lib/pkgconfig'))) {
            $installRoot = $candidate
            break
        }
    }

    if (-not $installRoot) {
        $searchRoots = @($env:GITHUB_WORKSPACE, $env:RUNNER_TEMP, (Get-Location).Path) |
            Where-Object { $_ -and (Test-Path $_) }
        $searchRoots | ForEach-Object { $checked.Add($_) }

        $found = $searchRoots |
            ForEach-Object {
                Get-ChildItem -Path $_ -Recurse -Filter $Triplet -Directory `
                              -ErrorAction SilentlyContinue -Depth 5
            } |
            Where-Object { Test-Path (Join-Path $_.FullName 'lib/pkgconfig') } |
            Select-Object -First 1

        if ($found) { $installRoot = $found.FullName }
    }

    if (-not $installRoot) {
        $msg  = "Could not locate vcpkg $Triplet install tree.`n"
        $msg += "Locations checked:`n"
        $checked | ForEach-Object { $msg += "  $_`n" }
        $msg += "Set VCPKG_INSTALLED_DIR or VCPKG_MANIFEST_INSTALL_DIR, or run vcpkg install first."
        throw $msg
    }

    [PSCustomObject]@{
        InstallRoot   = $installRoot
        BinDir        = Join-Path $installRoot 'bin'
        PkgConfigPath = Join-Path $installRoot 'lib/pkgconfig'
    }
}

function Add-VcpkgBinToPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BinDir,
        # Persist to GITHUB_PATH so later workflow steps (running in fresh shells) inherit it
        [switch]$Persist
    )

    if (-not (Test-Path $BinDir)) {
        Write-Warning "vcpkg bin directory not found at $BinDir - skipping PATH update"
        return
    }

    if ($Persist -and $env:GITHUB_PATH) {
        Add-Content -Path $env:GITHUB_PATH -Value $BinDir
        Write-Host "Added to GITHUB_PATH: $BinDir"
    }

    if ($env:PATH -notlike "*$BinDir*") {
        $env:PATH = "$BinDir;$env:PATH"
        Write-Host "Prepended to `$env:PATH: $BinDir"
    }
}
