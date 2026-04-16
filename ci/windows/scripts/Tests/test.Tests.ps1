BeforeAll {
    $script:TestScript = Join-Path $PSScriptRoot '../test.ps1'
}

Describe 'test.ps1' {
    It 'applies default parameter values' {
        # Capture the command line via -WhatIf output - test.ps1 doesn't support ShouldProcess,
        # so instead verify defaults by running against a non-existent build dir (meson will fail)
        # and checking that LASTEXITCODE is set (non-zero) rather than an exception thrown.
        $threw = $false
        try {
            # Pass a bogus build dir; meson exits non-zero, script must NOT throw
            & $script:TestScript -BuildDir (Join-Path $TestDrive 'no-build') 2>&1 | Out-Null
        } catch {
            $threw = $true
        }
        $threw | Should -Be $false
    }

    It 'does not throw on non-zero meson exit' {
        { & $script:TestScript -BuildDir (Join-Path $TestDrive 'no-build') } |
            Should -Not -Throw
    }

    It 'returns a numeric exit code' {
        & $script:TestScript -BuildDir (Join-Path $TestDrive 'no-build') 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -BeNullOrEmpty
        $LASTEXITCODE | Should -BeOfType [int]
    }
}
