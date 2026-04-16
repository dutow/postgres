BeforeAll {
    . (Join-Path $PSScriptRoot '../vcpkg.ps1')
}

Describe 'Get-VcpkgInstallRoot' {
    BeforeEach {
        $script:savedEnv = @{
            VCPKG_INSTALLED_DIR        = $env:VCPKG_INSTALLED_DIR
            VCPKG_MANIFEST_INSTALL_DIR = $env:VCPKG_MANIFEST_INSTALL_DIR
            GITHUB_WORKSPACE           = $env:GITHUB_WORKSPACE
            RUNNER_TEMP                = $env:RUNNER_TEMP
        }
        $env:VCPKG_INSTALLED_DIR        = $null
        $env:VCPKG_MANIFEST_INSTALL_DIR = $null
        $env:GITHUB_WORKSPACE           = $null
        $env:RUNNER_TEMP                = $null
    }

    AfterEach {
        $env:VCPKG_INSTALLED_DIR        = $script:savedEnv.VCPKG_INSTALLED_DIR
        $env:VCPKG_MANIFEST_INSTALL_DIR = $script:savedEnv.VCPKG_MANIFEST_INSTALL_DIR
        $env:GITHUB_WORKSPACE           = $script:savedEnv.GITHUB_WORKSPACE
        $env:RUNNER_TEMP                = $script:savedEnv.RUNNER_TEMP
    }

    It 'throws with clear message when nothing is discoverable' {
        Push-Location $TestDrive
        try {
            { Get-VcpkgInstallRoot } | Should -Throw -ExpectedMessage '*Could not locate vcpkg*'
        } finally {
            Pop-Location
        }
    }

    It 'resolves via VCPKG_INSTALLED_DIR when it points at the triplet parent' {
        $root = Join-Path $TestDrive 'vcpkg-a'
        New-Item -ItemType Directory -Path (Join-Path $root 'x64-windows/lib/pkgconfig') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'x64-windows/bin') -Force | Out-Null
        $env:VCPKG_INSTALLED_DIR = $root

        $result = Get-VcpkgInstallRoot
        $result.InstallRoot   | Should -Be (Join-Path $root 'x64-windows')
        $result.BinDir        | Should -Be (Join-Path (Join-Path $root 'x64-windows') 'bin')
        $result.PkgConfigPath | Should -Be (Join-Path (Join-Path $root 'x64-windows') 'lib/pkgconfig')
    }

    It 'resolves via VCPKG_INSTALLED_DIR when it points directly at the triplet' {
        $root = Join-Path $TestDrive 'vcpkg-b'
        New-Item -ItemType Directory -Path (Join-Path $root 'lib/pkgconfig') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
        $env:VCPKG_INSTALLED_DIR = $root

        (Get-VcpkgInstallRoot).InstallRoot | Should -Be $root
    }

    It 'falls back to recursive search under GITHUB_WORKSPACE' {
        $ws = Join-Path $TestDrive 'ws'
        $tripletRoot = Join-Path $ws 'sub/vcpkg_installed/x64-windows'
        New-Item -ItemType Directory -Path (Join-Path $tripletRoot 'lib/pkgconfig') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $tripletRoot 'bin') -Force | Out-Null
        $env:GITHUB_WORKSPACE = $ws

        (Get-VcpkgInstallRoot).InstallRoot | Should -Be $tripletRoot
    }
}

Describe 'Add-VcpkgBinToPath' {
    It 'prepends bin dir to $env:PATH when it exists' {
        $bin = Join-Path $TestDrive 'bin-a'
        New-Item -ItemType Directory -Path $bin | Out-Null
        $savedPath = $env:PATH
        try {
            $env:PATH = 'C:\foo'
            Add-VcpkgBinToPath -BinDir $bin
            $env:PATH | Should -BeLike "$bin*"
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'does not duplicate the bin dir on repeated calls' {
        $bin = Join-Path $TestDrive 'bin-b'
        New-Item -ItemType Directory -Path $bin | Out-Null
        $savedPath = $env:PATH
        try {
            $env:PATH = 'C:\foo'
            Add-VcpkgBinToPath -BinDir $bin
            Add-VcpkgBinToPath -BinDir $bin
            ($env:PATH -split ';' | Where-Object { $_ -eq $bin }).Count | Should -Be 1
        } finally {
            $env:PATH = $savedPath
        }
    }

    It 'warns and skips when the bin dir does not exist' {
        Add-VcpkgBinToPath -BinDir (Join-Path $TestDrive 'missing-bin') `
            -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -BeGreaterThan 0
    }
}
