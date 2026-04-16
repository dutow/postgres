BeforeAll {
    $script:TestScript = Join-Path $PSScriptRoot '../test.ps1'
}

Describe 'pg_tde/test.ps1' {
    It 'does not throw on missing build dir (meson returns non-zero)' {
        { & $script:TestScript -BuildDir (Join-Path $TestDrive 'no-pg_tde-build') } |
            Should -Not -Throw
    }

    It 'returns a numeric exit code' {
        & $script:TestScript -BuildDir (Join-Path $TestDrive 'no-pg_tde-build') 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -BeNullOrEmpty
        $LASTEXITCODE | Should -BeOfType [int]
    }
}
