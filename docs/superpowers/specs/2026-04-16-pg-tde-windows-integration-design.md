# pg_tde in the Windows build — design

**Date:** 2026-04-16
**Status:** Draft, awaiting implementation plan
**Related:** [2026-04-15 Windows CI & installer design](2026-04-15-windows-ci-installer-design.md)

## Goal

Add the `pg_tde` PostgreSQL extension (from `https://github.com/percona/pg_tde`, `main` branch) to the Windows build so that `pg_tde.dll`, its SQL/control files, and its frontend tools ship inside the same MSI as Percona Server for PostgreSQL 18. pg_tde lives in a separate git repository; we do not vendor or submodule it — CI checks it out on the fly, and local developers clone it manually next to the PG repo.

## Constraints

- pg_tde's `meson.build` is an out-of-tree build that discovers PostgreSQL via `pg_config`. It therefore needs a fully installed PG tree to build against.
- pg_tde bundles its own copies of PG frontend sources under `fetools/pg17/` and `fetools/pg18/`; it does not reach into the PG source tree.
- pg_tde requires: `libcrypto`, `libssl`, `libcurl`, `zlib`. Optional: `liblz4`, `libzstd`. Everything except `libcurl` is already in `ci/windows/vcpkg.json`.
- The existing Windows build stages PG into `C:/stage` via `meson install --destdir`, then WiX heat-harvests that prefix into `StagedFiles`. The existing flow must keep working unchanged if pg_tde is absent.
- pg_tde's TAP tests spin up a live PostgreSQL and some exercise external key services (KMIP, Vault). On this branch the main PG test step is already `continue-on-error`; we adopt the same policy for pg_tde.

## Decisions

1. **Source acquisition — GitHub Actions checkout, no helper.** CI runs a second `actions/checkout@v4` with `repository: percona/pg_tde`, `ref: main`, `path: pg_tde`. Local developers clone the repo themselves. No fetch/sync PowerShell helper.
2. **Source location — sibling directory.** In CI, pg_tde ends up at `$GITHUB_WORKSPACE/pg_tde`. Locally the default is `../pg_tde` relative to the PG repo root; every helper accepts a `-SourceDir` parameter to override.
3. **Tests — full TAP suite, `continue-on-error`.** We want to see pg_tde-specific failures on Windows without blocking the build.
4. **Installer — always bundled, no feature toggle.** pg_tde files merge into the existing `StagedFiles` component group via the same `wix heat` harvest.
5. **No repo changes to pg_tde source.** The PG repo does not add a submodule, a vendored copy, or a `.gitmodules` entry for pg_tde.

## Architecture

### Build ordering

```
PG configure → PG build → PG test → PG stage (populates C:/stage)
                                        │
                                        ▼
                pg_tde configure (uses staged pg_config)
                                        │
                                        ▼
                              pg_tde build
                                        │
                                        ▼
                        pg_tde test (continue-on-error)
                                        │
                                        ▼
               pg_tde stage  →  meson install --destdir C:/stage
                                        │
                                        ▼
                      wix heat harvest (merged tree)
                                        │
                                        ▼
                              wix build (MSI)
```

`pg_tde stage` installs into the **same** `C:/stage` prefix already populated by `stage.ps1`. That produces a merged tree with `pg_tde.dll` alongside PG's extension DLLs, pg_tde's frontend exes in `bin/`, and pg_tde's `.sql`/`.control` files under `share/extension/`. The existing harvest picks everything up with no WXS edits.

### Helper scripts

New directory `ci/windows/scripts/pg_tde/` with four helpers. Names mirror the top-level scripts but live in a subfolder to keep the top level readable as more extensions are added.

- **`configure.ps1`**
  Runs `meson setup <pg_tde_build_dir>` on the pg_tde source.
  - Parameters: `-SourceDir` (default `../pg_tde` resolved relative to the PG repo root), `-BuildDir` (default `pg_tde_build`), `-StagePrefix` (the PG stage root; required — this is how we find `pg_config.exe`), `-MesonArgs`.
  - Locates `pg_config.exe` under `<StagePrefix>/bin/` and passes it via `-Dpg_config=`.
  - Dot-sources `../vcpkg.ps1` to reuse `Get-VcpkgInstallRoot` / `Add-VcpkgBinToPath`, and passes `--pkg-config-path` / `--cmake-prefix-path` identically to the main `configure.ps1`.
  - Returns `PSCustomObject` with `SourceDir`, `BuildDir`, `PgConfig`.

- **`build.ps1`**
  `ninja -C <pg_tde_build_dir>`. Minimal — mirrors top-level `build.ps1`.

- **`test.ps1`**
  `meson test -C <pg_tde_build_dir> --print-errorlogs` with `-NumProcesses`, `-TimeoutMultiplier`, `-Suite`, `-MesonArgs`. Returns `$LASTEXITCODE`; does not throw. Caller decides whether to fail the build.
  - Ensures vcpkg bin is on PATH so the pg_tde test harness can load the runtime DLLs (curl, crypto, ssl, etc.).

- **`stage.ps1`**
  `meson install -C <pg_tde_build_dir> --destdir <DestDir>`. Does **not** copy runtime DLLs — the main `stage.ps1` already copied them into `<DestDir>/.../bin/` when it staged PG. Parameters: `-DestDir` (required), `-BuildDir` (default `pg_tde_build`).

### Pester tests

`ci/windows/scripts/pg_tde/Tests/` holds Pester unit tests for the four helpers, matching the pattern already used for top-level scripts. The existing CI Pester step uses a `-Path` list; we extend it to include the new folder. Tests should cover: parameter validation, pg_config discovery failure modes (missing stage, missing pg_config.exe), and the "happy path" mock of `meson` invocation.

### vcpkg manifest

Add `"curl"` to the `dependencies` array in `ci/windows/vcpkg.json`. Triplet and baseline are unchanged.

### CI workflow (`.github/workflows/windows-build.yml`)

Changes, in order:

1. **New early step — "Checkout pg_tde"**, placed directly after the main "Checkout" step:
   ```yaml
   - name: Checkout pg_tde
     uses: actions/checkout@v4
     with:
       repository: percona/pg_tde
       ref: main
       path: pg_tde
   ```
2. **Pester step** — add `ci/windows/scripts/pg_tde/Tests` to the `-Path` list.
3. **pg_tde configure/build/test/stage**, inserted between "Stage install tree" and "Install WiX 5":
   - "Configure pg_tde" — runs `./ci/windows/scripts/pg_tde/configure.ps1 -SourceDir $env:GITHUB_WORKSPACE/pg_tde -StagePrefix C:/stage` (the step resolves the actual stage prefix the same way the existing "Locate staged prefix" step does, or reuses that step's output — see Open question O1).
   - "Build pg_tde" — `./ci/windows/scripts/pg_tde/build.ps1`.
   - "Test pg_tde" — `continue-on-error: true`, `timeout-minutes: 30`, runs `./ci/windows/scripts/pg_tde/test.ps1`.
   - "Stage pg_tde" — `./ci/windows/scripts/pg_tde/stage.ps1 -DestDir C:/stage`.
4. **Test-logs artifact upload** — extend the `path:` list to include `pg_tde_build/meson-logs/`, `pg_tde_build/testrun/**/log/**`, `pg_tde_build/testrun/**/regress_log/**`.

The "Locate staged prefix" and everything downstream (harvest → MSI → upload) stay as-is.

### Documentation

`ci/windows/README.md` gets a new "pg_tde" section:

- One-time clone instruction: `git clone https://github.com/percona/pg_tde.git ../pg_tde`
- Local iteration commands:
  ```powershell
  ./ci/windows/scripts/pg_tde/configure.ps1 -StagePrefix C:/pgsql-stage
  ./ci/windows/scripts/pg_tde/build.ps1
  ./ci/windows/scripts/pg_tde/test.ps1
  ./ci/windows/scripts/pg_tde/stage.ps1 -DestDir C:/pgsql-local-stage
  ```
- Note: CI checks out `main` automatically; local developers pull updates themselves.

## Out of scope

- No MSI feature toggle for pg_tde (always bundled).
- No auto-registration of `pg_tde` in `shared_preload_libraries` — operators enable it post-install.
- No changes to the MSI product name, upgrade code, or version scheme. pg_tde's own version string is recorded only via the installed `pg_tde.control` file.
- No packaging of pg_tde documentation into the MSI.
- No pinning of the pg_tde ref — CI always builds `main`. (Pinning, if needed later, is a separate change.)
- No vendoring and no submodule.

## Open questions

- **O1:** Should the "Configure pg_tde" workflow step reuse the existing `Locate staged prefix` step's `outputs.prefix`, or re-discover the prefix itself for symmetry with the local-dev flow? Leaning **reuse** in CI to avoid redundant filesystem walks; `configure.ps1` still supports direct `-StagePrefix` for local use.
- **O2:** pg_tde's TAP tests that depend on external services (KMIP, Vault) — do they need additional setup in the Windows runner, or do they gracefully skip when those services aren't available? The answer may surface during first CI run; `continue-on-error` means a failing subset doesn't block merge while we investigate.

## Verification

After implementation, a green CI run must produce an MSI that, when installed on a clean Windows box, contains (at minimum):

- `lib\pg_tde.dll` (the extension module) and 9 `pg_tde_*.exe` frontend tools under `bin\`: `pg_tde_upgrade`, `pg_tde_basebackup`, `pg_tde_waldump`, `pg_tde_resetwal`, `pg_tde_rewind`, `pg_tde_checksums`, `pg_tde_change_key_provider`, `pg_tde_archive_decrypt`, `pg_tde_restore_encrypt`.
- `share\extension\pg_tde.control`
- `share\extension\pg_tde--1.0.sql`, `pg_tde--1.0--2.0.sql`, `pg_tde--2.0--2.1.sql`
- Runtime DLLs including `libcurl.dll` alongside the existing crypto/ssl/xml2/etc.

Post-install, `CREATE EXTENSION pg_tde;` from `psql` must succeed against a database started from the installer.
