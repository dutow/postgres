BeforeAll {
    $script:ConfigureScript = Join-Path $PSScriptRoot '../configure.ps1'
}

Describe 'pg_tde/configure.ps1' {
    It 'throws when -StagePrefix is omitted' {
        { & $script:ConfigureScript -SourceDir $TestDrive } |
            Should -Throw -ExpectedMessage '*StagePrefix*'
    }

    It 'throws when pg_config.exe is missing under StagePrefix/bin' {
        $stage = Join-Path $TestDrive 'empty-stage'
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        $src = Join-Path $TestDrive 'src'
        New-Item -ItemType Directory -Path $src | Out-Null
        New-Item -ItemType File -Path (Join-Path $src 'meson.build') | Out-Null
        { & $script:ConfigureScript -SourceDir $src -StagePrefix $stage } |
            Should -Throw -ExpectedMessage '*pg_config*'
    }

    It 'throws when SourceDir has no meson.build' {
        $stage = Join-Path $TestDrive 'stage2'
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $stage 'bin/pg_config.exe') | Out-Null
        $src = Join-Path $TestDrive 'src2'
        New-Item -ItemType Directory -Path $src | Out-Null
        { & $script:ConfigureScript -SourceDir $src -StagePrefix $stage } |
            Should -Throw -ExpectedMessage '*meson.build*'
    }

    It '-WhatIf does not create a build.ninja' {
        $stage = Join-Path $TestDrive 'stage3'
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $stage 'bin/pg_config.exe') | Out-Null
        $src = Join-Path $TestDrive 'src3'
        New-Item -ItemType Directory -Path $src | Out-Null
        New-Item -ItemType File -Path (Join-Path $src 'meson.build') | Out-Null
        $build = Join-Path $TestDrive 'build3'

        try {
            & $script:ConfigureScript -SourceDir $src -StagePrefix $stage -BuildDir $build -WhatIf
        } catch {}
        Test-Path (Join-Path $build 'build.ninja') | Should -Be $false
    }
}
