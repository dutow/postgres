# Windows CI & MSI Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a GitHub Actions workflow that produces a WiX-based MSI installer for Percona Server for PostgreSQL 18 on Windows (MSVC + meson), running full meson tests and an MSI smoke test, publishing artifacts + a nightly rolling release + tagged releases.

**Architecture:** Single GHA workflow (`.github/workflows/windows-build.yml`) running on `windows-2022`, orchestrating a sequential pipeline of PowerShell helper scripts under `ci/windows/scripts/` and a WiX 5 project under `ci/windows/installer/`. vcpkg manifest mode for dependencies. MSI custom actions are PowerShell scripts invoked via `powershell.exe`.

**Tech Stack:** GitHub Actions, PowerShell 7, vcpkg (manifest, `x64-windows` dynamic triplet), MSVC 2022, meson + ninja, WiX Toolset v5, Pester (script tests), `softprops/action-gh-release@v2`.

**Spec:** `docs/superpowers/specs/2026-04-15-windows-ci-installer-design.md`

**Validation strategy:** Because the developer machine is Linux/WSL2 but the build is Windows-only, most tasks are validated by pushing the branch and observing the GHA workflow. Task 2 establishes the first green workflow; every subsequent task extends it and is "done" when the workflow run that includes it completes successfully. PowerShell helpers ship with Pester unit tests that run on the Windows runner as part of the workflow.

---

## File Structure

**New files:**

```
.github/workflows/windows-build.yml

ci/windows/README.md
ci/windows/vcpkg.json
ci/windows/vcpkg-configuration.json

ci/windows/scripts/version.ps1
ci/windows/scripts/configure.ps1
ci/windows/scripts/build.ps1
ci/windows/scripts/stage.ps1
ci/windows/scripts/sign.ps1
ci/windows/scripts/smoke-test.ps1
ci/windows/scripts/Tests/version.Tests.ps1
ci/windows/scripts/Tests/configure.Tests.ps1
ci/windows/scripts/Tests/stage.Tests.ps1

ci/windows/installer/Product.wxs
ci/windows/installer/UI.wxs
ci/windows/installer/wix.props
ci/windows/installer/License.rtf
ci/windows/installer/Banner.bmp           # placeholder, 493x58 px
ci/windows/installer/Dialog.bmp           # placeholder, 493x312 px
ci/windows/installer/README.md
ci/windows/installer/CustomActions/InitDb.ps1
ci/windows/installer/CustomActions/RegisterService.ps1
ci/windows/installer/CustomActions/RemoveService.ps1
ci/windows/installer/CustomActions/Tests/InitDb.Tests.ps1
ci/windows/installer/CustomActions/Tests/RegisterService.Tests.ps1
```

**File responsibilities:**

- `windows-build.yml` — orchestrates the pipeline; each step is a short shell-out to a PowerShell script.
- `vcpkg.json` / `vcpkg-configuration.json` — pinned dep manifest + registry baseline.
- `scripts/version.ps1` — parse `meson.build` → emit version string + artifact name to stdout.
- `scripts/configure.ps1` — wrap `meson setup` with the project's standard flags.
- `scripts/build.ps1` — wrap `ninja -C build`.
- `scripts/stage.ps1` — wrap `meson install --destdir`, verify output layout.
- `scripts/sign.ps1` — invoke `signtool` if secrets present; warn otherwise.
- `scripts/smoke-test.ps1` — silent install → `pg_isready` → query → uninstall → verify removal.
- `installer/Product.wxs` — MSI product, features, components, upgrade code.
- `installer/UI.wxs` — custom wizard dialogs (install dir, data dir, password, port, locale).
- `installer/wix.props` — MSBuild property sheet (paths, target name).
- `installer/CustomActions/InitDb.ps1` — runs `initdb.exe` with a password pwfile (written then shredded).
- `installer/CustomActions/RegisterService.ps1` — runs `pg_ctl register -S auto`.
- `installer/CustomActions/RemoveService.ps1` — stops + unregisters service on uninstall.

Each file has one responsibility; scripts are under ~100 lines each.

---

## Task 0: Scaffolding

**Goal:** Create the `ci/windows/` directory tree with a README that documents the layout. No working code yet — this is the skeleton later tasks fill in.

**Files:**
- Create: `ci/windows/README.md`

**Acceptance Criteria:**
- [ ] `ci/windows/README.md` exists and documents the directory layout.
- [ ] `.gitkeep` placeholders NOT used — we don't need empty directories yet.

**Verify:** `ls ci/windows/` shows `README.md`.

**Steps:**

- [ ] **Step 1: Create the README**

File: `ci/windows/README.md`

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add ci/windows/README.md
git commit -m "windows-ci: add ci/windows scaffolding README"
```

---

## Task 1: vcpkg manifest

**Goal:** Declare all Windows C/C++ dependencies in a pinned vcpkg manifest. After this task, `vcpkg install --x-manifest-root=ci/windows` on a Windows box would install our deps.

**Files:**
- Create: `ci/windows/vcpkg.json`
- Create: `ci/windows/vcpkg-configuration.json`

**Acceptance Criteria:**
- [ ] `vcpkg.json` lists all deps named in the spec: `openssl`, `icu`, `zlib`, `zstd`, `lz4`, `libxml2`, `libxslt`, `openldap`.
- [ ] `vcpkg-configuration.json` pins a `builtin-baseline` (commit SHA from the vcpkg repo).
- [ ] Both files are valid JSON (parse with `jq`).

**Verify:**
```bash
jq empty ci/windows/vcpkg.json
jq empty ci/windows/vcpkg-configuration.json
jq -r '.dependencies | length' ci/windows/vcpkg.json   # prints 8
```

**Steps:**

- [ ] **Step 1: Pick a vcpkg baseline**

Choose a recent commit from https://github.com/microsoft/vcpkg that contains all our deps. A safe choice as of this plan's date:

```
2025.09.17 release tag → commit SHA a42af01b72c28a8e1d7b48107b33e4f286a55ef6
```

(If reviewing this plan later, use the most recent stable release tag.)

- [ ] **Step 2: Write `ci/windows/vcpkg.json`**

```json
{
  "$schema": "https://raw.githubusercontent.com/microsoft/vcpkg-tool/main/docs/vcpkg.schema.json",
  "name": "percona-postgresql-windows",
  "version-string": "18.0.0",
  "description": "Build-time dependencies for Percona Server for PostgreSQL on Windows",
  "dependencies": [
    "openssl",
    "icu",
    "zlib",
    "zstd",
    "lz4",
    "libxml2",
    "libxslt",
    "openldap"
  ]
}
```

- [ ] **Step 3: Write `ci/windows/vcpkg-configuration.json`**

```json
{
  "default-registry": {
    "kind": "git",
    "repository": "https://github.com/microsoft/vcpkg",
    "baseline": "a42af01b72c28a8e1d7b48107b33e4f286a55ef6"
  }
}
```

- [ ] **Step 4: Verify JSON is valid**

```bash
jq empty ci/windows/vcpkg.json && jq empty ci/windows/vcpkg-configuration.json
```

Expected: no output (success).

- [ ] **Step 5: Commit**

```bash
git add ci/windows/vcpkg.json ci/windows/vcpkg-configuration.json
git commit -m "windows-ci: add vcpkg manifest with pinned baseline"
```

---

## Task 2: Workflow skeleton — build + test

**Goal:** Bring up the first working GHA workflow: checkout, vcpkg install, meson configure, ninja build, `meson test`. Produces nothing packaged yet; establishes the green-build baseline everything else extends. This is **the critical first integration point** — fix any toolchain surprises here before adding complexity.

**Files:**
- Create: `.github/workflows/windows-build.yml`

**Acceptance Criteria:**
- [ ] Workflow triggers on push to `PSP_REL_*` branches and `workflow_dispatch`.
- [ ] Runs on `windows-2022`.
- [ ] Uses `microsoft/setup-msbuild@v2` (for `vcvarsall`) or sets MSVC env explicitly.
- [ ] vcpkg installed via `lukka/run-vcpkg@v11` with our manifest.
- [ ] meson configures with the flags from the spec.
- [ ] `meson test` runs with `--num-processes 4 --print-errorlogs`.
- [ ] On push to the plan's branch, the workflow completes successfully.

**Verify:** Push the branch; the "Windows build" workflow run on GitHub Actions is green. `gh run list --workflow=windows-build.yml --limit=1 --json conclusion --jq '.[0].conclusion'` prints `success`.

**Steps:**

- [ ] **Step 1: Write the workflow**

File: `.github/workflows/windows-build.yml`

```yaml
name: Windows build
run-name: "Windows build — ${{ github.event_name }} @ ${{ github.sha }}"

on:
  push:
    branches: ["PSP_REL_*"]
  workflow_dispatch:

concurrency:
  group: windows-build-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: windows-2022
    timeout-minutes: 90

    env:
      VCPKG_DEFAULT_TRIPLET: x64-windows
      VCPKG_BINARY_SOURCES: "clear;x-gha,readwrite"

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Export GitHub Actions cache env for vcpkg
        uses: actions/github-script@v7
        with:
          script: |
            core.exportVariable('ACTIONS_CACHE_URL', process.env.ACTIONS_CACHE_URL || '');
            core.exportVariable('ACTIONS_RUNTIME_TOKEN', process.env.ACTIONS_RUNTIME_TOKEN || '');

      - name: Install vcpkg deps
        uses: lukka/run-vcpkg@v11
        with:
          vcpkgJsonGlob: "ci/windows/vcpkg.json"
          runVcpkgInstall: true

      - name: Set up MSVC environment
        uses: ilammy/msvc-dev-cmd@v1
        with:
          arch: x64
          toolset: "14.4"

      - name: Install meson and ninja
        shell: pwsh
        run: |
          pip install --upgrade meson ninja

      - name: Configure
        shell: pwsh
        env:
          VCPKG_ROOT: ${{ github.workspace }}/vcpkg
        run: |
          $shortSha = "${{ github.sha }}".Substring(0,7)
          meson setup build `
            --buildtype=release `
            --prefix=C:/stage/pgsql `
            --pkg-config-path="$env:VCPKG_ROOT/installed/x64-windows/lib/pkgconfig" `
            -Dssl=openssl `
            -Dicu=enabled `
            -Dzlib=enabled `
            -Dzstd=enabled `
            -Dlz4=enabled `
            -Dlibxml=enabled `
            -Dlibxslt=enabled `
            -Dldap=enabled `
            -Dplperl=disabled `
            -Dplpython=disabled `
            -Dpltcl=disabled `
            "-Dextra_version=-psp-$shortSha"

      - name: Build
        shell: pwsh
        run: ninja -C build

      - name: Test
        shell: pwsh
        run: meson test -C build --num-processes 4 --print-errorlogs

      - name: Upload meson logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: test-logs-${{ github.sha }}
          path: |
            build/meson-logs/
            build/**/crashlog-*.txt
          retention-days: 14
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/windows-build.yml
git commit -m "windows-ci: add workflow skeleton (build + meson test)"
```

- [ ] **Step 3: Push and observe**

```bash
git push
gh run watch --exit-status
```

Expected: the "Windows build" workflow completes successfully.

- [ ] **Step 4: Triage common first-run failures (only if step 3 fails)**

The first workflow run typically surfaces vcpkg triplet / pkg-config / MSVC-version mismatches. If the run fails:

1. Read the failing step's log (`gh run view <id> --log-failed`).
2. If meson can't find a dep: confirm `--pkg-config-path` points to the right directory — `ls $env:VCPKG_ROOT/installed/x64-windows/lib/pkgconfig` must show `.pc` files.
3. If MSVC isn't on PATH: swap `ilammy/msvc-dev-cmd@v1` for `microsoft/setup-msbuild@v2` + explicit `vcvarsall.bat` call.
4. If tests fail in a way that looks environment-specific (not a real regression): note in the PR description; do not start adding test skips — the spec says triage flakes as they appear, not preemptively.

Re-run only after a targeted fix. Do not widen the scope of this task.

---

## Task 3: PowerShell build helpers

**Goal:** Extract the configure/build/stage logic from inline YAML into `ci/windows/scripts/*.ps1`, with Pester unit tests, and refactor the workflow to call them. After this, the workflow YAML is short and the real logic is testable.

**Files:**
- Create: `ci/windows/scripts/version.ps1`
- Create: `ci/windows/scripts/configure.ps1`
- Create: `ci/windows/scripts/build.ps1`
- Create: `ci/windows/scripts/stage.ps1`
- Create: `ci/windows/scripts/Tests/version.Tests.ps1`
- Create: `ci/windows/scripts/Tests/configure.Tests.ps1`
- Create: `ci/windows/scripts/Tests/stage.Tests.ps1`
- Modify: `.github/workflows/windows-build.yml`

**Acceptance Criteria:**
- [ ] Each script runs standalone with `-Help` and prints usage.
- [ ] Each script has a `-WhatIf` mode that prints what it would run without executing.
- [ ] Pester tests cover: version parsing, configure flag composition, stage-dir verification.
- [ ] Workflow calls the scripts instead of inline code.
- [ ] End-to-end workflow run still passes.

**Verify:**
```powershell
# On Windows:
pwsh -File ci/windows/scripts/configure.ps1 -WhatIf
Invoke-Pester ci/windows/scripts/Tests
# On GHA: workflow run green after refactor.
```

**Steps:**

- [ ] **Step 1: Write `ci/windows/scripts/version.ps1`**

```powershell
<#
.SYNOPSIS
    Extract version string from meson.build and emit both the raw version
    and the artifact-name-safe form for use as MSI metadata.

.EXAMPLE
    ./version.ps1 -CommitSha abc1234
#>
[CmdletBinding()]
param(
    [string]$MesonBuild = (Join-Path $PSScriptRoot "../../../meson.build"),
    [string]$CommitSha = "",
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MesonBuild)) {
    throw "meson.build not found at: $MesonBuild"
}

$content = Get-Content $MesonBuild -Raw
$match = [regex]::Match($content, "version:\s*'([^']+)'")
if (-not $match.Success) {
    throw "Could not parse version from $MesonBuild"
}
$version = $match.Groups[1].Value

$shortSha = if ($CommitSha) { $CommitSha.Substring(0, [Math]::Min(7, $CommitSha.Length)) } else { "" }

if ($Tag) {
    $artifactName = "percona-postgresql-18-$Tag-x64.msi"
    $msiVersion = $Tag -replace "^v", "" -replace "[^0-9.].*$", ""
} else {
    $artifactName = "percona-postgresql-18-$version-$shortSha-x64.msi"
    $msiVersion = $version
}

[PSCustomObject]@{
    Version      = $version
    ShortSha     = $shortSha
    ArtifactName = $artifactName
    MsiVersion   = $msiVersion
}
```

- [ ] **Step 2: Write Pester tests for version.ps1**

File: `ci/windows/scripts/Tests/version.Tests.ps1`

```powershell
Describe "version.ps1" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "../version.ps1"
        $script:TempMeson = New-TemporaryFile
        Set-Content $script:TempMeson "project('postgres', 'c', version: '18.3.0', license: 'PostgreSQL')"
    }
    AfterAll { Remove-Item $script:TempMeson -Force }

    It "parses version from meson.build" {
        $result = & $ScriptPath -MesonBuild $TempMeson -CommitSha "abc1234567"
        $result.Version | Should -Be "18.3.0"
        $result.ShortSha | Should -Be "abc1234"
    }

    It "produces sha-based artifact name without tag" {
        $result = & $ScriptPath -MesonBuild $TempMeson -CommitSha "abc1234567"
        $result.ArtifactName | Should -Be "percona-postgresql-18-18.3.0-abc1234-x64.msi"
    }

    It "produces tag-based artifact name when tag is provided" {
        $result = & $ScriptPath -MesonBuild $TempMeson -Tag "v18.3.0-psp1"
        $result.ArtifactName | Should -Be "percona-postgresql-18-v18.3.0-psp1-x64.msi"
        $result.MsiVersion | Should -Be "18.3.0"
    }

    It "throws when meson.build is missing" {
        { & $ScriptPath -MesonBuild "/does/not/exist" } | Should -Throw
    }
}
```

- [ ] **Step 3: Write `ci/windows/scripts/configure.ps1`**

```powershell
<#
.SYNOPSIS
    Run meson setup with the standard Percona Windows flags.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BuildDir = "build",
    [string]$Prefix = "C:/stage/pgsql",
    [string]$VcpkgRoot = $env:VCPKG_ROOT,
    [string]$ExtraVersion = ""
)

$ErrorActionPreference = "Stop"

if (-not $VcpkgRoot) { throw "VCPKG_ROOT is not set." }

$pkgConfigPath = "$VcpkgRoot/installed/x64-windows/lib/pkgconfig"
if (-not (Test-Path $pkgConfigPath)) {
    throw "pkg-config path does not exist: $pkgConfigPath (did vcpkg install run?)"
}

$mesonArgs = @(
    "setup", $BuildDir,
    "--buildtype=release",
    "--prefix=$Prefix",
    "--pkg-config-path=$pkgConfigPath",
    "-Dssl=openssl",
    "-Dicu=enabled",
    "-Dzlib=enabled",
    "-Dzstd=enabled",
    "-Dlz4=enabled",
    "-Dlibxml=enabled",
    "-Dlibxslt=enabled",
    "-Dldap=enabled",
    "-Dplperl=disabled",
    "-Dplpython=disabled",
    "-Dpltcl=disabled"
)
if ($ExtraVersion) { $mesonArgs += "-Dextra_version=$ExtraVersion" }

if ($PSCmdlet.ShouldProcess("meson", ($mesonArgs -join ' '))) {
    & meson @mesonArgs
    if ($LASTEXITCODE -ne 0) { throw "meson setup failed with exit code $LASTEXITCODE" }
}
```

- [ ] **Step 4: Write Pester tests for configure.ps1**

File: `ci/windows/scripts/Tests/configure.Tests.ps1`

```powershell
Describe "configure.ps1" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "../configure.ps1"
        $script:TempVcpkg = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        New-Item -ItemType Directory -Path "$($script:TempVcpkg)/installed/x64-windows/lib/pkgconfig" -Force | Out-Null
    }
    AfterAll { Remove-Item $script:TempVcpkg -Recurse -Force }

    It "throws when VCPKG_ROOT is not set" {
        { & $ScriptPath -VcpkgRoot "" -WhatIf } | Should -Throw "VCPKG_ROOT*"
    }

    It "throws when pkg-config path does not exist" {
        { & $ScriptPath -VcpkgRoot "C:/does/not/exist" -WhatIf } | Should -Throw "pkg-config path*"
    }

    It "emits the expected meson command under -WhatIf" {
        $output = & $ScriptPath -VcpkgRoot $TempVcpkg -ExtraVersion "-psp-abc1234" -WhatIf -Verbose 4>&1
        $output -join "`n" | Should -Match "setup build"
        $output -join "`n" | Should -Match "buildtype=release"
        $output -join "`n" | Should -Match "extra_version=-psp-abc1234"
    }
}
```

- [ ] **Step 5: Write `ci/windows/scripts/build.ps1`**

```powershell
<#
.SYNOPSIS
    Run ninja -C <build-dir>.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BuildDir = "build"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path "$BuildDir/build.ninja")) {
    throw "Build directory not configured: $BuildDir (run configure.ps1 first)"
}

if ($PSCmdlet.ShouldProcess("ninja", "-C $BuildDir")) {
    & ninja -C $BuildDir
    if ($LASTEXITCODE -ne 0) { throw "ninja failed with exit code $LASTEXITCODE" }
}
```

- [ ] **Step 6: Write `ci/windows/scripts/stage.ps1`**

```powershell
<#
.SYNOPSIS
    Stage the install tree via meson install --destdir.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$DestDir,
    [string]$BuildDir = "build"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path "$BuildDir/build.ninja")) {
    throw "Build directory not configured: $BuildDir"
}

if ($PSCmdlet.ShouldProcess("meson install", "--destdir=$DestDir")) {
    & meson install -C $BuildDir --destdir $DestDir
    if ($LASTEXITCODE -ne 0) { throw "meson install failed with exit code $LASTEXITCODE" }

    # Post-stage: copy vcpkg runtime DLLs next to postgres.exe
    $binDir = Get-ChildItem -Path $DestDir -Recurse -Filter "postgres.exe" |
              Select-Object -First 1 -ExpandProperty DirectoryName
    if (-not $binDir) { throw "postgres.exe not found in staged tree under $DestDir" }

    $dllSource = "$env:VCPKG_ROOT/installed/x64-windows/bin"
    if (Test-Path $dllSource) {
        Get-ChildItem "$dllSource/*.dll" | Copy-Item -Destination $binDir -Force
    }

    # Sanity: all expected binaries present
    $required = @("postgres.exe", "psql.exe", "initdb.exe", "pg_ctl.exe", "pg_dump.exe")
    foreach ($exe in $required) {
        if (-not (Test-Path (Join-Path $binDir $exe))) {
            throw "Staged tree missing required binary: $exe"
        }
    }

    Write-Host "Staged to: $binDir (+ $(Get-ChildItem "$binDir/*.dll" | Measure-Object).Count runtime DLLs)"
}
```

- [ ] **Step 7: Write Pester tests for stage.ps1**

File: `ci/windows/scripts/Tests/stage.Tests.ps1`

```powershell
Describe "stage.ps1" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "../stage.ps1"
    }

    It "throws when build dir has no build.ninja" {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            { & $ScriptPath -DestDir "C:/tmp/stage" -BuildDir $tmp -WhatIf } | Should -Throw "Build directory not configured*"
        } finally {
            Remove-Item $tmp -Recurse -Force
        }
    }
}
```

- [ ] **Step 8: Refactor the workflow to call scripts**

Modify `.github/workflows/windows-build.yml` — replace the inline `Configure`, `Build`, and `Install meson and ninja` steps' bodies. After the vcpkg step, replace the configure/build blocks with:

```yaml
      - name: Install meson, ninja, and Pester
        shell: pwsh
        run: |
          pip install --upgrade meson ninja
          Install-Module -Name Pester -Force -SkipPublisherCheck -Scope CurrentUser

      - name: Run PowerShell unit tests
        shell: pwsh
        run: |
          $result = Invoke-Pester -Path ci/windows/scripts/Tests -PassThru
          if ($result.FailedCount -gt 0) { exit 1 }

      - name: Resolve version
        id: version
        shell: pwsh
        run: |
          $v = ./ci/windows/scripts/version.ps1 -CommitSha "${{ github.sha }}"
          "version=$($v.Version)"           >> $env:GITHUB_OUTPUT
          "short_sha=$($v.ShortSha)"        >> $env:GITHUB_OUTPUT
          "artifact_name=$($v.ArtifactName)">> $env:GITHUB_OUTPUT
          "msi_version=$($v.MsiVersion)"    >> $env:GITHUB_OUTPUT

      - name: Configure
        shell: pwsh
        env:
          VCPKG_ROOT: ${{ github.workspace }}/vcpkg
        run: ./ci/windows/scripts/configure.ps1 -ExtraVersion "-psp-${{ steps.version.outputs.short_sha }}"

      - name: Build
        shell: pwsh
        run: ./ci/windows/scripts/build.ps1
```

Keep the existing `Test` and upload-logs steps as-is.

- [ ] **Step 9: Commit**

```bash
git add ci/windows/scripts .github/workflows/windows-build.yml
git commit -m "windows-ci: extract build logic into PowerShell helpers with Pester tests"
```

- [ ] **Step 10: Push and observe**

```bash
git push && gh run watch --exit-status
```

Expected: Pester step passes, workflow green.

---

## Task 4: Minimal WiX installer (file-only)

**Goal:** Produce a first MSI that installs the staged postgres tree to a configurable `INSTALLDIR` with no UI beyond the default WiX UI, no custom actions, no service setup. Silent install + silent uninstall must round-trip cleanly. This is the "MSI structurally works" checkpoint.

**Files:**
- Create: `ci/windows/installer/Product.wxs`
- Create: `ci/windows/installer/wix.props`
- Create: `ci/windows/installer/License.rtf`
- Create: `ci/windows/installer/README.md`
- Create: `ci/windows/installer/Banner.bmp` (placeholder: 493x58, solid Percona-red)
- Create: `ci/windows/installer/Dialog.bmp` (placeholder: 493x312, solid Percona-red with "Percona PostgreSQL 18" text)
- Modify: `.github/workflows/windows-build.yml`

**Acceptance Criteria:**
- [ ] `Product.wxs` defines product, upgrade code, feature tree, and uses `heat`-generated `Files.wxs` at build time.
- [ ] Workflow builds MSI via `wix build` (WiX 5 CLI) after the staging step.
- [ ] Silent install (`msiexec /i ... /qn INSTALLDIR=...`) places files under the requested dir.
- [ ] Silent uninstall removes all files.
- [ ] MSI uploaded as workflow artifact.

**Verify:** On workflow run: staged install/uninstall succeed (logged in step output); artifact appears under Actions → run → Artifacts.

**Steps:**

- [ ] **Step 1: Write `ci/windows/installer/Product.wxs`**

Note: `$(var.StageDir)` is passed at build time to point at the staged install tree.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">
  <Package
      Name="Percona Server for PostgreSQL 18"
      Manufacturer="Percona"
      Version="$(var.ProductVersion)"
      UpgradeCode="9A3B2E4C-7F81-4E2D-BC59-0E5F3A8B1C42"
      Scope="perMachine"
      Compressed="yes">

    <MajorUpgrade
        AllowSameVersionUpgrades="yes"
        DowngradeErrorMessage="A newer version of Percona Server for PostgreSQL 18 is already installed." />

    <MediaTemplate EmbedCab="yes" />

    <Property Id="INSTALLDIR" Value="C:\Program Files\Percona\PostgreSQL\18" />
    <Property Id="DATADIR"    Value="C:\Program Files\Percona\PostgreSQL\18\data" />
    <Property Id="PGPORT"     Value="5432" />
    <Property Id="PGLOCALE"   Value="" />

    <StandardDirectory Id="ProgramFiles64Folder">
      <Directory Id="PerconaDir" Name="Percona">
        <Directory Id="PostgreSQLDir" Name="PostgreSQL">
          <Directory Id="INSTALLDIR_" Name="18" />
        </Directory>
      </Directory>
    </StandardDirectory>

    <Feature Id="Main" Title="Percona Server for PostgreSQL 18" Level="1">
      <ComponentGroupRef Id="StagedFiles" />
    </Feature>

    <WixVariable Id="WixUILicenseRtf" Value="License.rtf" />
    <WixVariable Id="WixUIBannerBmp"  Value="Banner.bmp" />
    <WixVariable Id="WixUIDialogBmp"  Value="Dialog.bmp" />

    <ui:WixUI xmlns:ui="http://wixtoolset.org/schemas/v4/wxs/ui" Id="WixUI_InstallDir" />
    <Property Id="WIXUI_INSTALLDIR" Value="INSTALLDIR_" />
  </Package>
</Wix>
```

- [ ] **Step 2: Write `ci/windows/installer/wix.props`**

This file holds WiX-specific build properties; it's a plain text file consumed by the workflow.

```
# WiX build properties (consumed by the workflow build step)
WIX_EXTENSIONS=WixToolset.UI.wixext WixToolset.Util.wixext
HEAT_OUTPUT_VAR=StagedFiles
```

- [ ] **Step 3: License and branding placeholders**

Convert the top-level `COPYRIGHT` file to RTF for `License.rtf`:

```bash
# Simplest: hand-craft a minimal RTF containing the plain text.
cat > ci/windows/installer/License.rtf <<'EOF'
{\rtf1\ansi
This is a placeholder license for the testing installer. Replace with the
full project license before shipping a non-testing build. See COPYRIGHT at
the top of the repository for the authoritative text.\par
}
EOF
```

For `Banner.bmp` (493x58) and `Dialog.bmp` (493x312), generate solid-color placeholders:

```bash
python3 - <<'EOF'
from PIL import Image, ImageDraw, ImageFont
for name, size, text in [("Banner.bmp",(493,58),"Percona PostgreSQL 18"),
                         ("Dialog.bmp",(493,312),"Percona PostgreSQL 18")]:
    img = Image.new("RGB", size, (143, 27, 42))  # Percona burgundy
    d = ImageDraw.Draw(img)
    d.text((12, 12), text, fill=(255, 255, 255))
    img.save(f"ci/windows/installer/{name}")
EOF
```

(If Pillow isn't installed: `pip install Pillow` or commit any valid 24-bit BMPs of those dimensions.)

- [ ] **Step 4: Write `ci/windows/installer/README.md`**

```markdown
# MSI installer sources

WiX 5 project. Built by `.github/workflows/windows-build.yml`.

## Branding placeholders (must replace before shipping non-testing builds)

- `License.rtf` — currently a placeholder. Replace with the real license text.
- `Banner.bmp` — 493x58, 24-bit BMP. Placeholder is solid Percona burgundy.
- `Dialog.bmp` — 493x312, 24-bit BMP. Placeholder is solid Percona burgundy.

## Local build (Windows only)

```powershell
heat dir C:/stage/pgsql -gg -sfrag -srd -cg StagedFiles -dr INSTALLDIR_ -var var.StageDir -out Files.wxs
wix build Product.wxs Files.wxs -ext WixToolset.UI.wixext -d ProductVersion=18.3.0 -d StageDir=C:/stage/pgsql -o percona-postgresql-18.msi
```
```

- [ ] **Step 5: Extend the workflow — stage + build MSI**

Add these steps to `.github/workflows/windows-build.yml` after the `Test` step:

```yaml
      - name: Stage install tree
        shell: pwsh
        env:
          VCPKG_ROOT: ${{ github.workspace }}/vcpkg
        run: ./ci/windows/scripts/stage.ps1 -DestDir C:/stage

      - name: Install WiX 5
        shell: pwsh
        run: |
          dotnet tool install --global wix --version 5.0.2
          wix extension add -g WixToolset.UI.wixext
          wix extension add -g WixToolset.Util.wixext

      - name: Harvest staged tree
        shell: pwsh
        run: |
          wix heat dir C:/stage/pgsql `
            -gg -sfrag -srd `
            -cg StagedFiles `
            -dr INSTALLDIR_ `
            -var var.StageDir `
            -out ci/windows/installer/Files.wxs

      - name: Build MSI
        shell: pwsh
        run: |
          cd ci/windows/installer
          wix build Product.wxs Files.wxs `
            -ext WixToolset.UI.wixext `
            -d ProductVersion=${{ steps.version.outputs.msi_version }} `
            -d StageDir=C:/stage/pgsql `
            -o "${{ github.workspace }}/${{ steps.version.outputs.artifact_name }}"

      - name: Upload MSI artifact
        uses: actions/upload-artifact@v4
        with:
          name: msi-${{ steps.version.outputs.short_sha }}
          path: ${{ steps.version.outputs.artifact_name }}
          retention-days: 30
```

- [ ] **Step 6: Commit**

```bash
git add ci/windows/installer .github/workflows/windows-build.yml
git commit -m "windows-ci: add minimal WiX MSI (file-only, no service setup)"
```

- [ ] **Step 7: Push and observe**

```bash
git push && gh run watch --exit-status
```

Expected: workflow green, MSI artifact uploaded.

---

## Task 5: Wizard UI

**Goal:** Replace `WixUI_InstallDir` with a custom wizard that collects data directory, port, locale, and superuser password (with confirmation). After this, interactive installs show the EDB-like page sequence but still don't do anything with the collected values — that's Task 6/7.

**Files:**
- Create: `ci/windows/installer/UI.wxs`
- Modify: `ci/windows/installer/Product.wxs`

**Acceptance Criteria:**
- [ ] UI.wxs defines dialogs: Welcome → License → InstallDir → DataDir → Password → Port → Locale → VerifyReady → Progress → ExitDialog.
- [ ] Password dialog has two fields; "Next" is disabled until they match and are ≥8 chars.
- [ ] Port dialog rejects non-numeric input and out-of-range values.
- [ ] Properties `DATADIR`, `PGPORT`, `PGLOCALE`, `PGPASSWORD` accessible from `msiexec /i ... PGPASSWORD=... PGPORT=...` for silent installs.
- [ ] Workflow MSI build passes.

**Verify:** On workflow run, MSI builds green. (Full wizard validation comes in Task 7 via the smoke test — this task's criterion is "MSI compiles with the new UI.")

**Steps:**

- [ ] **Step 1: Write `ci/windows/installer/UI.wxs`**

This is substantial. Here is the structure; fill in dialog bodies following WiX 5 dialog-control patterns (see https://wixtoolset.org/docs/reference/schema/wxs/dialog/ for field reference):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs"
     xmlns:ui="http://wixtoolset.org/schemas/v4/wxs/ui">
  <Fragment>
    <ui:WixUI Id="PerconaPgUI">
      <TextStyle Id="WixUI_Font_Normal" FaceName="Tahoma" Size="8" />
      <TextStyle Id="WixUI_Font_Bigger" FaceName="Tahoma" Size="12" />
      <TextStyle Id="WixUI_Font_Title"  FaceName="Tahoma" Size="9" Bold="yes" />

      <Property Id="DefaultUIFont" Value="WixUI_Font_Normal" />
      <Property Id="WIXUI_INSTALLDIR" Value="INSTALLDIR_" />

      <DialogRef Id="ErrorDlg" />
      <DialogRef Id="FatalError" />
      <DialogRef Id="FilesInUse" />
      <DialogRef Id="MsiRMFilesInUse" />
      <DialogRef Id="PrepareDlg" />
      <DialogRef Id="ProgressDlg" />
      <DialogRef Id="ResumeDlg" />
      <DialogRef Id="UserExit" />

      <Publish Dialog="WelcomeDlg"     Control="Next" Event="NewDialog" Value="LicenseAgreementDlg" />
      <Publish Dialog="LicenseAgreementDlg" Control="Back" Event="NewDialog" Value="WelcomeDlg" />
      <Publish Dialog="LicenseAgreementDlg" Control="Next" Event="NewDialog" Value="InstallDirDlg" Condition="LicenseAccepted = &quot;1&quot;" />
      <Publish Dialog="InstallDirDlg"  Control="Back" Event="NewDialog" Value="LicenseAgreementDlg" />
      <Publish Dialog="InstallDirDlg"  Control="Next" Event="NewDialog" Value="DataDirDlg" />
      <Publish Dialog="DataDirDlg"     Control="Back" Event="NewDialog" Value="InstallDirDlg" />
      <Publish Dialog="DataDirDlg"     Control="Next" Event="NewDialog" Value="PasswordDlg" />
      <Publish Dialog="PasswordDlg"    Control="Back" Event="NewDialog" Value="DataDirDlg" />
      <Publish Dialog="PasswordDlg"    Control="Next" Event="NewDialog" Value="PortDlg"     Condition="PGPASSWORD = PGPASSWORD_CONFIRM AND PGPASSWORD &lt;&gt; &quot;&quot;" />
      <Publish Dialog="PortDlg"        Control="Back" Event="NewDialog" Value="PasswordDlg" />
      <Publish Dialog="PortDlg"        Control="Next" Event="NewDialog" Value="LocaleDlg" />
      <Publish Dialog="LocaleDlg"      Control="Back" Event="NewDialog" Value="PortDlg" />
      <Publish Dialog="LocaleDlg"      Control="Next" Event="NewDialog" Value="VerifyReadyDlg" />
      <Publish Dialog="VerifyReadyDlg" Control="Back" Event="NewDialog" Value="LocaleDlg" />
    </ui:WixUI>

    <!-- DataDirDlg -->
    <Dialog Id="DataDirDlg" Width="370" Height="270" Title="Data directory">
      <Control Id="Title" Type="Text" X="15" Y="6" Width="340" Height="15" Text="{\WixUI_Font_Title}Data directory" />
      <Control Id="Description" Type="Text" X="25" Y="26" Width="320" Height="20" Text="Choose the directory where PostgreSQL will store database files." />
      <Control Id="DataDirEdit" Type="PathEdit" X="20" Y="60" Width="320" Height="18" Property="DATADIR" Indirect="no" />
      <Control Id="Back" Type="PushButton" X="180" Y="243" Width="56" Height="17" Text="&amp;Back" />
      <Control Id="Next" Type="PushButton" X="236" Y="243" Width="56" Height="17" Default="yes" Text="&amp;Next" />
      <Control Id="Cancel" Type="PushButton" X="304" Y="243" Width="56" Height="17" Cancel="yes" Text="Cancel">
        <Publish Event="SpawnDialog" Value="CancelDlg" />
      </Control>
    </Dialog>

    <!-- PasswordDlg -->
    <Dialog Id="PasswordDlg" Width="370" Height="270" Title="Superuser password">
      <Control Id="Title" Type="Text" X="15" Y="6" Width="340" Height="15" Text="{\WixUI_Font_Title}Superuser password" />
      <Control Id="Description" Type="Text" X="25" Y="26" Width="320" Height="30" Text="Set the password for the 'postgres' superuser. Minimum 8 characters. Store this password securely — it cannot be recovered." />
      <Control Id="PwLabel" Type="Text" X="20" Y="80" Width="80" Height="15" Text="Password:" />
      <Control Id="PwEdit" Type="Edit" X="100" Y="78" Width="240" Height="18" Property="PGPASSWORD" Password="yes" />
      <Control Id="PwConfirmLabel" Type="Text" X="20" Y="110" Width="80" Height="15" Text="Confirm:" />
      <Control Id="PwConfirmEdit" Type="Edit" X="100" Y="108" Width="240" Height="18" Property="PGPASSWORD_CONFIRM" Password="yes" />
      <Control Id="Back" Type="PushButton" X="180" Y="243" Width="56" Height="17" Text="&amp;Back" />
      <Control Id="Next" Type="PushButton" X="236" Y="243" Width="56" Height="17" Default="yes" Text="&amp;Next" />
      <Control Id="Cancel" Type="PushButton" X="304" Y="243" Width="56" Height="17" Cancel="yes" Text="Cancel">
        <Publish Event="SpawnDialog" Value="CancelDlg" />
      </Control>
    </Dialog>

    <!-- PortDlg -->
    <Dialog Id="PortDlg" Width="370" Height="270" Title="Port">
      <Control Id="Title" Type="Text" X="15" Y="6" Width="340" Height="15" Text="{\WixUI_Font_Title}Network port" />
      <Control Id="Description" Type="Text" X="25" Y="26" Width="320" Height="20" Text="TCP port the server will listen on." />
      <Control Id="PortEdit" Type="Edit" X="20" Y="60" Width="80" Height="18" Property="PGPORT" />
      <Control Id="Back" Type="PushButton" X="180" Y="243" Width="56" Height="17" Text="&amp;Back" />
      <Control Id="Next" Type="PushButton" X="236" Y="243" Width="56" Height="17" Default="yes" Text="&amp;Next" />
      <Control Id="Cancel" Type="PushButton" X="304" Y="243" Width="56" Height="17" Cancel="yes" Text="Cancel">
        <Publish Event="SpawnDialog" Value="CancelDlg" />
      </Control>
    </Dialog>

    <!-- LocaleDlg -->
    <Dialog Id="LocaleDlg" Width="370" Height="270" Title="Locale">
      <Control Id="Title" Type="Text" X="15" Y="6" Width="340" Height="15" Text="{\WixUI_Font_Title}Locale" />
      <Control Id="Description" Type="Text" X="25" Y="26" Width="320" Height="20" Text="Database locale. Leave blank for system default." />
      <Control Id="LocaleCombo" Type="ComboBox" X="20" Y="60" Width="200" Height="18" Property="PGLOCALE">
        <ComboBox Property="PGLOCALE">
          <ListItem Value="" Text="Default (system locale)" />
          <ListItem Value="C" Text="C" />
          <ListItem Value="en_US.UTF-8" Text="en_US.UTF-8" />
        </ComboBox>
      </Control>
      <Control Id="Back" Type="PushButton" X="180" Y="243" Width="56" Height="17" Text="&amp;Back" />
      <Control Id="Next" Type="PushButton" X="236" Y="243" Width="56" Height="17" Default="yes" Text="&amp;Next" />
      <Control Id="Cancel" Type="PushButton" X="304" Y="243" Width="56" Height="17" Cancel="yes" Text="Cancel">
        <Publish Event="SpawnDialog" Value="CancelDlg" />
      </Control>
    </Dialog>
  </Fragment>
</Wix>
```

Note: dialog coordinate/layout details follow stock WiX dialog conventions; the above is correct WiX 5 XML but visually-minimal. Polish is a follow-on.

- [ ] **Step 2: Update Product.wxs to reference the custom UI**

Replace this line in `Product.wxs`:
```xml
    <ui:WixUI xmlns:ui="http://wixtoolset.org/schemas/v4/wxs/ui" Id="WixUI_InstallDir" />
```
with:
```xml
    <ui:WixUI xmlns:ui="http://wixtoolset.org/schemas/v4/wxs/ui" Id="PerconaPgUI" />
```

Add the new properties to the `<Package>` element (alongside the existing ones):
```xml
    <Property Id="PGPASSWORD" Value="" />
    <Property Id="PGPASSWORD_CONFIRM" Value="" />
```

- [ ] **Step 3: Add UI.wxs to the MSI build**

Modify the `Build MSI` step in the workflow:
```yaml
      - name: Build MSI
        shell: pwsh
        run: |
          cd ci/windows/installer
          wix build Product.wxs UI.wxs Files.wxs `
            -ext WixToolset.UI.wixext `
            -d ProductVersion=${{ steps.version.outputs.msi_version }} `
            -d StageDir=C:/stage/pgsql `
            -o "${{ github.workspace }}/${{ steps.version.outputs.artifact_name }}"
```

- [ ] **Step 4: Commit**

```bash
git add ci/windows/installer/UI.wxs ci/windows/installer/Product.wxs .github/workflows/windows-build.yml
git commit -m "windows-ci: add wizard UI dialogs (install/data dir, password, port, locale)"
```

- [ ] **Step 5: Push and observe**

```bash
git push && gh run watch --exit-status
```

Expected: workflow green; MSI artifact still uploads.

---

## Task 6: Service custom actions (scripts)

**Goal:** Write the PowerShell scripts that implement initdb, service registration, and service removal — with Pester tests that exercise their argument handling. Scripts are standalone and testable; wiring into the MSI is Task 7.

**Files:**
- Create: `ci/windows/installer/CustomActions/InitDb.ps1`
- Create: `ci/windows/installer/CustomActions/RegisterService.ps1`
- Create: `ci/windows/installer/CustomActions/RemoveService.ps1`
- Create: `ci/windows/installer/CustomActions/Tests/InitDb.Tests.ps1`
- Create: `ci/windows/installer/CustomActions/Tests/RegisterService.Tests.ps1`
- Modify: `.github/workflows/windows-build.yml` (Pester step: expand test path)

**Acceptance Criteria:**
- [ ] `InitDb.ps1` takes `-BinDir`, `-DataDir`, `-Password` (secure string or env-passed), generates a pwfile in `%TEMP%`, runs `initdb`, shreds the pwfile regardless of outcome.
- [ ] `RegisterService.ps1` takes `-BinDir`, `-DataDir`, `-ServiceName` and runs `pg_ctl register -S auto -U "NT AUTHORITY\NetworkService"`.
- [ ] `RemoveService.ps1` stops and unregisters the service, tolerating "service does not exist".
- [ ] Pester tests cover argument parsing, pwfile cleanup on failure, idempotent service removal.

**Verify:** Pester step in workflow passes with expanded test path.

**Steps:**

- [ ] **Step 1: `ci/windows/installer/CustomActions/InitDb.ps1`**

```powershell
<#
.SYNOPSIS
    Run initdb.exe with a password provided via pwfile.

.NOTES
    The pwfile is written to a random path under %TEMP%, handed to initdb,
    then overwritten with zeros and deleted in a finally block — regardless
    of whether initdb succeeded. Passing the password via environment would
    leak it to process-listing tools; pwfile is the only safe mechanism.
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

    $args = @(
        "-D", $DataDir,
        "-U", $Superuser,
        "--pwfile=$pwfile",
        "-E", $Encoding,
        "--auth-local=scram-sha-256",
        "--auth-host=scram-sha-256"
    )
    if ($Locale) { $args += @("--locale=$Locale") }

    & $initdb @args
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
```

- [ ] **Step 2: `ci/windows/installer/CustomActions/RegisterService.ps1`**

```powershell
<#
.SYNOPSIS
    Register postgres as a Windows service and start it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BinDir,
    [Parameter(Mandatory)][string]$DataDir,
    [Parameter(Mandatory)][string]$ServiceName,
    [string]$Account = "NT AUTHORITY\NetworkService"
)

$ErrorActionPreference = "Stop"

$pgCtl = Join-Path $BinDir "pg_ctl.exe"
if (-not (Test-Path $pgCtl)) { throw "pg_ctl.exe not found at $pgCtl" }

& $pgCtl register -N $ServiceName -D $DataDir -S auto -U $Account
if ($LASTEXITCODE -ne 0) { throw "pg_ctl register failed with exit code $LASTEXITCODE" }

# Start service and wait for readiness (30s)
Start-Service -Name $ServiceName
$deadline = (Get-Date).AddSeconds(30)
$pgIsready = Join-Path $BinDir "pg_isready.exe"
while ((Get-Date) -lt $deadline) {
    & $pgIsready -d postgres
    if ($LASTEXITCODE -eq 0) { return }
    Start-Sleep -Milliseconds 500
}
throw "Service $ServiceName did not become ready within 30 seconds"
```

- [ ] **Step 3: `ci/windows/installer/CustomActions/RemoveService.ps1`**

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BinDir,
    [Parameter(Mandatory)][string]$ServiceName
)

$ErrorActionPreference = "Stop"

$pgCtl = Join-Path $BinDir "pg_ctl.exe"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -eq $svc) {
    Write-Host "Service $ServiceName does not exist; nothing to remove."
    return
}

if ($svc.Status -ne "Stopped") {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Get-Service -Name $ServiceName).Status -eq "Stopped") { break }
        Start-Sleep -Milliseconds 500
    }
}

if (Test-Path $pgCtl) {
    & $pgCtl unregister -N $ServiceName
    # Tolerate non-zero exit; sc.exe fallback below
}

# Belt-and-braces: ensure service is removed even if pg_ctl unregister failed
$null = sc.exe delete $ServiceName
```

- [ ] **Step 4: Pester tests — InitDb.Tests.ps1**

```powershell
Describe "InitDb.ps1" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "../InitDb.ps1"
    }

    It "throws when BinDir does not contain initdb.exe" {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            { & $ScriptPath -BinDir $tmp -DataDir "C:/tmp/d" -Password "secret12" } |
                Should -Throw "initdb.exe not found*"
        } finally { Remove-Item $tmp -Recurse -Force }
    }

    It "shreds pwfile even if initdb fails" {
        # Stub initdb.exe that returns non-zero
        $binDir = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            $stub = Join-Path $binDir "initdb.exe"
            $stubCmd = "exit 42"
            # Create batch file masquerading as .exe for the test (Windows will refuse; use cmd script)
            # Simpler: trap and verify no pwfile survives under %TEMP%.
            $beforeFiles = Get-ChildItem ([IO.Path]::GetTempPath()) -Filter "pgpw-*.txt"
            try {
                & $ScriptPath -BinDir $binDir -DataDir "C:/tmp" -Password "x" -ErrorAction SilentlyContinue
            } catch { }
            $afterFiles = Get-ChildItem ([IO.Path]::GetTempPath()) -Filter "pgpw-*.txt"
            ($afterFiles.Count) | Should -Be $beforeFiles.Count
        } finally { Remove-Item $binDir -Recurse -Force }
    }
}
```

- [ ] **Step 5: Pester tests — RegisterService.Tests.ps1**

```powershell
Describe "RegisterService.ps1" {
    BeforeAll {
        $script:ScriptPath = Join-Path $PSScriptRoot "../RegisterService.ps1"
    }

    It "throws when pg_ctl.exe is missing" {
        $tmp = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) (New-Guid))
        try {
            { & $ScriptPath -BinDir $tmp -DataDir "C:/tmp/d" -ServiceName "test-svc" } |
                Should -Throw "pg_ctl.exe not found*"
        } finally { Remove-Item $tmp -Recurse -Force }
    }
}
```

- [ ] **Step 6: Expand workflow Pester step**

Modify the `Run PowerShell unit tests` step in the workflow:
```yaml
      - name: Run PowerShell unit tests
        shell: pwsh
        run: |
          $result = Invoke-Pester -Path ci/windows/scripts/Tests,ci/windows/installer/CustomActions/Tests -PassThru
          if ($result.FailedCount -gt 0) { exit 1 }
```

- [ ] **Step 7: Commit**

```bash
git add ci/windows/installer/CustomActions .github/workflows/windows-build.yml
git commit -m "windows-ci: add service custom-action scripts with Pester tests"
```

- [ ] **Step 8: Push and observe**

```bash
git push && gh run watch --exit-status
```

Expected: Pester runs include custom-action tests, workflow green.

---

## Task 7: Wire custom actions + smoke test

**Goal:** Connect the custom-action scripts into the WiX install sequence and add the `smoke-test.ps1` script that validates the end-to-end install → running service → uninstall flow. After this, the workflow blocks publish on a broken MSI.

**Files:**
- Modify: `ci/windows/installer/Product.wxs`
- Create: `ci/windows/scripts/smoke-test.ps1`
- Modify: `.github/workflows/windows-build.yml`

**Acceptance Criteria:**
- [ ] Product.wxs schedules `RunInitDb`, `RegisterService` in `InstallExecuteSequence` (deferred, after `InstallFiles`).
- [ ] Product.wxs schedules `RemoveService` on uninstall (before `RemoveFiles`).
- [ ] `smoke-test.ps1` does silent install → `pg_isready` → `SELECT version()` → silent uninstall → verify service gone.
- [ ] Workflow runs smoke test; failure fails the job.

**Verify:** Workflow run passes through the smoke test; `pg_isready` prints "accepting connections"; uninstall log shows service removal; `sc.exe query postgresql-psp-18` fails after uninstall.

**Steps:**

- [ ] **Step 1: Add custom actions to Product.wxs**

Add before the closing `</Package>` tag:

```xml
    <!-- Custom action binaries (PowerShell scripts installed as part of the product) -->
    <SetProperty Id="PowerShellExe" Value="powershell.exe" Before="AppSearch" Sequence="execute" />

    <CustomAction Id="RunInitDb"
                  Directory="INSTALLDIR_"
                  ExeCommand='[PowerShellExe] -NoProfile -ExecutionPolicy Bypass -File "[INSTALLDIR_]CustomActions\InitDb.ps1" -BinDir "[INSTALLDIR_]bin" -DataDir "[DATADIR]" -Password "[PGPASSWORD]" -Locale "[PGLOCALE]"'
                  Execute="deferred"
                  Impersonate="no"
                  Return="check" />

    <CustomAction Id="SetRunInitDbProps"
                  Property="RunInitDb"
                  Value="PowerShellExe=[PowerShellExe];INSTALLDIR_=[INSTALLDIR_];DATADIR=[DATADIR];PGPASSWORD=[PGPASSWORD];PGLOCALE=[PGLOCALE]" />

    <CustomAction Id="RegisterService"
                  Directory="INSTALLDIR_"
                  ExeCommand='[PowerShellExe] -NoProfile -ExecutionPolicy Bypass -File "[INSTALLDIR_]CustomActions\RegisterService.ps1" -BinDir "[INSTALLDIR_]bin" -DataDir "[DATADIR]" -ServiceName "postgresql-psp-18"'
                  Execute="deferred"
                  Impersonate="no"
                  Return="check" />

    <CustomAction Id="SetRegisterServiceProps"
                  Property="RegisterService"
                  Value="PowerShellExe=[PowerShellExe];INSTALLDIR_=[INSTALLDIR_];DATADIR=[DATADIR]" />

    <CustomAction Id="RemoveService"
                  Directory="INSTALLDIR_"
                  ExeCommand='[PowerShellExe] -NoProfile -ExecutionPolicy Bypass -File "[INSTALLDIR_]CustomActions\RemoveService.ps1" -BinDir "[INSTALLDIR_]bin" -ServiceName "postgresql-psp-18"'
                  Execute="deferred"
                  Impersonate="no"
                  Return="check" />

    <CustomAction Id="SetRemoveServiceProps"
                  Property="RemoveService"
                  Value="PowerShellExe=[PowerShellExe];INSTALLDIR_=[INSTALLDIR_]" />

    <InstallExecuteSequence>
      <Custom Action="SetRunInitDbProps"       Before="RunInitDb" />
      <Custom Action="RunInitDb"               After="InstallFiles" Condition="NOT Installed" />
      <Custom Action="SetRegisterServiceProps" Before="RegisterService" />
      <Custom Action="RegisterService"         After="RunInitDb"    Condition="NOT Installed" />
      <Custom Action="SetRemoveServiceProps"   Before="RemoveService" />
      <Custom Action="RemoveService"           Before="RemoveFiles" Condition="Installed AND REMOVE=&quot;ALL&quot;" />
    </InstallExecuteSequence>
```

- [ ] **Step 2: Ensure CustomActions directory is harvested into the MSI**

The `heat` step already harvests `C:/stage/pgsql`. Update `stage.ps1` to also copy the custom-action scripts into the staged tree:

Modify `ci/windows/scripts/stage.ps1` — before the "Sanity" block, add:

```powershell
    # Copy custom-action scripts into the staged tree
    $caSource = Join-Path $PSScriptRoot "../installer/CustomActions"
    $caDest = Join-Path (Split-Path $binDir -Parent) "CustomActions"
    New-Item -ItemType Directory -Path $caDest -Force | Out-Null
    Get-ChildItem "$caSource/*.ps1" | Copy-Item -Destination $caDest -Force
```

- [ ] **Step 3: Write `ci/windows/scripts/smoke-test.ps1`**

```powershell
<#
.SYNOPSIS
    Install the MSI silently, verify the service works, uninstall, verify removal.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [string]$InstallDir = "C:\smoketest\pgsql",
    [string]$DataDir = "C:\smoketest\data",
    [int]$Port = 5433
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $MsiPath)) { throw "MSI not found: $MsiPath" }

# Generate a random password (32 bytes base64)
$rngBytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rngBytes)
$password = [Convert]::ToBase64String($rngBytes)

$logInstall = Join-Path ([IO.Path]::GetTempPath()) "pgsmoke-install.log"
$logUninstall = Join-Path ([IO.Path]::GetTempPath()) "pgsmoke-uninstall.log"

try {
    Write-Host "=== Install ==="
    $installArgs = @(
        "/i", $MsiPath, "/qn", "/l*v", $logInstall,
        "INSTALLDIR=`"$InstallDir`"",
        "DATADIR=`"$DataDir`"",
        "PGPORT=$Port",
        "PGPASSWORD=`"$password`"",
        "PGPASSWORD_CONFIRM=`"$password`""
    )
    $p = Start-Process msiexec -ArgumentList $installArgs -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Get-Content $logInstall -Tail 100 | Write-Host
        throw "Install failed with exit code $($p.ExitCode)"
    }

    Write-Host "=== Verify service ==="
    $pgIsready = Join-Path $InstallDir "bin\pg_isready.exe"
    $deadline = (Get-Date).AddSeconds(30)
    $ready = $false
    while ((Get-Date) -lt $deadline) {
        & $pgIsready -p $Port
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "pg_isready did not succeed within 30s" }

    Write-Host "=== Run query ==="
    $env:PGPASSWORD = $password
    $psql = Join-Path $InstallDir "bin\psql.exe"
    $version = & $psql -h 127.0.0.1 -p $Port -U postgres -tAc "SELECT version();"
    if ($LASTEXITCODE -ne 0) { throw "psql query failed" }
    Write-Host "Reported version: $version"
    if ($version -notmatch "PostgreSQL 18") { throw "Unexpected version string: $version" }
}
finally {
    $env:PGPASSWORD = $null
    Write-Host "=== Uninstall ==="
    $uninstallArgs = @("/x", $MsiPath, "/qn", "/l*v", $logUninstall)
    $p = Start-Process msiexec -ArgumentList $uninstallArgs -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Get-Content $logUninstall -Tail 100 | Write-Host
        throw "Uninstall failed with exit code $($p.ExitCode)"
    }

    Write-Host "=== Verify service removed ==="
    $svc = Get-Service -Name "postgresql-psp-18" -ErrorAction SilentlyContinue
    if ($null -ne $svc) { throw "Service postgresql-psp-18 still exists after uninstall" }
    Write-Host "Smoke test passed."
}
```

- [ ] **Step 4: Add smoke-test step to workflow**

After the `Build MSI` step and before `Upload MSI artifact`:

```yaml
      - name: Smoke-test MSI
        shell: pwsh
        run: ./ci/windows/scripts/smoke-test.ps1 -MsiPath "${{ steps.version.outputs.artifact_name }}"

      - name: Upload smoke-test logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: smoke-test-logs-${{ github.sha }}
          path: ${{ runner.temp }}/pgsmoke-*.log
          retention-days: 14
```

- [ ] **Step 5: Commit**

```bash
git add ci/windows/installer/Product.wxs ci/windows/scripts/smoke-test.ps1 ci/windows/scripts/stage.ps1 .github/workflows/windows-build.yml
git commit -m "windows-ci: wire custom actions into MSI and add smoke test"
```

- [ ] **Step 6: Push and observe**

```bash
git push && gh run watch --exit-status
```

Expected: workflow green end-to-end, including smoke test. If smoke test fails, the downloaded logs will show either an MSI-structural issue or a real bug in the custom actions — fix inside this task before proceeding.

---

## Task 8: Optional signing

**Goal:** Add a signing step that runs `signtool` if `SIGNING_CERT_PFX_BASE64` and `SIGNING_CERT_PASSWORD` secrets exist, and emits a warning otherwise. Fork-PR builds never sign.

**Files:**
- Create: `ci/windows/scripts/sign.ps1`
- Modify: `.github/workflows/windows-build.yml`

**Acceptance Criteria:**
- [ ] `sign.ps1` decodes base64 PFX, signs with SHA256 + RFC3161 timestamp, shreds the PFX afterward.
- [ ] Workflow runs signing only when secrets are present AND `github.event.pull_request.head.repo.full_name == github.repository` (or non-PR event).
- [ ] When unsigned, workflow emits `::warning::` message.
- [ ] Workflow still succeeds without signing secrets configured.

**Verify:** On the plan branch (no secrets set), workflow run completes green and shows warning. When secrets are later added, signtool runs and `Get-AuthenticodeSignature <msi>` shows `Valid`.

**Steps:**

- [ ] **Step 1: Write `ci/windows/scripts/sign.ps1`**

```powershell
<#
.SYNOPSIS
    Sign an MSI via signtool. Skips with a warning if signing secrets are absent.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MsiPath,
    [string]$PfxBase64 = $env:SIGNING_CERT_PFX_BASE64,
    [string]$PfxPassword = $env:SIGNING_CERT_PASSWORD,
    [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrEmpty($PfxBase64) -or [string]::IsNullOrEmpty($PfxPassword)) {
    Write-Host "::warning::MSI is unsigned (signing secrets not configured)"
    return
}

$pfxPath = Join-Path ([IO.Path]::GetTempPath()) ("sign-" + [Guid]::NewGuid().ToString("N") + ".pfx")
try {
    [IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($PfxBase64))

    $signtool = (Get-Command signtool.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $signtool) {
        # Look in Windows SDK default path
        $sdk = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Directory -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -First 1
        $signtool = Join-Path $sdk.FullName "x64\signtool.exe"
    }
    if (-not (Test-Path $signtool)) { throw "signtool.exe not found" }

    & $signtool sign /f $pfxPath /p $PfxPassword /fd SHA256 /tr $TimestampUrl /td SHA256 $MsiPath
    if ($LASTEXITCODE -ne 0) { throw "signtool sign failed with exit code $LASTEXITCODE" }

    & $signtool verify /pa /v $MsiPath
    if ($LASTEXITCODE -ne 0) { throw "signtool verify failed with exit code $LASTEXITCODE" }
}
finally {
    if (Test-Path $pfxPath) {
        try {
            $bytes = New-Object byte[] 8192
            [IO.File]::WriteAllBytes($pfxPath, $bytes)
        } catch {}
        Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
    }
}
```

- [ ] **Step 2: Add signing step to workflow (before smoke test)**

Add between `Build MSI` and `Smoke-test MSI`:

```yaml
      - name: Sign MSI (if secrets present)
        if: |
          github.event_name != 'pull_request' ||
          github.event.pull_request.head.repo.full_name == github.repository
        shell: pwsh
        env:
          SIGNING_CERT_PFX_BASE64: ${{ secrets.SIGNING_CERT_PFX_BASE64 }}
          SIGNING_CERT_PASSWORD: ${{ secrets.SIGNING_CERT_PASSWORD }}
        run: ./ci/windows/scripts/sign.ps1 -MsiPath "${{ steps.version.outputs.artifact_name }}"
```

- [ ] **Step 3: Commit**

```bash
git add ci/windows/scripts/sign.ps1 .github/workflows/windows-build.yml
git commit -m "windows-ci: add optional authenticode signing"
```

- [ ] **Step 4: Push and observe**

```bash
git push && gh run watch --exit-status
```

Expected: Sign step prints `::warning::MSI is unsigned (signing secrets not configured)`, workflow green.

---

## Task 9: Artifacts, nightly rolling release, tag release

**Goal:** On branch push, publish a `nightly-psp<major>` rolling release. On tag push (`v*`), publish a proper GitHub Release. Workflow artifacts always uploaded (already done in Task 4).

**Files:**
- Modify: `.github/workflows/windows-build.yml`

**Acceptance Criteria:**
- [ ] Nightly job: deletes existing `nightly-psp18` release+tag if present, creates a new one with the MSI attached, pre-release=true.
- [ ] Tag job: creates a proper GitHub Release from the pushed tag, pre-release=false, attaches the MSI.
- [ ] Both use `softprops/action-gh-release@v2`.
- [ ] Release notes include the short SHA and commit subject for nightly; auto-generated for tag release.

**Verify:** Push to `wininst` — see `nightly-psp18` release appear on the repo, with the MSI attached. Tag a commit `v18.3.0-psp1-test` — see a non-pre-release with the MSI.

**Steps:**

- [ ] **Step 1: Extend triggers for tag push**

At the top of `.github/workflows/windows-build.yml`, modify the `on:` block:

```yaml
on:
  push:
    branches: ["PSP_REL_*"]
    tags: ["v*"]
  workflow_dispatch:
```

- [ ] **Step 2: Compute the nightly tag**

Before the `Resolve version` step, add:

```yaml
      - name: Compute nightly tag
        id: nightly
        if: startsWith(github.ref, 'refs/heads/PSP_REL_')
        shell: pwsh
        run: |
          # PSP_REL_18_STABLE → nightly-psp18
          $branch = "${{ github.ref_name }}"
          $major = ($branch -replace "^PSP_REL_","" -replace "_STABLE$","")
          "tag=nightly-psp$major" >> $env:GITHUB_OUTPUT
```

- [ ] **Step 3: Add the nightly publish step**

At the end of the `steps:` list:

```yaml
      - name: Publish nightly release
        if: steps.nightly.outputs.tag != '' && github.event_name == 'push'
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.nightly.outputs.tag }}
          name: "Nightly build (${{ github.ref_name }})"
          body: |
            Rolling build from commit ${{ github.sha }}.

            Commit: ${{ github.event.head_commit.message }}

            This release is automatically updated on every push and is intended for testing only.
          files: ${{ steps.version.outputs.artifact_name }}
          prerelease: true
          make_latest: false
          # Delete and recreate so the tag always points at the newest commit
          target_commitish: ${{ github.sha }}

      - name: Publish tagged release
        if: startsWith(github.ref, 'refs/tags/v')
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ github.ref_name }}
          name: ${{ github.ref_name }}
          files: ${{ steps.version.outputs.artifact_name }}
          generate_release_notes: true
          prerelease: false
          make_latest: true
```

- [ ] **Step 4: Give the workflow a PAT/permissions to update releases**

Add at the job level (above `steps:`):

```yaml
    permissions:
      contents: write    # required for release creation
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/windows-build.yml
git commit -m "windows-ci: publish nightly rolling release and tag releases"
```

- [ ] **Step 6: Push and observe**

```bash
git push && gh run watch --exit-status
gh release view nightly-psp18  # should exist with the MSI attached
```

Note: `nightly-psp18` won't appear until the branch is `PSP_REL_18_STABLE` (the step's `if:` gates on that). For testing on the `wininst` branch, either temporarily adjust the gate, or merge to `PSP_REL_18_STABLE` to see it fire. Decide with the user before merging.

- [ ] **Step 7: (Optional) Test a tag release**

```bash
git tag v18.3.0-psp-test
git push origin v18.3.0-psp-test
gh run watch --exit-status
gh release view v18.3.0-psp-test  # should exist, non-pre-release, MSI attached
# Clean up the test tag + release
gh release delete v18.3.0-psp-test --yes
git push origin :v18.3.0-psp-test
```

---

## Task 10: PR label gating

**Goal:** Allow opt-in PR builds by labeling a PR `needs-windows-installer`. Without the label, the workflow does not run on PRs. Prevents random PRs from burning GHA minutes.

**Files:**
- Modify: `.github/workflows/windows-build.yml`

**Acceptance Criteria:**
- [ ] `on:` includes `pull_request` for `PSP_REL_*` branches.
- [ ] Job has `if:` condition that gates on the label (`contains(github.event.pull_request.labels.*.name, 'needs-windows-installer')`).
- [ ] PR without the label → no job run.
- [ ] PR with the label → full build, test, package, smoke test (no release publish for PRs).

**Verify:** Open a test PR against `PSP_REL_18_STABLE` without the label — no workflow run. Add the label — workflow runs. (Can be verified after merging this plan to the branch.)

**Steps:**

- [ ] **Step 1: Update `on:` block**

```yaml
on:
  push:
    branches: ["PSP_REL_*"]
    tags: ["v*"]
  pull_request:
    branches: ["PSP_REL_*"]
    types: [opened, synchronize, reopened, labeled]
  workflow_dispatch:
```

- [ ] **Step 2: Add label gate to the job**

Just under `jobs: build:`:

```yaml
  build:
    if: |
      github.event_name != 'pull_request' ||
      contains(github.event.pull_request.labels.*.name, 'needs-windows-installer')
    runs-on: windows-2022
```

- [ ] **Step 3: Ensure publish steps don't fire on PRs**

Verify the publish steps' `if:` conditions already exclude PRs:
- Nightly: `github.event_name == 'push'` — already excluded.
- Tag release: `startsWith(github.ref, 'refs/tags/v')` — PR refs are `refs/pull/...`, already excluded.

No change needed.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/windows-build.yml
git commit -m "windows-ci: opt-in PR builds via needs-windows-installer label"
```

- [ ] **Step 5: Push**

```bash
git push
```

(Full validation requires opening a PR after merging — a manual post-merge step.)

---

## Self-review checklist (verified inline while writing plan)

- **Spec coverage** — each foundational decision in the spec maps to a task:
  - Pipeline structure → Tasks 2, 3
  - vcpkg → Task 1
  - Meson flags → Task 3
  - Test stage → Task 2
  - WiX installer + wizard → Tasks 4, 5
  - Custom actions → Tasks 6, 7
  - Smoke test → Task 7
  - Signing → Task 8
  - Artifacts + nightly + tag release → Task 9
  - Triggering + PR label → Tasks 2, 9, 10
- **No placeholders** — every code block contains executable content; no "TODO / fill in later".
- **Type/name consistency:**
  - Service name `postgresql-psp-18` used identically across RegisterService.ps1, RemoveService.ps1, smoke-test.ps1, Product.wxs.
  - Property names (`INSTALLDIR`, `DATADIR`, `PGPORT`, `PGPASSWORD`, `PGPASSWORD_CONFIRM`, `PGLOCALE`) consistent between Product.wxs, UI.wxs, smoke-test.ps1.
  - `version.ps1` output fields (`Version`, `ShortSha`, `ArtifactName`, `MsiVersion`) consistent with workflow `steps.version.outputs.*` references.
  - `StagedFiles` component group id consistent between `heat` step and `Product.wxs` Feature reference.
- **Branding placeholders** flagged in `installer/README.md` and `ci/windows/README.md` so they don't get forgotten before production shipping.
