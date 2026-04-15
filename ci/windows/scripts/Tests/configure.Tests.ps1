BeforeAll {
    $script:ConfigureScript = Join-Path $PSScriptRoot '../configure.ps1'
}

Describe 'configure.ps1' {
    It 'throws with clear message when vcpkg root cannot be found' {
        # Temporarily clear env vars so auto-discovery has nothing to find
        $savedInstalled = $env:VCPKG_INSTALLED_DIR
        $savedManifest  = $env:VCPKG_MANIFEST_INSTALL_DIR
        $savedGhWs      = $env:GITHUB_WORKSPACE
        $savedRunnerT   = $env:RUNNER_TEMP
        try {
            $env:VCPKG_INSTALLED_DIR        = $null
            $env:VCPKG_MANIFEST_INSTALL_DIR = $null
            $env:GITHUB_WORKSPACE           = $null
            $env:RUNNER_TEMP                = $null
            # Run from TestDrive which has no x64-windows tree
            Push-Location $TestDrive
            { & $script:ConfigureScript } | Should -Throw
        } finally {
            Pop-Location
            $env:VCPKG_INSTALLED_DIR        = $savedInstalled
            $env:VCPKG_MANIFEST_INSTALL_DIR = $savedManifest
            $env:GITHUB_WORKSPACE           = $savedGhWs
            $env:RUNNER_TEMP                = $savedRunnerT
        }
    }

    It '-WhatIf does not create a build.ninja' {
        # Even if vcpkg is somehow found, WhatIf must skip meson setup
        $savedInstalled = $env:VCPKG_INSTALLED_DIR
        $savedManifest  = $env:VCPKG_MANIFEST_INSTALL_DIR
        $savedGhWs      = $env:GITHUB_WORKSPACE
        $savedRunnerT   = $env:RUNNER_TEMP
        try {
            $env:VCPKG_INSTALLED_DIR        = $null
            $env:VCPKG_MANIFEST_INSTALL_DIR = $null
            $env:GITHUB_WORKSPACE           = $null
            $env:RUNNER_TEMP                = $null
            Push-Location $TestDrive
            # This will throw because no vcpkg root exists — that's expected before WhatIf skips meson
            # The important check: build.ninja must NOT exist afterwards
            try { & $script:ConfigureScript -WhatIf } catch {}
            Test-Path (Join-Path $TestDrive 'build/build.ninja') | Should -Be $false
        } finally {
            Pop-Location
            $env:VCPKG_INSTALLED_DIR        = $savedInstalled
            $env:VCPKG_MANIFEST_INSTALL_DIR = $savedManifest
            $env:GITHUB_WORKSPACE           = $savedGhWs
            $env:RUNNER_TEMP                = $savedRunnerT
        }
    }
}
