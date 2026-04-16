# pg_tde Windows Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship pg_tde (`pg_tde.dll` + frontend tools + SQL/control files) inside the existing Percona Server for PostgreSQL 18 Windows MSI, with dedicated PowerShell helpers and a CI workflow that checks out `percona/pg_tde@main` on the fly.

**Architecture:** pg_tde source is fetched via a second `actions/checkout@v4` in CI (or a manual clone locally) and never vendored into the PG repo. Four new PowerShell helpers under `ci/windows/scripts/pg_tde/` configure/build/test/stage pg_tde *after* the main PG build has staged into `C:/stage`. pg_tde's `meson install --destdir` drops its artifacts into that same prefix, so the existing `wix heat` harvest picks them up with zero WXS changes. pg_tde's full TAP suite runs in CI with `continue-on-error: true` so failures surface as logs without blocking the build.

**Tech Stack:** PowerShell 7 (`pwsh`), Pester 5, meson/ninja, vcpkg, WiX 5, GitHub Actions on `windows-2022`.

**Spec:** [docs/superpowers/specs/2026-04-16-pg-tde-windows-integration-design.md](../specs/2026-04-16-pg-tde-windows-integration-design.md)

---

## File structure (new files)

- `ci/windows/scripts/pg_tde/configure.ps1` — meson setup against a staged PG tree
- `ci/windows/scripts/pg_tde/build.ps1` — ninja wrapper
- `ci/windows/scripts/pg_tde/test.ps1` — meson test wrapper (non-throwing)
- `ci/windows/scripts/pg_tde/stage.ps1` — meson install into DestDir
- `ci/windows/scripts/pg_tde/Tests/configure.Tests.ps1`
- `ci/windows/scripts/pg_tde/Tests/build.Tests.ps1`
- `ci/windows/scripts/pg_tde/Tests/test.Tests.ps1`
- `ci/windows/scripts/pg_tde/Tests/stage.Tests.ps1`

## File structure (modified files)

- `ci/windows/vcpkg.json` — add `curl` dependency
- `.github/workflows/windows-build.yml` — add pg_tde checkout + configure/build/test/stage steps, extend Pester path and log-upload globs
- `ci/windows/README.md` — new pg_tde subsection

---

### Task 0: Add libcurl to vcpkg manifest

**Goal:** Ensure vcpkg installs libcurl so pg_tde's `dependency('libcurl')` resolves and `libcurl.dll` ends up beside `pg_tde.dll` in the staged tree.

**Files:**
- Modify: `ci/windows/vcpkg.json`

**Acceptance Criteria:**
- [ ] `ci/windows/vcpkg.json` lists `"curl"` in `dependencies`, alphabetically placed.
- [ ] JSON remains valid (parses with `ConvertFrom-Json`).
- [ ] No other deps are removed or reordered beyond the insertion point.

**Verify:** `Get-Content ci/windows/vcpkg.json | ConvertFrom-Json | Select-Object -ExpandProperty dependencies` must include `curl`.

**Steps:**

- [ ] **Step 1: Edit the manifest**

Replace the current dependencies array so `curl` sits alphabetically between `"libxslt"` and `"openssl"` — actually vcpkg sorts internally, but keep the file sorted for reviewer sanity. The existing order is: `openssl, icu, zlib, zstd, lz4, libxml2, libxslt` (not alphabetical). Preserve the existing style and simply append `"curl"` as the first entry so diffs stay minimal, like so:

```json
{
  "$schema": "https://raw.githubusercontent.com/microsoft/vcpkg-tool/main/docs/vcpkg.schema.json",
  "name": "percona-postgresql-windows",
  "version-string": "18.0.0",
  "description": "Build-time dependencies for Percona Server for PostgreSQL on Windows",
  "dependencies": [
    "curl",
    "openssl",
    "icu",
    "zlib",
    "zstd",
    "lz4",
    "libxml2",
    "libxslt"
  ]
}
```

- [ ] **Step 2: Verify JSON validity**

Run:
```powershell
Get-Content ci/windows/vcpkg.json | ConvertFrom-Json | Select-Object -ExpandProperty dependencies
```
Expected: output lists `curl, openssl, icu, zlib, zstd, lz4, libxml2, libxslt` (one per line).

- [ ] **Step 3: Commit**

```bash
git add ci/windows/vcpkg.json
git commit -m "windows-ci: add curl to vcpkg manifest for pg_tde"
```

---

### Task 1: pg_tde configure helper + Pester tests

**Goal:** A `configure.ps1` that runs `meson setup` on a pg_tde source tree, pointing `pg_config` at a previously-staged PG install and wiring vcpkg pkgconfig/prefix paths identically to the main `configure.ps1`.

**Files:**
- Create: `ci/windows/scripts/pg_tde/configure.ps1`
- Create: `ci/windows/scripts/pg_tde/Tests/configure.Tests.ps1`

**Acceptance Criteria:**
- [ ] Script takes `-SourceDir` (default `../pg_tde` relative to repo root), `-BuildDir` (default `pg_tde_build`), `-StagePrefix` (required), `-MesonArgs` (array), and supports `SupportsShouldProcess`.
- [ ] Script resolves `$StagePrefix/bin/pg_config.exe` and throws a clear error if missing.
- [ ] Script throws a clear error if `$SourceDir/meson.build` is missing.
- [ ] Script dot-sources `../vcpkg.ps1` and reuses `Get-VcpkgInstallRoot` + `Add-VcpkgBinToPath`.
- [ ] Meson invocation includes: `setup <BuildDir> --buildtype=debugoptimized --pkg-config-path=<vcpkg pc> --cmake-prefix-path=<vcpkg root> -Dpg_config=<pg_config.exe>` plus any `$MesonArgs`.
- [ ] Script is no-op on `-WhatIf` (no `build.ninja` created).
- [ ] Pester tests cover: missing StagePrefix, missing pg_config.exe, missing SourceDir, `-WhatIf` short-circuit.

**Verify:** `Invoke-Pester ci/windows/scripts/pg_tde/Tests/configure.Tests.ps1 -PassThru` → `FailedCount -eq 0`.

**Steps:**

- [ ] **Step 1: Write the Pester test first**

Create `ci/windows/scripts/pg_tde/Tests/configure.Tests.ps1`:

```powershell
BeforeAll {
    $script:ConfigureScript = Join-Path $PSScriptRoot '../configure.ps1'
}

Describe 'pg_tde/configure.ps1' {
    It 'throws when -StagePrefix is omitted' {
        { & $script:ConfigureScript -SourceDir $TestDrive } |
            Should -Throw -ExpectedMessage '*StagePrefix*'
    }

    It 'throws when pg_config.exe is missing under StagePrefix/bin' {
        $stage = Join-Path $TestDrive 'empty-stage'
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        # Fake SourceDir so we get past that check
        $src = Join-Path $TestDrive 'src'
        New-Item -ItemType Directory -Path $src | Out-Null
        New-Item -ItemType File -Path (Join-Path $src 'meson.build') | Out-Null
        { & $script:ConfigureScript -SourceDir $src -StagePrefix $stage } |
            Should -Throw -ExpectedMessage '*pg_config*'
    }

    It 'throws when SourceDir has no meson.build' {
        $stage = Join-Path $TestDrive 'stage2'
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $stage 'bin/pg_config.exe') | Out-Null
        $src = Join-Path $TestDrive 'src2'
        New-Item -ItemType Directory -Path $src | Out-Null
        { & $script:ConfigureScript -SourceDir $src -StagePrefix $stage } |
            Should -Throw -ExpectedMessage '*meson.build*'
    }

    It '-WhatIf does not create a build.ninja' {
        $stage = Join-Path $TestDrive 'stage3'
        New-Item -ItemType Directory -Path (Join-Path $stage 'bin') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $stage 'bin/pg_config.exe') | Out-Null
        $src = Join-Path $TestDrive 'src3'
        New-Item -ItemType Directory -Path $src | Out-Null
        New-Item -ItemType File -Path (Join-Path $src 'meson.build') | Out-Null
        $build = Join-Path $TestDrive 'build3'

        # Auto-discovery of vcpkg may still throw; we only care that build.ninja never appears.
        try {
            & $script:ConfigureScript -SourceDir $src -StagePrefix $stage -BuildDir $build -WhatIf
        } catch {}
        Test-Path (Join-Path $build 'build.ninja') | Should -Be $false
    }
}
```

- [ ] **Step 2: Run the test — expect FAIL (script doesn't exist)**

Run:
```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests/configure.Tests.ps1 -PassThru
```
Expected: Every test fails because `configure.ps1` is missing.

- [ ] **Step 3: Write `configure.ps1`**

Create `ci/windows/scripts/pg_tde/configure.ps1`:

```powershell
<#
.SYNOPSIS
    Run meson setup on pg_tde, pointing pg_config at a staged PG install.
.DESCRIPTION
    pg_tde is an out-of-tree meson project that discovers PostgreSQL via
    pg_config. This script locates pg_config.exe under a previously-staged
    PG prefix, wires vcpkg pkgconfig/prefix paths the same way the main
    configure.ps1 does, and runs meson setup against the pg_tde source tree.
.OUTPUTS
    PSCustomObject with SourceDir, BuildDir, PgConfig.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $SourceDir    = (Join-Path $PSScriptRoot '../../../../pg_tde'),
    [string]   $BuildDir     = 'pg_tde_build',
    [Parameter(Mandatory)][string] $StagePrefix,
    [string[]] $MesonArgs    = @()
)

. (Join-Path $PSScriptRoot '../vcpkg.ps1')

# --- 1. Resolve and validate SourceDir ---
$resolvedSource = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($SourceDir)
if (-not (Test-Path (Join-Path $resolvedSource 'meson.build'))) {
    throw "pg_tde meson.build not found at '$resolvedSource/meson.build'. Clone percona/pg_tde there, or pass -SourceDir."
}

# --- 2. Resolve pg_config from StagePrefix ---
$pgConfig = Join-Path $StagePrefix 'bin/pg_config.exe'
if (-not (Test-Path $pgConfig)) {
    throw "pg_config.exe not found at '$pgConfig'. Did you run ci/windows/scripts/stage.ps1 first?"
}

# --- 3. Discover vcpkg (same pattern as main configure.ps1) ---
$vcpkg         = Get-VcpkgInstallRoot
$installRoot   = $vcpkg.InstallRoot
$pkgConfigPath = $vcpkg.PkgConfigPath

Write-Host "pg_tde source:      $resolvedSource"
Write-Host "pg_config:          $pgConfig"
Write-Host "vcpkg install root: $installRoot"

$env:CMAKE_PREFIX_PATH = $installRoot
$env:PKG_CONFIG_PATH   = $pkgConfigPath
Add-VcpkgBinToPath -BinDir $vcpkg.BinDir -Persist

# --- 4. meson setup ---
$mesonSetupArgs = @(
    'setup', $BuildDir,
    '--buildtype=debugoptimized',
    "--pkg-config-path=$pkgConfigPath",
    "--cmake-prefix-path=$installRoot",
    "-Dpg_config=$pgConfig"
)
$mesonSetupArgs += $MesonArgs

if ($PSCmdlet.ShouldProcess("meson setup $BuildDir (pg_tde)", 'Run meson setup')) {
    Push-Location $resolvedSource
    try {
        Write-Host "Running (in $resolvedSource): meson $($mesonSetupArgs -join ' ')"
        & meson @mesonSetupArgs
        if ($LASTEXITCODE -ne 0) {
            throw "meson setup failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

[PSCustomObject]@{
    SourceDir = $resolvedSource
    BuildDir  = $BuildDir
    PgConfig  = $pgConfig
}
```

- [ ] **Step 4: Run the test — expect PASS**

Run:
```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests/configure.Tests.ps1 -PassThru
```
Expected: `FailedCount: 0`, all four tests pass.

- [ ] **Step 5: Commit**

```bash
git add ci/windows/scripts/pg_tde/configure.ps1 ci/windows/scripts/pg_tde/Tests/configure.Tests.ps1
git commit -m "windows-ci: add pg_tde configure.ps1 and Pester tests"
```

---

### Task 2: pg_tde build helper + Pester tests

**Goal:** A thin `build.ps1` that runs `ninja` in the pg_tde build dir, throwing a clear error when the build dir isn't configured.

**Files:**
- Create: `ci/windows/scripts/pg_tde/build.ps1`
- Create: `ci/windows/scripts/pg_tde/Tests/build.Tests.ps1`

**Acceptance Criteria:**
- [ ] Script takes `-BuildDir` (default `pg_tde_build`) and supports `SupportsShouldProcess`.
- [ ] Throws with a message containing `build.ninja` when that file is missing, hinting at `configure.ps1`.
- [ ] Throws if `ninja` exits non-zero.
- [ ] Pester tests cover: missing directory, empty directory without build.ninja.

**Verify:** `Invoke-Pester ci/windows/scripts/pg_tde/Tests/build.Tests.ps1 -PassThru` → `FailedCount -eq 0`.

**Steps:**

- [ ] **Step 1: Write the Pester test first**

Create `ci/windows/scripts/pg_tde/Tests/build.Tests.ps1`:

```powershell
BeforeAll {
    $script:BuildScript = Join-Path $PSScriptRoot '../build.ps1'
}

Describe 'pg_tde/build.ps1' {
    It 'throws when build.ninja is missing (no such dir)' {
        { & $script:BuildScript -BuildDir (Join-Path $TestDrive 'no-such-dir') } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It 'throws when dir exists but has no build.ninja' {
        $emptyDir = Join-Path $TestDrive 'empty-pg_tde-build'
        New-Item -ItemType Directory -Path $emptyDir | Out-Null
        { & $script:BuildScript -BuildDir $emptyDir } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }
}
```

- [ ] **Step 2: Run the test — expect FAIL**

Run:
```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests/build.Tests.ps1 -PassThru
```
Expected: two failures (script doesn't exist).

- [ ] **Step 3: Write `build.ps1`**

Create `ci/windows/scripts/pg_tde/build.ps1`:

```powershell
<#
.SYNOPSIS
    Build pg_tde with ninja.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$BuildDir = 'pg_tde_build'
)

$ninjaFile = Join-Path $BuildDir 'build.ninja'
if (-not (Test-Path $ninjaFile)) {
    throw "build.ninja not found in '$BuildDir'. Run ci/windows/scripts/pg_tde/configure.ps1 first."
}

if ($PSCmdlet.ShouldProcess($BuildDir, 'Run ninja (pg_tde)')) {
    & ninja -C "$BuildDir"
    if ($LASTEXITCODE -ne 0) {
        throw "ninja build failed with exit code $LASTEXITCODE"
    }
}
```

- [ ] **Step 4: Run the test — expect PASS**

```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests/build.Tests.ps1 -PassThru
```
Expected: `FailedCount: 0`.

- [ ] **Step 5: Commit**

```bash
git add ci/windows/scripts/pg_tde/build.ps1 ci/windows/scripts/pg_tde/Tests/build.Tests.ps1
git commit -m "windows-ci: add pg_tde build.ps1 and Pester tests"
```

---

### Task 3: pg_tde test helper + Pester tests

**Goal:** A `test.ps1` that runs `meson test` against the pg_tde build dir, returns `$LASTEXITCODE` without throwing, and puts vcpkg runtime DLLs on PATH so the TAP harness can load libcurl/libssl/etc.

**Files:**
- Create: `ci/windows/scripts/pg_tde/test.ps1`
- Create: `ci/windows/scripts/pg_tde/Tests/test.Tests.ps1`

**Acceptance Criteria:**
- [ ] Parameters: `-BuildDir` (default `pg_tde_build`), `-NumProcesses` (default 4), `-TimeoutMultiplier` (default 1.0 — TAP tests are slow; unlike the main run we don't want to truncate them), `-Suite` (string[]), `-MesonArgs` (string[]).
- [ ] Script dot-sources `../vcpkg.ps1` and best-effort adds vcpkg bin to PATH, warning (not throwing) if discovery fails.
- [ ] Does NOT throw on non-zero `meson test` exit; returns the exit code.
- [ ] Forwards `-Suite` as repeated `--suite <name>` args.
- [ ] Pester tests cover: non-throwing behavior, numeric exit code return.

**Verify:** `Invoke-Pester ci/windows/scripts/pg_tde/Tests/test.Tests.ps1 -PassThru` → `FailedCount -eq 0`.

**Steps:**

- [ ] **Step 1: Write the Pester test first**

Create `ci/windows/scripts/pg_tde/Tests/test.Tests.ps1`:

```powershell
BeforeAll {
    $script:TestScript = Join-Path $PSScriptRoot '../test.ps1'
}

Describe 'pg_tde/test.ps1' {
    It 'does not throw on missing build dir (meson returns non-zero)' {
        { & $script:TestScript -BuildDir (Join-Path $TestDrive 'no-pg_tde-build') } |
            Should -Not -Throw
    }

    It 'returns a numeric exit code' {
        & $script:TestScript -BuildDir (Join-Path $TestDrive 'no-pg_tde-build') 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -BeNullOrEmpty
        $LASTEXITCODE | Should -BeOfType [int]
    }
}
```

- [ ] **Step 2: Run the test — expect FAIL**

```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests/test.Tests.ps1 -PassThru
```
Expected: two failures.

- [ ] **Step 3: Write `test.ps1`**

Create `ci/windows/scripts/pg_tde/test.ps1`:

```powershell
<#
.SYNOPSIS
    Run meson test on pg_tde. Returns exit code; does NOT throw on test failure.
.NOTES
    Callers that want to fail the build on test failure should check $LASTEXITCODE
    or the return value and exit/throw themselves.
#>
[CmdletBinding()]
param(
    [string]   $BuildDir          = 'pg_tde_build',
    [int]      $NumProcesses      = 4,
    [double]   $TimeoutMultiplier = 1.0,
    [string[]] $Suite             = @(),
    [string[]] $MesonArgs         = @()
)

. (Join-Path $PSScriptRoot '../vcpkg.ps1')

# Put vcpkg bin on PATH so pg_tde TAP tests can load libcurl/libssl/libcrypto etc.
try {
    $vcpkg = Get-VcpkgInstallRoot
    Add-VcpkgBinToPath -BinDir $vcpkg.BinDir
} catch {
    Write-Warning "vcpkg bin discovery failed; pg_tde tests will rely on existing PATH: $_"
}

$mesonTestArgs = @(
    'test',
    '-C', $BuildDir,
    '--num-processes', $NumProcesses,
    '--print-errorlogs',
    '--timeout-multiplier', $TimeoutMultiplier
)

foreach ($s in $Suite) {
    $mesonTestArgs += '--suite'
    $mesonTestArgs += $s
}
$mesonTestArgs += $MesonArgs

Write-Host "Running: meson $($mesonTestArgs -join ' ')"
& meson @mesonTestArgs

return $LASTEXITCODE
```

- [ ] **Step 4: Run the test — expect PASS**

```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests/test.Tests.ps1 -PassThru
```
Expected: `FailedCount: 0`.

- [ ] **Step 5: Commit**

```bash
git add ci/windows/scripts/pg_tde/test.ps1 ci/windows/scripts/pg_tde/Tests/test.Tests.ps1
git commit -m "windows-ci: add pg_tde test.ps1 and Pester tests"
```

---

### Task 4: pg_tde stage helper + Pester tests

**Goal:** A `stage.ps1` that runs `meson install --destdir <DestDir>` on the pg_tde build, installing into the same staged tree already populated by the main PG `stage.ps1`. No runtime-DLL copy — the main staging already handled that.

**Files:**
- Create: `ci/windows/scripts/pg_tde/stage.ps1`
- Create: `ci/windows/scripts/pg_tde/Tests/stage.Tests.ps1`

**Acceptance Criteria:**
- [ ] Parameters: `-DestDir` (mandatory), `-BuildDir` (default `pg_tde_build`), supports `SupportsShouldProcess`.
- [ ] Throws with `build.ninja` message when the build dir isn't configured.
- [ ] Runs `meson install -C <BuildDir> --destdir <DestDir>` under `ShouldProcess`.
- [ ] Does NOT attempt to copy runtime DLLs (that's the main `stage.ps1`'s job).
- [ ] Pester tests cover: missing build.ninja, `-WhatIf` skipping install.

**Verify:** `Invoke-Pester ci/windows/scripts/pg_tde/Tests/stage.Tests.ps1 -PassThru` → `FailedCount -eq 0`.

**Steps:**

- [ ] **Step 1: Write the Pester test first**

Create `ci/windows/scripts/pg_tde/Tests/stage.Tests.ps1`:

```powershell
BeforeAll {
    $script:StageScript = Join-Path $PSScriptRoot '../stage.ps1'
}

Describe 'pg_tde/stage.ps1' {
    It 'throws when build.ninja is missing (no such dir)' {
        { & $script:StageScript -DestDir (Join-Path $TestDrive 'stage') -BuildDir (Join-Path $TestDrive 'no-build') } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It 'throws when dir exists but has no build.ninja' {
        $emptyBuild = Join-Path $TestDrive 'empty-pg_tde-build'
        New-Item -ItemType Directory -Path $emptyBuild | Out-Null
        { & $script:StageScript -DestDir (Join-Path $TestDrive 'stage') -BuildDir $emptyBuild } |
            Should -Throw -ExpectedMessage '*build.ninja*'
    }

    It '-WhatIf does not invoke meson install' {
        $build = Join-Path $TestDrive 'fake-pg_tde-build'
        New-Item -ItemType Directory -Path $build | Out-Null
        New-Item -ItemType File -Path (Join-Path $build 'build.ninja') | Out-Null
        $dest = Join-Path $TestDrive 'fake-pg_tde-stage'
        { & $script:StageScript -DestDir $dest -BuildDir $build -WhatIf } | Should -Not -Throw
        # DestDir should not be populated since meson install was skipped
        Test-Path (Join-Path $dest 'bin') | Should -Be $false
    }
}
```

- [ ] **Step 2: Run the test — expect FAIL**

```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests/stage.Tests.ps1 -PassThru
```
Expected: three failures.

- [ ] **Step 3: Write `stage.ps1`**

Create `ci/windows/scripts/pg_tde/stage.ps1`:

```powershell
<#
.SYNOPSIS
    Install pg_tde into an existing staged PG tree via meson install --destdir.
.DESCRIPTION
    Unlike the main ci/windows/scripts/stage.ps1, this script does not copy
    runtime DLLs - the main stage step already dropped them into the staged
    bin/ directory. pg_tde's meson install adds pg_tde.dll, frontend .exes,
    and share/extension/pg_tde* files alongside PG's own artifacts, so the
    existing wix heat harvest picks them up automatically.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$DestDir,
    [string]$BuildDir = 'pg_tde_build'
)

$ninjaFile = Join-Path $BuildDir 'build.ninja'
if (-not (Test-Path $ninjaFile)) {
    throw "build.ninja not found in '$BuildDir'. Run ci/windows/scripts/pg_tde/configure.ps1 and build.ps1 first."
}

if ($PSCmdlet.ShouldProcess($DestDir, "meson install --destdir (pg_tde)")) {
    & meson install -C "$BuildDir" --destdir "$DestDir"
    if ($LASTEXITCODE -ne 0) {
        throw "pg_tde meson install failed with exit code $LASTEXITCODE"
    }
    Write-Host "pg_tde staged into: $DestDir"
}
```

- [ ] **Step 4: Run the test — expect PASS**

```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests/stage.Tests.ps1 -PassThru
```
Expected: `FailedCount: 0`.

- [ ] **Step 5: Commit**

```bash
git add ci/windows/scripts/pg_tde/stage.ps1 ci/windows/scripts/pg_tde/Tests/stage.Tests.ps1
git commit -m "windows-ci: add pg_tde stage.ps1 and Pester tests"
```

---

### Task 5: CI workflow wiring

**Goal:** Extend `.github/workflows/windows-build.yml` so every push that currently triggers the Windows build also: checks out `percona/pg_tde@main`, runs the new Pester tests for pg_tde helpers, configures/builds/tests/stages pg_tde against the staged PG tree, and includes pg_tde's build logs in the uploaded artifact.

**Files:**
- Modify: `.github/workflows/windows-build.yml`

**Acceptance Criteria:**
- [ ] After the existing "Checkout" step, a new "Checkout pg_tde" step clones `percona/pg_tde` at `main` into path `pg_tde`.
- [ ] The Pester step's `-Path` argument includes `ci/windows/scripts/pg_tde/Tests`.
- [ ] Four new steps — "Configure pg_tde", "Build pg_tde", "Test pg_tde", "Stage pg_tde" — appear between "Stage install tree" and "Install WiX 5".
- [ ] The "Test pg_tde" step uses `continue-on-error: true` and `timeout-minutes: 30`.
- [ ] The "Configure pg_tde" step re-uses `${{ steps.stage_prefix.outputs.prefix }}` — BUT the existing "Locate staged prefix" step currently runs *after* "Stage install tree", so we must move pg_tde steps below "Locate staged prefix" rather than directly after "Stage install tree". Plan places them in this exact order: `Stage install tree` → `Locate staged prefix` → `Configure pg_tde` → `Build pg_tde` → `Test pg_tde` → `Stage pg_tde` → `Install WiX 5` → `Resolve version` → `Harvest staged tree` → `Build MSI`.
- [ ] The "Upload test logs" step's `path:` block includes `pg_tde_build/meson-logs/`, `pg_tde_build/testrun/**/log/**`, `pg_tde_build/testrun/**/regress_log/**`.
- [ ] YAML parses (validate with PowerShell's `ConvertFrom-Yaml` if `powershell-yaml` module available, else visual review + CI run).

**Verify:** Push the branch, observe all new steps run, Test pg_tde step does not block downstream steps even on failure, MSI artifact appears.

**Steps:**

- [ ] **Step 1: Insert the pg_tde checkout step**

After the existing "Checkout" step (currently lines 25-27), insert:

```yaml
      - name: Checkout pg_tde
        uses: actions/checkout@v4
        with:
          repository: percona/pg_tde
          ref: main
          path: pg_tde
```

- [ ] **Step 2: Extend the Pester step**

In the "Install Pester and run unit tests" step (currently lines 52-57), change the `-Path` argument from:
```
-Path ci/windows/scripts/Tests, ci/windows/installer/CustomActions/Tests
```
to:
```
-Path ci/windows/scripts/Tests, ci/windows/scripts/pg_tde/Tests, ci/windows/installer/CustomActions/Tests
```

- [ ] **Step 3: Move "Locate staged prefix" earlier**

"Locate staged prefix" currently sits between "Install WiX 5" and "Resolve version" (lines 101-109). Move it so it runs directly after "Stage install tree" and before the new pg_tde steps. The relocated block should appear immediately after the "Stage install tree" step. Its `id: stage_prefix` and `outputs.prefix` work regardless of position.

- [ ] **Step 4: Insert pg_tde build steps**

Directly after the relocated "Locate staged prefix" step, insert:

```yaml
      - name: Configure pg_tde
        shell: pwsh
        env:
          VCPKG_ROOT: ${{ github.workspace }}/vcpkg
        run: |
          ./ci/windows/scripts/pg_tde/configure.ps1 `
            -SourceDir "${{ github.workspace }}/pg_tde" `
            -StagePrefix "${{ steps.stage_prefix.outputs.prefix }}"

      - name: Build pg_tde
        shell: pwsh
        run: ./ci/windows/scripts/pg_tde/build.ps1

      - name: Test pg_tde
        shell: pwsh
        timeout-minutes: 30
        continue-on-error: true
        run: |
          ./ci/windows/scripts/pg_tde/test.ps1
          exit $LASTEXITCODE

      - name: Stage pg_tde
        shell: pwsh
        run: ./ci/windows/scripts/pg_tde/stage.ps1 -DestDir C:/stage
```

- [ ] **Step 5: Extend the test-log upload**

In "Upload test logs" (currently lines 146-158), add three lines to `path:`:

```yaml
            pg_tde_build/meson-logs/
            pg_tde_build/testrun/**/log/**
            pg_tde_build/testrun/**/regress_log/**
```

So the full `path:` block becomes:
```yaml
          path: |
            build/meson-logs/
            build/testrun/**/log/**
            build/testrun/**/regress_log/**
            build/**/crashlog-*.txt
            build/**/*.pdb
            pg_tde_build/meson-logs/
            pg_tde_build/testrun/**/log/**
            pg_tde_build/testrun/**/regress_log/**
```

- [ ] **Step 6: Validate YAML locally**

Run:
```powershell
# If powershell-yaml is installed:
if (Get-Module -ListAvailable -Name powershell-yaml) {
    Get-Content .github/workflows/windows-build.yml -Raw | ConvertFrom-Yaml | Out-Null
    Write-Host "YAML parses cleanly"
} else {
    Write-Host "powershell-yaml not installed; skipping local YAML validation (CI will catch syntax errors)"
}
```
Expected: no errors. If the module isn't installed, CI will fail fast on malformed YAML.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/windows-build.yml
git commit -m "windows-ci: wire pg_tde checkout + build/test/stage into workflow"
```

---

### Task 6: Update README

**Goal:** Document how to build/test pg_tde locally, following the style of the existing "Running locally" section.

**Files:**
- Modify: `ci/windows/README.md`

**Acceptance Criteria:**
- [ ] New "## pg_tde" section appears after the existing "## Running locally (Windows only)" section and before the "## Branding" section.
- [ ] Section states pg_tde lives in a separate repo and must be cloned manually for local builds.
- [ ] Section shows exact commands (clone, configure, build, test, stage).
- [ ] Section notes CI checks out `main` automatically and the user doesn't need to do anything extra.

**Verify:** Visual read — the section reads as a self-contained "how do I build pg_tde locally?" reference.

**Steps:**

- [ ] **Step 1: Insert the pg_tde section**

After the "## Running locally (Windows only)" block (ends with the `Invoke-Pester ci/windows/scripts/Tests` code block around line 44), and before "## Branding", insert:

```markdown
## pg_tde

`pg_tde.dll` ships inside the same MSI but lives in a separate repository
(`percona/pg_tde`). CI checks out `main` automatically via a second
`actions/checkout@v4`; for local builds clone it yourself into a sibling
directory (default expected location: `../pg_tde` relative to the PG repo
root):

```powershell
git clone https://github.com/percona/pg_tde.git ../pg_tde
```

Build against an already-staged PG tree (`stage.ps1` must have run first):

```powershell
./ci/windows/scripts/pg_tde/configure.ps1 -StagePrefix C:/pgsql-stage
./ci/windows/scripts/pg_tde/build.ps1
./ci/windows/scripts/pg_tde/test.ps1                        # full TAP suite
./ci/windows/scripts/pg_tde/test.ps1 -Suite basic           # one suite
./ci/windows/scripts/pg_tde/stage.ps1 -DestDir C:/pgsql-local-stage
```

All four helpers accept `-SourceDir` to point at a pg_tde checkout that
isn't at `../pg_tde`.

Run the pg_tde helper unit tests:

```powershell
Invoke-Pester ci/windows/scripts/pg_tde/Tests
```
```

- [ ] **Step 2: Verify rendering**

Run:
```powershell
Get-Content ci/windows/README.md | Select-String -Pattern '^## '
```
Expected output includes `## Windows CI & Installer` (if present), `## Layout`, `## Running locally (Windows only)`, `## pg_tde`, `## Branding` in that order.

- [ ] **Step 3: Commit**

```bash
git add ci/windows/README.md
git commit -m "windows-ci: document pg_tde helpers in README"
```

---

### Task 7: End-to-end verification

**Goal:** Confirm the merged build actually produces an MSI containing pg_tde's files, and that `CREATE EXTENSION pg_tde` works after installation. This is a verification-only task; it produces no new files.

**Files:**
- Verify only. No edits.

**Acceptance Criteria:**
- [ ] CI run on the branch turns green (or amber — Test pg_tde may fail but build continues).
- [ ] The uploaded MSI artifact, when opened (e.g. via `lessmsi` or `msiexec /a ... TARGETDIR=...` on a Windows box), contains:
  - [ ] `lib\pg_tde.dll`
  - [ ] `bin\pg_tde_upgrade.exe`, `bin\pg_tde_basebackup.exe`, `bin\pg_tde_waldump.exe`, `bin\pg_tde_resetwal.exe`, `bin\pg_tde_rewind.exe`, `bin\pg_tde_checksums.exe`, `bin\pg_tde_change_key_provider.exe`, `bin\pg_tde_archive_decrypt.exe`, `bin\pg_tde_restore_encrypt.exe`
  - [ ] `share\extension\pg_tde.control`
  - [ ] `share\extension\pg_tde--1.0.sql`, `pg_tde--1.0--2.0.sql`, `pg_tde--2.0--2.1.sql`
  - [ ] `bin\libcurl.dll` (or `libcurl-*.dll` depending on vcpkg output)
- [ ] Installing the MSI on a clean VM and running `psql -c "CREATE EXTENSION pg_tde;"` succeeds.
- [ ] pg_tde CI test logs are attached to the `test-logs-<sha>` artifact.

**Verify:**
```bash
# After downloading the MSI artifact:
lessmsi l percona-postgresql-18-*.msi | grep -E 'pg_tde|libcurl'
```
Expected: at least `pg_tde.dll`, 9 `pg_tde_*.exe`, the three SQL files, the `.control` file, and `libcurl*.dll` appear in the listing.

**Steps:**

- [ ] **Step 1: Push the branch to GitHub**

```bash
git push origin wininst
```
Watch the Actions tab. Expect "Test pg_tde" to possibly fail (we accept that — `continue-on-error`), but every other step must stay green.

- [ ] **Step 2: Download the MSI artifact**

From the workflow run page, download `msi-<sha>.zip`, extract, and locate the `.msi`.

- [ ] **Step 3: Inspect the MSI file list**

On a Windows box with `lessmsi` or `wix` installed:
```powershell
lessmsi l percona-postgresql-18-*.msi | Select-String -Pattern 'pg_tde|libcurl'
```
Verify the list contains the files from the Acceptance Criteria above.

- [ ] **Step 4: Install on a clean Windows VM**

On a fresh VM:
```powershell
msiexec /i percona-postgresql-18-*.msi /passive
# After install, start the server (exact commands depend on whether registration ran;
# follow the existing README's local install steps).
& 'C:\Program Files\Percona\PostgreSQL\18\bin\psql.exe' -U postgres -c "CREATE EXTENSION pg_tde;"
```
Expected output: `CREATE EXTENSION`. Failure here indicates something's wrong — likely a missing runtime DLL or SQL script.

- [ ] **Step 5: Review pg_tde test logs**

Download `test-logs-<sha>.zip`. Under `pg_tde_build/testrun/`, inspect a handful of TAP failures (if any) and file follow-up issues for pg_tde-on-Windows problems — these are not plan blockers, they're the signal we wanted by enabling the suite in CI.

- [ ] **Step 6: If verification passes, no commit needed — work is complete. If not, file follow-ups and return to the failing task.**

---

## Self-review notes (executed during plan authoring)

- **Spec coverage:**
  - "Source acquisition via actions/checkout" → Task 5 Step 1. ✓
  - "Sibling default `../pg_tde`" → Tasks 1-4 defaults. ✓
  - "Four helpers under `ci/windows/scripts/pg_tde/`" → Tasks 1-4. ✓
  - "Full TAP suite, continue-on-error" → Task 5 Step 4 ("Test pg_tde" with `continue-on-error: true`, `TimeoutMultiplier` default 1.0). ✓
  - "Always-bundled installer, no WXS changes" → verified via Task 7 MSI inspection; the plan deliberately avoids touching `Product.wxs`. ✓
  - "Add libcurl to vcpkg.json" → Task 0. ✓
  - "Extend README" → Task 6. ✓
  - "Extend test-log upload paths" → Task 5 Step 5. ✓
  - Open question O1 (reuse stage_prefix output vs. re-discover) → resolved by Task 5 Step 3 (move "Locate staged prefix" earlier and reuse its output).
  - Open question O2 (external-service TAP tests) → intentionally left to surface during first CI run; Task 7 Step 5 files follow-ups from the logs.

- **Type consistency:** Parameter names are consistent across helpers — `-BuildDir`, `-DestDir`, `-SourceDir`, `-StagePrefix`, `-NumProcesses`, `-TimeoutMultiplier`, `-Suite`, `-MesonArgs`. Default `BuildDir` is `pg_tde_build` in every script.

- **Placeholder scan:** No "TBD" / "TODO" / "implement later" strings appear. Every code block contains the full content.
