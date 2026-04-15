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

Prerequisites (install once):
- Visual Studio 2022 with "Desktop development with C++" (MSVC v14.4+).
- PowerShell 7 (`pwsh`).
- Python 3 + `pip install meson ninja`.
- `choco install winflexbison3 pkgconfiglite`.
- vcpkg cloned somewhere with `VCPKG_ROOT` pointing at it.

Build the dependencies once, from the repo root:

```powershell
vcpkg install --x-manifest-root=ci/windows --triplet x64-windows
```

Then iterate:

```powershell
./ci/windows/scripts/configure.ps1 -ExtraVersion "-local"
./ci/windows/scripts/build.ps1
./ci/windows/scripts/test.ps1                        # fast feedback (timeout-multiplier 0.3)
./ci/windows/scripts/test.ps1 -TimeoutMultiplier 1   # full-timeout run
./ci/windows/scripts/test.ps1 -Suite regress         # single suite
./ci/windows/scripts/stage.ps1 -DestDir C:/pgsql-local-stage
```

Run the script-level unit tests:

```powershell
Invoke-Pester ci/windows/scripts/Tests
```

## Branding

`installer/Banner.bmp` and `installer/Dialog.bmp` are placeholder images. Replace with real Percona branding before shipping a non-testing build. See `installer/README.md` for required dimensions.
