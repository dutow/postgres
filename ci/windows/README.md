# Windows CI & Installer

This directory contains everything specific to the Windows build and MSI installer pipeline.

## Layout

- `vcpkg.json`, `vcpkg-configuration.json` — dependency manifest (pinned baseline).
- `scripts/` — PowerShell helpers used by the GitHub Actions workflow and runnable locally on Windows.
  - `scripts/Tests/` — Pester unit tests for the scripts.
- `installer/` — WiX 5 sources for the MSI.
  - `installer/CustomActions/` — PowerShell custom-action scripts invoked during install/uninstall.
  - `installer/CustomActions/Tests/` — Pester unit tests for the custom actions.

## Running locally (Windows only)

On a Windows machine with Visual Studio 2022, vcpkg, meson, ninja, WiX 5, and PowerShell 7 installed:

```powershell
./scripts/configure.ps1
./scripts/build.ps1
./scripts/stage.ps1 -DestDir C:/stage
# Then build the MSI from ci/windows/installer.
```

See `.github/workflows/windows-build.yml` for the authoritative pipeline.

## Branding

`installer/Banner.bmp` and `installer/Dialog.bmp` are placeholder images. Replace with real Percona branding before shipping a non-testing build. See `installer/README.md` for required dimensions.
