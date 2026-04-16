<#
.SYNOPSIS
    Run initdb.exe with a password supplied via a temp pwfile.

.NOTES
    The pwfile is written to a random path under %TEMP%, handed to initdb,
    then overwritten with zeros and deleted in a finally block — regardless
    of whether initdb succeeded. Passing the password via env or argv would
    leak it to process-listing tools or event logs; pwfile is the only safe
    mechanism on Windows.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BinDir,
    [Parameter(Mandatory)][string]$DataDir,
    [Parameter(Mandatory)][string]$Password,
    [string]$Locale = "",
    [string]$Superuser = "postgres",
    [string]$Encoding = "UTF8"
)

$ErrorActionPreference = "Stop"

$initdb = Join-Path $BinDir "initdb.exe"
if (-not (Test-Path $initdb)) { throw "initdb.exe not found at $initdb" }

$pwfile = Join-Path ([IO.Path]::GetTempPath()) ("pgpw-" + [Guid]::NewGuid().ToString("N") + ".txt")
try {
    [IO.File]::WriteAllText($pwfile, $Password, [Text.UTF8Encoding]::new($false))

    $argList = @(
        "-D", $DataDir,
        "-U", $Superuser,
        "--pwfile=$pwfile",
        "-E", $Encoding,
        "--auth-local=scram-sha-256",
        "--auth-host=scram-sha-256"
    )
    if ($Locale) { $argList += @("--locale=$Locale") }

    & $initdb @argList
    if ($LASTEXITCODE -ne 0) { throw "initdb failed with exit code $LASTEXITCODE" }
}
finally {
    if (Test-Path $pwfile) {
        try {
            $bytes = New-Object byte[] 4096
            [IO.File]::WriteAllBytes($pwfile, $bytes)
        } catch {}
        Remove-Item $pwfile -Force -ErrorAction SilentlyContinue
    }
}
