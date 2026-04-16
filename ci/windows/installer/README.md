# MSI installer sources

WiX 5 project. Built by `.github/workflows/windows-build.yml`.

## Layout

- `Product.wxs` — core MSI definition (product code, upgrade code, feature tree, WixUI_InstallDir).
- `License.rtf` — placeholder license.
- `Banner.bmp`, `Dialog.bmp` — placeholder branding (solid Percona burgundy).
- `Files.wxs` — generated at build time by `wix heat`, not checked in.

## Branding placeholders (must replace before shipping non-testing builds)

- `License.rtf` — currently a placeholder. Replace with the real project license text.
- `Banner.bmp` — 493x58, 24-bit BMP. Placeholder is solid Percona burgundy with white text.
- `Dialog.bmp` — 493x312, 24-bit BMP. Placeholder is solid Percona burgundy with white text.

## Local build (Windows only)

After `./ci/windows/scripts/stage.ps1 -DestDir C:/stage`:

```powershell
# Locate the staged binary tree (path-independent of the meson prefix)
$binDir   = Get-ChildItem C:/stage -Recurse -Filter postgres.exe | Select-Object -First 1
$prefix   = $binDir.Directory.Parent.FullName

dotnet tool install --global wix --version 5.0.2
wix extension add -g WixToolset.UI.wixext

wix heat dir $prefix -gg -sfrag -srd `
  -cg StagedFiles -dr INSTALLDIR_ -var var.StageDir `
  -out ci/windows/installer/Files.wxs

wix build ci/windows/installer/Product.wxs ci/windows/installer/Files.wxs `
  -ext WixToolset.UI.wixext `
  -d ProductVersion=18.3.0 `
  -d StageDir=$prefix `
  -o percona-postgresql-18.msi
```
