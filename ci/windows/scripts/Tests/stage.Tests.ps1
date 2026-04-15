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
}
