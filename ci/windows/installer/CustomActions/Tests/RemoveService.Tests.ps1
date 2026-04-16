Describe "RemoveService.ps1" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "../RemoveService.ps1"
    }

    It "is idempotent when the service does not exist" {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            $unique = "nonexistent-svc-" + [Guid]::NewGuid().ToString("N").Substring(0,8)
            { & $ScriptPath -BinDir $tmp -ServiceName $unique } | Should -Not -Throw
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }
}
