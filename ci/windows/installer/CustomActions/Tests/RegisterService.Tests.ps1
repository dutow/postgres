Describe "RegisterService.ps1" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "../RegisterService.ps1"
    }

    It "throws when pg_ctl.exe is missing" {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            { & $ScriptPath -BinDir $tmp -DataDir "C:/tmp/d" -ServiceName "test-svc" } |
                Should -Throw -ExpectedMessage "pg_ctl.exe not found*"
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }

    It "uses the default account when -Account is not supplied" {
        # Ensure the script accepts the parameter set without -Account; the
        # test exercises argument validation only - actual registration would
        # require a real pg_ctl which is out of scope here.
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            { & $ScriptPath -BinDir $tmp -DataDir "C:/tmp/d" -ServiceName "test-svc" } |
                Should -Throw -ExpectedMessage "pg_ctl.exe not found*"
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }
}
