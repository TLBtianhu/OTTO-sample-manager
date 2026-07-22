# Electron to Tauri Update Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish and locally install one signed 2.6.3 Tauri release that old Electron clients can consume through `latest.yml` and Tauri clients can consume through `latest.json`, with only the Tauri workflow publishing version tags.

**Architecture:** Keep one final Tauri NSIS installer as the release payload and generate both updater manifests from its exact bytes. Preserve the existing Reqwest system-proxy fix, make the legacy Electron workflow manual-only, add release-contract verification, then exercise the final installer with Electron Updater's real NSIS arguments before overwriting the local installation.

**Tech Stack:** Tauri 2, Rust 2024, Reqwest 0.13, Minisign, Electron Updater 6, NSIS, GitHub Actions, Node.js ESM, Vitest, PowerShell.

---

## File Map

- `src-tauri/Cargo.toml` and `src-tauri/Cargo.lock`: Tauri version and Reqwest system-proxy feature.
- `src-tauri/tauri.conf.json`: application version and Tauri update endpoint/public key.
- `package.json` and `package-lock.json`: shared version and release commands.
- `src/services/desktopBridge.ts`: Tauri update state and failed-install recovery.
- `src/services/desktopBridge.tauri.test.ts`: UI-state regression test.
- `src-tauri/tests/updater_network_features.rs`: resolved Reqwest feature regression test.
- `.github/workflows/publish-windows.yml`: manual-only legacy Electron workflow.
- `.github/workflows/tauri-windows.yml`: sole tag publisher and four-file release pipeline.
- `scripts/generate-tauri-update-manifests.mjs`: dual-manifest generator.
- `scripts/verify-tauri-update-artifacts.mjs`: final four-file consistency verifier.
- `src-tauri/examples/verify_update_signature.rs`: Minisign verification using the same library as the Tauri updater.
- `electron/main/services/releaseVersionConsistency.test.ts`: production version contract.
- `electron/main/services/releaseWorkflow.test.ts`: workflow trigger and publishing contract.
- `electron/main/services/tauriUpdateManifest.test.ts`: dual-manifest generator coverage.
- `electron/main/services/tauriUpdateArtifactVerifier.test.ts`: release verifier fixture coverage.
- `scripts/verify-electron-tauri-install.ps1`: isolated NSIS compatibility test using Electron Updater arguments.
- `AGENTS.md`: signing path and cryptographic verification rules.

### Task 1: Preserve the confirmed updater fixes

**Files:**
- Modify: `AGENTS.md`
- Modify: `src-tauri/Cargo.toml`
- Modify: `src-tauri/Cargo.lock`
- Modify: `src/services/desktopBridge.ts`
- Modify: `src/services/desktopBridge.tauri.test.ts`
- Create: `src-tauri/tests/updater_network_features.rs`

- [ ] **Step 1: Run the focused frontend regression test**

Run:

```powershell
npx vitest run src/services/desktopBridge.tauri.test.ts
```

Expected: one passing test proving failed `downloadAndInstall()` changes state to
`error`, restores `download-and-restart`, and does not reject the UI action.

- [ ] **Step 2: Run the resolved-feature regression test**

Run:

```powershell
cargo test --manifest-path src-tauri/Cargo.toml --locked --test updater_network_features
```

Expected: one passing test proving Reqwest 0.13 resolves `system-proxy`.

- [ ] **Step 3: Confirm the production changes are minimal**

The dependency must remain:

```toml
reqwest = { version = "0.13", default-features = false, features = ["system-proxy"] }
```

The updater catch block must publish the error state without rethrowing:

```ts
} catch (error) {
  publishUpdate({
    phase: 'error',
    progressPercent: null,
    message: error instanceof Error ? error.message : String(error),
    action: 'download-and-restart',
  })
}
```

- [ ] **Step 4: Commit the confirmed fixes**

```powershell
git add AGENTS.md src-tauri/Cargo.toml src-tauri/Cargo.lock src-tauri/tests/updater_network_features.rs src/services/desktopBridge.ts src/services/desktopBridge.tauri.test.ts
git commit -m "fix: support Windows proxy in Tauri updater"
```

### Task 2: Make 2.6.3 the single release version

**Files:**
- Create: `electron/main/services/releaseVersionConsistency.test.ts`
- Modify: `package.json`
- Modify: `package-lock.json`
- Modify: `src-tauri/Cargo.toml`
- Modify: `src-tauri/Cargo.lock`
- Modify: `src-tauri/tauri.conf.json`

- [ ] **Step 1: Write the failing version-contract test**

```ts
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

describe('2.6.3 release version contract', () => {
  it('keeps npm, Cargo, Tauri, and release commands on one version', () => {
    const packageJson = JSON.parse(readFileSync('package.json', 'utf8'))
    const tauriConfig = JSON.parse(readFileSync('src-tauri/tauri.conf.json', 'utf8'))
    const cargoToml = readFileSync('src-tauri/Cargo.toml', 'utf8')

    expect(packageJson.version).toBe('2.6.3')
    expect(tauriConfig.version).toBe('2.6.3')
    expect(cargoToml).toMatch(/^version = "2\.6\.3"$/m)
    expect(packageJson.scripts['tauri:verify:release']).toContain('_2.6.3_')
    expect(packageJson.scripts['tauri:verify:release']).toContain('--expected-version 2.6.3')
    expect(packageJson.scripts['tauri:manifests:release']).toContain('_2.6.3_')
    expect(packageJson.scripts['tauri:manifests:release']).toContain('--version 2.6.3')
  })
})
```

- [ ] **Step 2: Run the test and observe the expected failure**

Run:

```powershell
npx vitest run electron/main/services/releaseVersionConsistency.test.ts
```

Expected: FAIL because the repository still declares 2.6.2.

- [ ] **Step 3: Update every production version declaration**

Change the package, lockfile root package, Cargo package, Cargo lock root package,
Tauri config, installer paths, asset name, release notes, and expected version to
2.6.3. The release commands must resolve these paths:

```json
"tauri:verify:release": "node scripts/verify-tauri-release.mjs --exe src-tauri/target/release/otto-sample-manager.exe --installer src-tauri/target/release/bundle/nsis/采样管理器_2.6.3_x64-setup.exe --expected-version 2.6.3",
"tauri:manifests:release": "node scripts/generate-tauri-update-manifests.mjs --installer src-tauri/target/release/bundle/nsis/采样管理器_2.6.3_x64-setup.exe --signature src-tauri/target/release/bundle/nsis/采样管理器_2.6.3_x64-setup.exe.sig --version 2.6.3 --asset-name _2.6.3_x64-setup.exe --repository ywb2164/OTTO-sample-manager --notes \"OTTO Sample Manager 2.6.3：修复跨 Electron/Tauri 更新发布与 Windows 系统代理检查。\" --output-dir release/2.6.3"
```

- [ ] **Step 4: Run the focused test and Cargo metadata**

```powershell
npx vitest run electron/main/services/releaseVersionConsistency.test.ts
cargo metadata --manifest-path src-tauri/Cargo.toml --format-version 1 --offline | Out-Null
```

Expected: PASS and a lockfile whose root package version is 2.6.3.

- [ ] **Step 5: Commit the version change**

```powershell
git add package.json package-lock.json src-tauri/Cargo.toml src-tauri/Cargo.lock src-tauri/tauri.conf.json electron/main/services/releaseVersionConsistency.test.ts
git commit -m "chore: prepare 2.6.3 compatibility release"
```

### Task 3: Make the Tauri workflow the only tag publisher

**Files:**
- Create: `electron/main/services/releaseWorkflow.test.ts`
- Modify: `.github/workflows/publish-windows.yml`
- Modify: `.github/workflows/tauri-windows.yml`

- [ ] **Step 1: Write the failing workflow-contract test**

```ts
import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

describe('Windows release workflows', () => {
  it('keeps Electron manual-only and gives Tauri sole tag ownership', () => {
    const legacy = readFileSync('.github/workflows/publish-windows.yml', 'utf8')
    const tauri = readFileSync('.github/workflows/tauri-windows.yml', 'utf8')

    expect(legacy).not.toMatch(/^\s*push:\s*$/m)
    expect(legacy).toMatch(/^\s*workflow_dispatch:\s*$/m)
    expect(tauri).toContain("tags:\n      - 'v*'")
    expect(tauri).toContain('npm run tauri:manifests:release')
    expect(tauri).toContain('npm run tauri:verify:update-artifacts')
    expect(tauri).toContain('gh release upload')
    expect(tauri).toContain('gh release edit')
  })
})
```

- [ ] **Step 2: Run the test and observe the expected failure**

```powershell
npx vitest run electron/main/services/releaseWorkflow.test.ts
```

Expected: FAIL because the legacy workflow still owns tag pushes and the Tauri
workflow does not generate/verify/upload the compatibility manifests.

- [ ] **Step 3: Restrict the legacy workflow**

Replace its trigger with:

```yaml
on:
  workflow_dispatch:
```

Remove tag-only release finalization from the legacy workflow. Keep its manual
Electron build behavior available for historical testing.

- [ ] **Step 4: Complete the signed Tauri release job**

After `tauri-apps/tauri-action`, add steps that run:

```yaml
- name: Generate Electron and Tauri update manifests
  run: npm run tauri:manifests:release

- name: Verify final update artifacts
  run: npm run tauri:verify:update-artifacts

- name: Upload compatibility release files
  shell: pwsh
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    gh release upload "${{ github.ref_name }}" `
      release/2.6.3/_2.6.3_x64-setup.exe `
      release/2.6.3/_2.6.3_x64-setup.exe.sig `
      release/2.6.3/latest.json `
      release/2.6.3/latest.yml `
      --clobber

- name: Publish release
  shell: pwsh
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: gh release edit "${{ github.ref_name }}" --draft=false --latest
```

- [ ] **Step 5: Run the workflow test**

```powershell
npx vitest run electron/main/services/releaseWorkflow.test.ts
```

Expected: PASS.

- [ ] **Step 6: Commit workflow isolation**

```powershell
git add .github/workflows/publish-windows.yml .github/workflows/tauri-windows.yml electron/main/services/releaseWorkflow.test.ts
git commit -m "ci: make Tauri the sole Windows tag publisher"
```

### Task 4: Verify the complete four-file release contract

**Files:**
- Create: `scripts/verify-tauri-update-artifacts.mjs`
- Create: `src-tauri/examples/verify_update_signature.rs`
- Create: `electron/main/services/tauriUpdateArtifactVerifier.test.ts`
- Modify: `src-tauri/Cargo.toml`
- Modify: `src-tauri/Cargo.lock`
- Modify: `package.json`

- [ ] **Step 1: Write a failing verifier test**

The test creates a temporary installer, signature, public-key config,
`latest.json`, and `latest.yml`, then invokes the verifier. It first asserts a
valid known Minisign fixture exits zero, then changes the installer bytes and
asserts non-zero with `signature verification failed` or `SHA-512 mismatch`.

```ts
const result = spawnSync(process.execPath, [
  verifier,
  '--installer', installer,
  '--signature', signature,
  '--latest-json', latestJson,
  '--latest-yml', latestYml,
  '--tauri-config', tauriConfig,
  '--expected-version', '2.6.3',
], { encoding: 'utf8' })
expect(result.status).toBe(0)
```

- [ ] **Step 2: Run the test and observe the expected failure**

```powershell
npx vitest run electron/main/services/tauriUpdateArtifactVerifier.test.ts
```

Expected: FAIL because `scripts/verify-tauri-update-artifacts.mjs` does not exist.

- [ ] **Step 3: Implement the Rust signature verifier**

Add development dependencies:

```toml
base64 = "0.22"
minisign-verify = "0.2"
```

The example must decode Tauri's outer base64 public key and signature, call
`PublicKey::verify(installer, signature, true)`, print a short success message,
and exit non-zero on invalid input. It accepts exactly three positional paths:
public-key file, installer, and signature.

- [ ] **Step 4: Implement the structured artifact verifier**

The Node verifier must use `JSON.parse` for `latest.json` and `js-yaml` for
`latest.yml`. It checks version, both Tauri platform URLs/signatures, Electron
URL/path, byte size, SHA-512, and exact signature-file content, then invokes:

```powershell
cargo run --quiet --manifest-path src-tauri/Cargo.toml --example verify_update_signature -- <public-key> <installer> <signature>
```

Add this package command:

```json
"tauri:verify:update-artifacts": "node scripts/verify-tauri-update-artifacts.mjs --installer release/2.6.3/_2.6.3_x64-setup.exe --signature release/2.6.3/_2.6.3_x64-setup.exe.sig --latest-json release/2.6.3/latest.json --latest-yml release/2.6.3/latest.yml --tauri-config src-tauri/tauri.conf.json --expected-version 2.6.3"
```

- [ ] **Step 5: Run the verifier tests**

```powershell
npx vitest run electron/main/services/tauriUpdateArtifactVerifier.test.ts electron/main/services/tauriUpdateManifest.test.ts
```

Expected: PASS for valid fixtures and rejection of modified bytes.

- [ ] **Step 6: Commit the release verifier**

```powershell
git add scripts/verify-tauri-update-artifacts.mjs src-tauri/examples/verify_update_signature.rs electron/main/services/tauriUpdateArtifactVerifier.test.ts src-tauri/Cargo.toml src-tauri/Cargo.lock package.json package-lock.json
git commit -m "test: enforce signed dual-updater release contract"
```

### Task 5: Build and verify the signed 2.6.3 release

**Files:**
- Create: `release/2.6.3/_2.6.3_x64-setup.exe` (ignored release artifact)
- Create: `release/2.6.3/_2.6.3_x64-setup.exe.sig` (ignored release artifact)
- Create: `release/2.6.3/latest.json` (ignored release artifact)
- Create: `release/2.6.3/latest.yml` (ignored release artifact)

- [ ] **Step 1: Run all source verification before signing**

```powershell
npm test
npm run check:types
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo test --manifest-path src-tauri/Cargo.toml --all-targets --locked
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets --locked -- -D warnings
```

Expected: all commands exit zero.

- [ ] **Step 2: Recover the approved signing password in memory**

Use only the sources allowed by `AGENTS.md`. Require exactly one explicit value,
set it only in the signing process, and never print it or write it to disk.

- [ ] **Step 3: Build with the correct private-key path variable**

```powershell
$env:TAURI_SIGNING_PRIVATE_KEY_PATH = (Resolve-Path 'src-tauri/keys/otto-updater.key').Path
$env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = $recoveredPassword
npm run tauri:build:release
```

Remove both environment variables in a `finally` block.

- [ ] **Step 4: Sign the final installer explicitly**

Use `tauri signer sign --private-key-path` against the final NSIS installer. This
prevents a path from being interpreted as private-key contents and ensures the
signature covers the bytes that will be uploaded.

- [ ] **Step 5: Generate and verify all four files**

```powershell
npm run tauri:verify:release
npm run tauri:manifests:release
npm run tauri:verify:update-artifacts
```

Expected: version 2.6.3, GUI subsystem 2, matching installer/signature, valid
Minisign verification, and matching JSON/YAML metadata.

### Task 6: Prove Electron-to-Tauri NSIS compatibility

**Files:**
- Create: `scripts/verify-electron-tauri-install.ps1`
- Modify: `package.json`

- [ ] **Step 1: Implement the isolated compatibility runner**

The script accepts installer and expected-version arguments, creates a unique
directory under `$env:TEMP`, validates that the resolved directory remains under
that root, and runs:

```powershell
& $Installer '--updated' '/S' '--force-run' "/D=$installRoot"
```

It waits for installer completion, locates `otto-sample-manager.exe`, invokes
`scripts/verify-tauri-release.mjs` with `--installed-exe`, records the executable
version/subsystem, stops only a process whose executable path is inside the test
directory, runs the generated uninstaller if present, and finally removes only
the validated test directory.

- [ ] **Step 2: Add the package command**

```json
"tauri:verify:electron-migration": "powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-electron-tauri-install.ps1 -Installer src-tauri/target/release/bundle/nsis/采样管理器_2.6.3_x64-setup.exe -ExpectedVersion 2.6.3"
```

- [ ] **Step 3: Run the real compatibility test**

```powershell
npm run tauri:verify:electron-migration
```

Expected: exit zero and a report showing a 2.6.3 GUI executable installed into
the isolated `/D` directory.

- [ ] **Step 4: Commit the compatibility runner**

```powershell
git add scripts/verify-electron-tauri-install.ps1 package.json package-lock.json
git commit -m "test: verify Electron updater can launch Tauri installer"
```

### Task 7: Recover the local installation and verify the real application

**Files:**
- Replace through NSIS: `E:\采样管理器\otto-sample-manager.exe`
- Preserve: `%APPDATA%\sample-manager`, `E:\采样管理器\Copy`, and all user data

- [ ] **Step 1: Capture the pre-install evidence**

Record the installed executable path, version, size, SHA-256, and timestamps.
Record hashes/listings of the SQLite/JSON data files without reading or changing
their contents.

- [ ] **Step 2: Stop only the running old application**

If an OTTO process exists, resolve its executable path and stop it only when the
path equals `E:\采样管理器\otto-sample-manager.exe`.

- [ ] **Step 3: Run the verified installer against the existing directory**

```powershell
& 'release/2.6.3/_2.6.3_x64-setup.exe' '/S' "/D=E:\采样管理器"
```

Wait for completion and do not delete the old directory or user data first.

- [ ] **Step 4: Verify the installed binary and preserved data**

Run `scripts/verify-tauri-release.mjs` with `--installed-exe`, confirm version
2.6.3 and GUI subsystem 2, and compare pre/post data hashes/listings.

- [ ] **Step 5: Launch the installed application and check updates**

Start `E:\采样管理器\otto-sample-manager.exe`, invoke a manual update check, and
confirm the result is `up-to-date` rather than a request error. Read the running
process path to prove the shortcut and process use the installed 2.6.3 binary.

- [ ] **Step 6: Final verification and handoff**

```powershell
git diff --check
git status --short
```

Report the four `release/2.6.3` files, installer size and SHA-256, all executed
test/build results, workflow behavior, local installed executable evidence, and
any remaining limitation for already shipped clients that cannot reach GitHub.
