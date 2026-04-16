BeforeAll {
    $script:BuildScript = Join-Path $PSScriptRoot '../build.ps1'
}

Describe 'pg_tde/build.ps1' {
    It 'throws when build.ninja is missing (no such dir)' {
        { & $script:BuildScript -BuildDir (Join-Path $TestDrive 'no-such-dir') } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It 'throws when dir exists but has no build.ninja' {
        $emptyDir = Join-Path $TestDrive 'empty-pg_tde-build'
        New-Item -ItemType Directory -Path $emptyDir | Out-Null
        { & $script:BuildScript -BuildDir $emptyDir } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }
}
