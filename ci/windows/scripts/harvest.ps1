<#
.SYNOPSIS
    Generate a WiX v4 Files.wxs from a staged directory tree.
    Replaces `wix heat dir` which was removed in WiX 5.
.PARAMETER StageDir
    Root directory to harvest.
.PARAMETER ComponentGroup
    Name of the ComponentGroup element (default: StagedFiles).
.PARAMETER DirectoryRef
    Directory reference ID for the root (default: INSTALLDIR_).
.PARAMETER VarName
    WiX variable name for the source path (default: StageDir).
.PARAMETER OutFile
    Path to write the generated .wxs file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StageDir,
    [string]$ComponentGroup = 'StagedFiles',
    [string]$DirectoryRef   = 'INSTALLDIR_',
    [string]$VarName        = 'StageDir',
    [Parameter(Mandatory)][string]$OutFile
)

$ErrorActionPreference = "Stop"

$StageDir = (Resolve-Path $StageDir).Path.TrimEnd('\', '/')

# Collect every file under StageDir
$files = Get-ChildItem -Path $StageDir -Recurse -File | Sort-Object FullName

# Build a set of directories that contain files (directly or indirectly)
$dirs = @{}
foreach ($f in $files) {
    $rel = $f.DirectoryName.Substring($StageDir.Length).TrimStart('\', '/')
    if ($rel -eq '') { continue }
    # Register this dir and all ancestors
    $parts = $rel -split '[\\\/]'
    for ($i = 1; $i -le $parts.Count; $i++) {
        $ancestor = ($parts[0..($i-1)]) -join '\'
        $dirs[$ancestor] = $true
    }
}

# Deterministic ID from a relative path
function Make-Id([string]$prefix, [string]$relPath) {
    # Preserve +/- distinctly so paths like Etc/GMT+3 vs Etc/GMT-3 don't collide
    $safe = $relPath -replace '\+', 'P' -replace '-', 'M' -replace '[^A-Za-z0-9._]', '_'
    # WiX IDs must start with a letter or underscore and be <= 72 chars
    $id = "${prefix}_${safe}"
    if ($id.Length -gt 72) {
        $hash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                [System.Text.Encoding]::UTF8.GetBytes($relPath)
            )
        ).Replace('-','').Substring(0,16)
        $id = "${prefix}_${hash}"
    }
    return $id
}

$xml = [System.Xml.XmlDocument]::new()
$xml.AppendChild($xml.CreateXmlDeclaration("1.0", "UTF-8", $null)) | Out-Null

$ns = "http://wixtoolset.org/schemas/v4/wxs"
$wix = $xml.CreateElement("Wix", $ns)
$xml.AppendChild($wix) | Out-Null

$fragment = $xml.CreateElement("Fragment", $ns)
$wix.AppendChild($fragment) | Out-Null

# DirectoryRef for root
$rootRef = $xml.CreateElement("DirectoryRef", $ns)
$rootRef.SetAttribute("Id", $DirectoryRef)
$fragment.AppendChild($rootRef) | Out-Null

# Create nested Directory elements
$dirElements = @{ '' = $rootRef }
foreach ($d in ($dirs.Keys | Sort-Object)) {
    if ($d.Contains('\')) {
        $parentPath = $d.Substring(0, $d.LastIndexOf('\'))
        $name = $d.Substring($d.LastIndexOf('\') + 1)
    } else {
        $parentPath = ''
        $name = $d
    }
    $dirEl = $xml.CreateElement("Directory", $ns)
    $dirEl.SetAttribute("Id", (Make-Id "dir" $d))
    $dirEl.SetAttribute("Name", $name)
    $dirElements[$parentPath].AppendChild($dirEl) | Out-Null
    $dirElements[$d] = $dirEl
}

# ComponentGroup
$cg = $xml.CreateElement("ComponentGroup", $ns)
$cg.SetAttribute("Id", $ComponentGroup)
$fragment.AppendChild($cg) | Out-Null

# One Component per file
foreach ($f in $files) {
    $relFile = $f.FullName.Substring($StageDir.Length).TrimStart('\', '/')
    $relDir  = $f.DirectoryName.Substring($StageDir.Length).TrimStart('\', '/')

    $compId = Make-Id "cmp" $relFile
    $fileId = Make-Id "fil" $relFile

    $comp = $xml.CreateElement("Component", $ns)
    $comp.SetAttribute("Id", $compId)
    $comp.SetAttribute("Guid", [Guid]::NewGuid().ToString("D"))
    $dirId = if ($relDir -eq '') { $DirectoryRef } else { Make-Id "dir" $relDir }
    $comp.SetAttribute("Directory", $dirId)

    $fileEl = $xml.CreateElement("File", $ns)
    $fileEl.SetAttribute("Id", $fileId)
    $fileEl.SetAttribute("Name", $f.Name)
    $fileEl.SetAttribute("KeyPath", "yes")
    $fileEl.SetAttribute("Source", "`$(var.$VarName)\$relFile")

    $comp.AppendChild($fileEl) | Out-Null
    $cg.AppendChild($comp) | Out-Null
}

# Write with UTF-8 (no BOM)
$settings = [System.Xml.XmlWriterSettings]::new()
$settings.Indent = $true
$settings.IndentChars = "  "
$settings.Encoding = [System.Text.UTF8Encoding]::new($false)

$outPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
$writer = [System.Xml.XmlWriter]::Create($outPath, $settings)
$xml.Save($writer)
$writer.Close()

Write-Host "Harvested $($files.Count) files into $outPath"
