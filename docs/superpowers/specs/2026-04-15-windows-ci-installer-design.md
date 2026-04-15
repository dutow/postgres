# Windows CI & MSI installer — Design

**Date:** 2026-04-15
**Scope:** Percona Server for PostgreSQL 18 (branch `PSP_REL_18_STABLE`)
**Status:** Design approved; ready for implementation planning.

## Goal

Produce a GitHub Actions workflow that, for every commit on `PSP_REL_*` branches (and on tag pushes, and on opt-in PRs), builds Percona Server for PostgreSQL on Windows with MSVC, runs the test suite, packages the result as a WiX-built MSI with an EDB-style interactive wizard, smoke-tests the MSI, and publishes it as a workflow artifact plus a rolling nightly release (and a proper GitHub Release on tags).

This is the first iteration. It establishes the pipeline so every commit yields a testable installer. Subsequent iterations can add `pg_tde`, additional PL languages, ARM64, pgAdmin bundling, real Authenticode signing with a production certificate, and external artifact distribution.

## Non-goals

- Migrating existing Cirrus CI to GitHub Actions. Cirrus remains upstream CI; this workflow runs alongside it.
- Bundling `pg_tde`. The contrib submodule is not currently present and Windows support for it is a separate workstream.
- Bundling `plperl`, `plpython`, `pltcl`. Each requires a full language runtime and is deferred.
- ARM64 Windows. Structure allows adding a matrix entry later; not shipped in v1.
- pgAdmin, StackBuilder, or other EDB-bundle components.
- Cross-major version upgrades inside the installer (no `pg_upgrade` integration in v1).
- External artifact distribution (S3, Percona package server). Workflow artifacts + GitHub Releases only.

## Foundational decisions

| Area | Decision |
|------|----------|
| CI system | GitHub Actions alongside existing Cirrus CI (Cirrus is upstream; we do not modify it) |
| Installer scope | Server + interactive setup wizard (initdb, service registration). No pg_tde, no pgAdmin |
| Installer technology | WiX Toolset → MSI (enterprise deployment target: GPO-friendly) |
| Build toolchain | MSVC (Visual Studio 2022) + meson + ninja |
| Dependency management | vcpkg manifest mode, dynamic triplet `x64-windows`, baseline-pinned |
| Target architecture | x64 only (v1) |
| Code signing | Optional via GHA secrets; warn if unset; never sign fork PRs |
| Artifact publication | Workflow artifacts always; `nightly-psp18` rolling release on branch push; proper release on `v*` tag |
| Triggering | Push to `PSP_REL_*`, push of `v*` tags, `workflow_dispatch`, PRs to `PSP_REL_*` only when labeled `needs-windows-installer` |

## Pipeline structure

One workflow file: `.github/workflows/windows-build.yml`.
One job (sequential stages — avoids re-checkout and re-restoring vcpkg between jobs).
Runner: `windows-2022` pinned (not `windows-latest`, for reproducibility).
Job-level timeout: 90 minutes.

Stages:

1. Check out repo (`actions/checkout@v4`, no submodules).
2. Restore vcpkg cache; install deps from `ci/windows/vcpkg.json`.
3. Configure meson (release, Percona extra-version with short SHA).
4. Build with `ninja -C build` (default target — full build).
5. Run `meson test -C build --num-processes 4 --print-errorlogs`. On failure, upload test logs and fail the job.
6. Stage install tree (`meson install --destdir stage`).
7. Build MSI with WiX from `ci/windows/installer/`.
8. Sign MSI if signing secrets present; otherwise emit a warning and continue.
9. Smoke-test the MSI (silent install → verify → uninstall).
10. Upload MSI as workflow artifact (always).
11. Publish to release if triggered by branch push (nightly) or tag (versioned).

Any stage failure fails the job. A failed smoke test blocks publish.

## Build configuration

### vcpkg manifest (`ci/windows/vcpkg.json`)

Deps: `openssl`, `icu`, `zlib`, `zstd`, `lz4`, `libxml2`, `libxslt`, `openldap`.
Triplet: `x64-windows` (dynamic). Rationale: clearer security-servicing story (replace a single dep DLL for a CVE), matches EDB convention, aligns with enterprise expectations.
Baseline: pinned `builtin-baseline` commit for deterministic dep versions.

### Meson setup

Approximate form:

```
meson setup build `
  --buildtype=release `
  --prefix=C:/stage/pgsql `
  -Dssl=openssl -Dicu=enabled -Dzlib=enabled `
  -Dzstd=enabled -Dlz4=enabled `
  -Dlibxml=enabled -Dlibxslt=enabled -Dldap=enabled `
  -Dplperl=disabled -Dplpython=disabled -Dpltcl=disabled `
  -Dextra_version=-psp-<shortsha>
```

`extra_version` embeds the commit in `SELECT version()` output for traceability.

### Caching

- vcpkg binary cache: `actions/cache`, keyed on `vcpkg.json` hash + baseline commit.
- Compiler cache: `sccache`, keyed on compiler + meson config hash; restored across commits on the same branch.

## Test stage

- Command: `meson test -C build --num-processes 4 --print-errorlogs`.
- Covers: regress, isolation, TAP, contrib tests for enabled contribs.
- Concurrency: 4 processes. Higher counts on GHA Windows runners produce timing-sensitive flakes; this matches the Cirrus MinGW task's rationale.
- Failure: fails the job, blocks packaging.
- On failure: upload `build/meson-logs/testlog.txt` and any `crashlog-*.txt` / core files as `test-logs-<sha>`.
- Flaky tests: none pre-excluded. Triage and add targeted skips only if a specific test proves chronically flaky on GHA but passes on Cirrus.

## MSI / WiX installer

### Source layout (`ci/windows/installer/`)

- `Product.wxs` — core MSI definition: product code, upgrade code, features, components.
- `UI.wxs` — custom wizard pages.
- `CustomActions/` — custom actions for initdb, service registration, service start/stop.
- `License.rtf`, `Banner.bmp`, `Dialog.bmp` — branding assets (Percona placeholders in v1).
- `README.md` — documents required branding-asset swap before non-testing use.

`Files.wxs` is generated at build time from the staged install tree via `heat.exe`, not checked in.

### Wizard pages

1. Welcome.
2. License agreement.
3. Installation directory. Default: `C:\Program Files\Percona\PostgreSQL\18`.
4. Data directory. Default: `C:\Program Files\Percona\PostgreSQL\18\data`.
5. Superuser password (with confirm field; required).
6. Service port. Default: `5432`.
7. Locale (dropdown; default "Default locale").
8. Ready to install → progress → finish.

### Install-time custom actions (deferred, elevated)

1. `initdb.exe -D <datadir> -U postgres --pwfile=<temp>` then securely delete the temp file.
2. Register Windows service `postgresql-psp-18` via `pg_ctl register -N postgresql-psp-18 -D <datadir> -S auto`, running as `NT AUTHORITY\NetworkService`.
3. Start the service; verify via `pg_isready` within 30s. Roll back install on failure.

### Uninstall

- Stop and unregister the service.
- Leave the data directory in place by default (matches EDB; accidental data loss is worse than orphan files).
- Checkbox on finish-uninstall screen allows requesting data-directory removal.

### Upgrade handling

- `MajorUpgrade` element with `DowngradeErrorMessage`.
- Same-major upgrade: replace binaries in place, leave data untouched.
- Cross-major upgrade: **not supported in v1**. User must uninstall the old major and restore via pg_dump or manually-invoked `pg_upgrade`.
- `UpgradeCode`: one fixed GUID per major version. PostgreSQL 18 gets one GUID; 19 will get another when the time comes.

## Signing & publication

### Signing (conditional)

GHA secrets:
- `SIGNING_CERT_PFX_BASE64` — base64-encoded PFX.
- `SIGNING_CERT_PASSWORD` — PFX password.

Behavior:
- If both secrets present: decode PFX to a temp file, run `signtool sign /f cert.pfx /p $pw /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 <msi>`, then securely delete the temp file. Signing failure fails the job.
- If either missing: emit `::warning::MSI is unsigned (signing secrets not configured)` and continue.
- PRs from forks never sign, with an explicit guard (GHA already withholds secrets from fork PRs, but we belt-and-brace).

### Artifact naming

- Branch/PR builds: `percona-postgresql-18-<version>-<shortsha>-x64.msi`.
- Tag builds: `percona-postgresql-18-<tag>-x64.msi` (where `<tag>` is the pushed tag, e.g. `v18.3.0-psp1`).
- `<version>` read from the `version:` argument of `project()` in `meson.build`.
- `<shortsha>` = first 7 chars of the commit.

### Workflow artifact upload (always)

- `actions/upload-artifact@v4`.
- Contents: MSI + `build-info.json` (commit sha, build timestamp, vcpkg baseline, meson options, test summary).
- Retention: 30 days.

### Nightly rolling release (push to `PSP_REL_*`)

- Tag derived from branch: `PSP_REL_18_STABLE` → `nightly-psp18`.
- On each push: delete existing release and tag if present, recreate with new MSI attached, marked **pre-release**, release notes = `<shortsha> <commit subject>` + commit link.
- Tool: `softprops/action-gh-release@v2`.

### Tagged release (push of `v*` tag)

- Creates a proper GitHub Release, not pre-release, named after the tag.
- Release notes: auto-generated from commits since the previous `v*` tag.
- `draft: false`.

### Failure behavior

- Signing failure → job fails.
- Workflow artifact upload failure → job fails.
- Release publish failure → job fails; artifacts remain attached to the workflow run.

## Installer smoke test

Runs inside the same job, immediately after signing, before publish:

```powershell
msiexec /i $msi /qn /l*v install.log `
  INSTALLDIR="C:\smoketest\pgsql" `
  DATADIR="C:\smoketest\data" `
  PGPORT=5433 PGPASSWORD=<random>
& "C:\smoketest\pgsql\bin\pg_isready.exe" -p 5433
$env:PGPASSWORD=<random>
& "C:\smoketest\pgsql\bin\psql.exe" -p 5433 -U postgres -c "SELECT version();"
msiexec /x $msi /qn /l*v uninstall.log
sc.exe query postgresql-psp-18  # must fail with "does not exist"
```

- Runs on every build (commit, labeled PR, tag, dispatch).
- Non-default port `5433` to avoid runner-image collisions.
- Random password generated per-run via `System.Security.Cryptography.RandomNumberGenerator` (32 bytes, base64-encoded), passed through environment variables only, never echoed to logs.
- Smoke-test failure fails the job and blocks publish.
- Install/uninstall logs uploaded as workflow artifact **on failure only**.

Adds ~2 minutes per build. Catches MSI-structural bugs (missing files, broken custom actions, service registration glitches) that meson tests cannot see.

## Files this introduces

- `.github/workflows/windows-build.yml`
- `ci/windows/vcpkg.json` and `vcpkg-configuration.json`
- `ci/windows/installer/Product.wxs`
- `ci/windows/installer/UI.wxs`
- `ci/windows/installer/CustomActions/` (initdb runner, service registration, smoke helpers)
- `ci/windows/installer/License.rtf`
- `ci/windows/installer/Banner.bmp`, `Dialog.bmp`
- `ci/windows/installer/README.md`
- `ci/windows/scripts/` (PowerShell helpers: `configure.ps1`, `build.ps1`, `stage.ps1`, `smoke-test.ps1`, `sign.ps1`, `publish-nightly.ps1`)

Rationale for the split: the workflow YAML stays readable by calling out to PowerShell scripts for each stage; scripts are testable in isolation (a developer can run `stage.ps1` locally after a meson build) and keep the workflow file from becoming a 400-line YAML blob.

## Follow-on work (deferred; not in this spec)

- `pg_tde` bundling once its Windows port lands.
- PL language bundling (`plperl`, `plpython`, `pltcl`).
- ARM64 Windows as a second matrix entry.
- Real code-signing certificate provisioning (once available).
- pgAdmin / StackBuilder bundling.
- External artifact distribution (S3 / Percona package server).
- `pg_upgrade` integration in the installer for cross-major upgrades.
- Real Percona branding assets (replace placeholders).
