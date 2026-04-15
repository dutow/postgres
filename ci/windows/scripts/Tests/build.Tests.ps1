BeforeAll {
    $script:BuildScript = Join-Path $PSScriptRoot '../build.ps1'
}

Describe 'build.ps1' {
    It 'throws when build.ninja is missing' {
        { & $script:BuildScript -BuildDir (Join-Path $TestDrive 'no-such-dir') } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It 'throws with configure hint when directory exists but has no build.ninja' {
        $emptyDir = Join-Path $TestDrive 'empty-build'
        New-Item -ItemType Directory -Path $emptyDir | Out-Null
        { & $script:BuildScript -BuildDir $emptyDir } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }
}
