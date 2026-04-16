BeforeAll {
    $script:StageScript = Join-Path $PSScriptRoot '../stage.ps1'
}

Describe 'pg_tde/stage.ps1' {
    It 'throws when build.ninja is missing (no such dir)' {
        { & $script:StageScript -BuildDir (Join-Path $TestDrive 'no-build') } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It 'throws when dir exists but has no build.ninja' {
        $emptyBuild = Join-Path $TestDrive 'empty-pg_tde-build'
        New-Item -ItemType Directory -Path $emptyBuild | Out-Null
        { & $script:StageScript -BuildDir $emptyBuild } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It '-WhatIf does not invoke meson install' {
        $build = Join-Path $TestDrive 'fake-pg_tde-build'
        New-Item -ItemType Directory -Path $build | Out-Null
        New-Item -ItemType File -Path (Join-Path $build 'build.ninja') | Out-Null
        { & $script:StageScript -BuildDir $build -WhatIf } | Should -Not -Throw
    }
}
