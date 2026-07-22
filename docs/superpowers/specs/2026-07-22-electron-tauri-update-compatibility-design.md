# Electron to Tauri Update Compatibility Design

## Goal

Publish one signed Windows 2.6.3 release that supports both update clients without
allowing the legacy Electron workflow to compete with the Tauri release workflow.
Electron 2.5.0 reads `latest.yml`; Tauri reads `latest.json`. Both manifests point
to the same final Tauri NSIS installer.

The affected local Tauri 2.6.2 executable cannot repair its own HTTP client before
an update check succeeds, so the verified 2.6.3 installer will also be installed
over `E:\采样管理器` as the local recovery step.

## Confirmed Causes

1. The installed `E:\采样管理器\otto-sample-manager.exe` is an older 2.6.2
   binary even though it has the same visible version as the rebuilt release.
2. The older Tauri binary does not include Reqwest system proxy discovery and
   fails before it can read `latest.json` on the affected machine.
3. `.github/workflows/publish-windows.yml` and
   `.github/workflows/tauri-windows.yml` both react to version tags. The legacy
   Electron workflow can fail or publish competing assets while a Tauri release
   is being prepared.
4. Electron and Tauri require different metadata formats, but the repository
   already has the correct shared release model: `latest.yml` for Electron and
   `latest.json` plus Minisign for Tauri.

## Release Architecture

Version 2.6.3 will be declared consistently in `package.json`,
`src-tauri/Cargo.toml`, `src-tauri/tauri.conf.json`, the lockfile, release scripts,
and tests.

The authoritative release set contains exactly four files:

- `_2.6.3_x64-setup.exe`
- `_2.6.3_x64-setup.exe.sig`
- `latest.json`
- `latest.yml`

`latest.json` contains the Tauri updater platforms and the Minisign signature.
`latest.yml` contains the same installer's SHA-512, byte size, and URL for
Electron Updater. The generator must produce both manifests from the final
installer and final signature in one invocation.

The Tauri tag workflow is the sole automatic publisher for version tags. It
builds the signed installer, explicitly verifies the final Minisign signature,
generates both manifests, checks their consistency, and uploads the four files
to one GitHub Release. The legacy Electron workflow remains available only by
manual dispatch for historical builds and cannot edit the latest Tauri release.

## Client Flows

### Electron 2.5.0

Electron Updater resolves `latest.yml`, sees 2.6.3, downloads the complete Tauri
NSIS installer, and validates the declared SHA-512. No blockmap is required; a
full download is acceptable for the approximately 6 MiB installer.

Before publishing, the actual Tauri installer must be exercised with Electron
Updater's argument contract: `--updated`, `/S`, `--force-run`, and an explicit
`/D=<temporary directory>`. The test must confirm a successful process exit,
the expected 2.6.3 application executable, and a GUI subsystem binary. Unknown
Electron-specific arguments may be ignored only if installation and launch
behavior remain correct.

The application identifier remains `com.ywb2164.otto-sample-manager`, and the
Tauri application continues to read `%APPDATA%\sample-manager`, preserving the
existing data migration path. The compatibility test must not use or delete the
real user data directory.

### Tauri 2.6.2 and Later

Tauri resolves `latest.json`, compares semantic versions, downloads the same
installer, verifies its Minisign signature, installs it, and restarts. Reqwest's
`system-proxy` feature remains mandatory and covered by a resolved-feature test.

The already installed broken 2.6.2 cannot be guaranteed to reach the manifest,
so this machine receives 2.6.3 through a direct verified overwrite install. After
installation, the application must report 2.6.3 and a manual update check must
reach the GitHub manifest and report up to date.

## Failure Handling

- A metadata request failure leaves the UI in an error state with retry available;
  it must never remain in a checking or installing spinner indefinitely.
- A mismatched SHA-512, byte size, URL, version, or Minisign signature blocks
  publication.
- A cross-installer compatibility failure blocks the 2.6.3 release rather than
  falling back to an unverified automatic migration.
- A local overwrite failure must preserve the existing executable, user data,
  SQLite database, JSON data, and Copy directories.
- The legacy workflow must not publish or mark a release latest on a tag event.

## Verification

Automated verification includes focused red-green tests for version consistency,
workflow trigger isolation, dual-manifest generation, Reqwest system proxy
resolution, and updater error-state behavior. The full JavaScript tests,
TypeScript checks, Rust tests, formatting, clippy, renderer build, and signed Tauri
release build must pass.

Release verification includes:

- installer version, PE GUI subsystem, byte size, and SHA-256;
- cryptographic Minisign verification against the configured updater public key;
- equality between the built and release installer/signature;
- `latest.json` signature and URL consistency;
- `latest.yml` version, URL, SHA-512, and size consistency;
- a real isolated NSIS installation using Electron Updater arguments;
- an overwrite install to `E:\采样管理器` followed by installed-binary and update
  check verification.

## Non-goals

- Do not introduce a second migration signing key or activate the unused custom
  `TauriMigrationService` path.
- Do not publish a second Electron bridge installer.
- Do not delete historical releases, tags, user data, or Copy contents.
- Do not refactor unrelated application features.
