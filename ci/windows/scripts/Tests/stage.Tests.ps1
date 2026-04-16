BeforeAll {
    $script:StageScript = Join-Path $PSScriptRoot '../stage.ps1'
}

Describe 'stage.ps1' {
    It 'throws when build.ninja is missing' {
        { & $script:StageScript -DestDir (Join-Path $TestDrive 'stage') -BuildDir (Join-Path $TestDrive 'no-build') } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It 'throws with configure hint when dir exists but has no build.ninja' {
        $emptyBuild = Join-Path $TestDrive 'empty-build'
        New-Item -ItemType Directory -Path $emptyBuild | Out-Null
        { & $script:StageScript -DestDir (Join-Path $TestDrive 'stage') -BuildDir $emptyBuild } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It 'warns (not throws) when postgres.exe is not present after install' {
        # -WhatIf skips the meson install call, so no postgres.exe will exist and
        # the DLL-copy step should emit a warning rather than crash the script.
        $build = Join-Path $TestDrive 'fake-build'
        New-Item -ItemType Directory -Path $build | Out-Null
        New-Item -ItemType File -Path (Join-Path $build 'build.ninja') | Out-Null
        $dest = Join-Path $TestDrive 'fake-stage'

        { & $script:StageScript -DestDir $dest -BuildDir $build -WhatIf `
            -WarningAction SilentlyContinue } | Should -Not -Throw
    }
}
