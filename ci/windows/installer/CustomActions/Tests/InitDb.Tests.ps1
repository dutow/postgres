Describe "InitDb.ps1" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "../InitDb.ps1"
    }

    It "throws when BinDir does not contain initdb.exe" {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            { & $ScriptPath -BinDir $tmp -DataDir "C:/tmp/d" -Password "secret12" } |
                Should -Throw -ExpectedMessage "initdb.exe not found*"
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }

    It "shreds the pwfile after a failed initdb invocation" {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            # Stub initdb.exe — a small batch file that always exits non-zero, renamed .exe
            # Windows will reject .bat-as-.exe execution, but the script will throw early
            # with a non-zero $LASTEXITCODE, which is the path we want to exercise.
            $stub = Join-Path $tmp "initdb.exe"
            "@echo off`nexit /b 42" | Set-Content -Path $stub -Encoding ASCII
            $beforeCount = (Get-ChildItem ([IO.Path]::GetTempPath()) -Filter "pgpw-*.txt" -ErrorAction SilentlyContinue).Count
            try {
                & $ScriptPath -BinDir $tmp -DataDir "C:/tmp/d" -Password "x" 2>&1 | Out-Null
            } catch { }
            $afterCount = (Get-ChildItem ([IO.Path]::GetTempPath()) -Filter "pgpw-*.txt" -ErrorAction SilentlyContinue).Count
            $afterCount | Should -Be $beforeCount
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }
}
