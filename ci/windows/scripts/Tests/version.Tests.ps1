BeforeAll {
    $script:VersionScript = Join-Path $PSScriptRoot '../version.ps1'
    $script:TempMeson     = Join-Path $TestDrive 'meson.build'
    Set-Content $script:TempMeson "project('postgresql', version: '18.3.0', license: 'PostgreSQL')"
}

Describe 'version.ps1' {
    It 'parses version from meson.build' {
        $r = & $script:VersionScript -MesonBuild $script:TempMeson
        $r.Version | Should -Be '18.3.0'
    }

    It 'builds sha-based artifact name when no tag' {
        $r = & $script:VersionScript -MesonBuild $script:TempMeson -CommitSha 'abcdef1234567'
        $r.ShortSha     | Should -Be 'abcdef1'
        $r.ArtifactName | Should -Be 'percona-postgresql-18-18.3.0-abcdef1-x64.msi'
        $r.MsiVersion   | Should -Be '18.3.0'
    }

    It 'builds tag-based artifact name and strips v-prefix and suffix' {
        $r = & $script:VersionScript -MesonBuild $script:TempMeson -Tag 'v18.3.0-psp1'
        $r.ArtifactName | Should -Be 'percona-postgresql-18-v18.3.0-psp1-x64.msi'
        $r.MsiVersion   | Should -Be '18.3.0'
    }

    It 'throws when meson.build is missing' {
        { & $script:VersionScript -MesonBuild (Join-Path $TestDrive 'no-such-file') } |
            Should -Throw
    }
}
