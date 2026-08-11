# Windows Drag and Drop Research

This directory contains the black-box investigation for OTTO Sample Manager to
Melodyne 3 drag/drop compatibility. The tools use documented Win32 OLE and
Shell APIs. They do not patch Melodyne, inspect licensing code, or modify the
Melodyne installation.

## Environment

- OS build: Windows NT `10.0.26100`, 64-bit
- Melodyne: `D:\melodyne3\Melodyne.exe`, version `3.2.2.2`, x86
- Melodyne integrity: Medium (`0x2000`)
- OTTO/Electron build: x64, Medium integrity
- Source revision: `origin/main` commit `8e541f0`

The matching integrity levels rule out a UIPI elevation boundary in the tested
configuration.

## Build

```powershell
.\build.ps1
```

The research build produces x86 and x64 `DropInspector.exe` and
`DragProbe.exe` binaries under `bin`. Generated binaries and object files are
ignored by Git.

## Test Data

```powershell
.\scripts\New-TestData.ps1 -Root C:\otto-dnd-test
```

The Chinese names are assembled from Unicode code points so Windows PowerShell
5.1 cannot reinterpret a UTF-8 source file as ANSI.

## DropInspector

```powershell
.\bin\x86\DropInspector.exe --mode both
.\bin\x86\DropInspector.exe --mode legacy
.\bin\x86\DropInspector.exe --inspect-shell-file C:\otto-dnd-test\ascii\a.wav
```

`both` registers an OLE `IDropTarget` and accepts `WM_DROPFILES`. `legacy`
disables OLE registration so Shell fallback behavior can be tested directly.
The inspector enumerates every `FORMATETC`, calls `QueryGetData` and `GetData`,
and decodes known Shell formats including `CF_HDROP`.

## DragProbe

```powershell
.\bin\x86\DragProbe.exe --file C:\otto-dnd-test\ascii\a.wav --preset A
.\bin\x64\DragProbe.exe --file C:\otto-dnd-test\ascii\a.wav --preset A
```

Presets add one compatibility layer at a time:

| Preset | Formats |
| --- | --- |
| A | `CF_HDROP` |
| B | A + `Preferred DropEffect` |
| C | B + `FileName` + `FileNameW` |
| D | C + `Shell IDList Array` |
| E | D + `FileGroupDescriptor[A/W]` + `FileContents` |

Every `IDataObject` request and the final `DoDragDrop` result are logged.

## Experiment Matrix

| Source | Target | Result | Evidence |
| --- | --- | --- | --- |
| Explorer | Melodyne 3.2.2 | Success | Baseline observation |
| Original x64 OTTO/Electron | Melodyne 3.2.2 | Imports, then opens Bug Reporter | `fresh-otto-to-melodyne-20260811-171500.png` |
| Explorer Shell object | DropInspector | 6 Shell formats | `shell-dataobject-x86-20260811-165249.log` |
| Original OTTO/Electron | DropInspector | 3 formats; valid Unicode `CF_HDROP` | `otto-to-dropinspector-20260811-170718.log` |
| x86 DragProbe preset A | Melodyne 3.2.2 | Success, no Bug Reporter | `melodyne-preset-A-20260811-165017.log` |
| x64 DragProbe preset A | Melodyne 3.2.2 | Drop completes, then Bug Reporter | `melodyne-x64-preset-A-20260811-171905.log` |
| Fixed OTTO x86 helper | Melodyne 3.2.2 | Controlled automation succeeded for all tested paths | `verified-fix-20260811.log` |
| Fixed OTTO, compatibility off | DropInspector | Original 3-format Electron object unchanged | `default-electron-path-20260811-230453.log` |

## Root Cause

The original Electron data object is structurally valid. Its `CF_HDROP` uses
`TYMED_HGLOBAL`, `DROPFILES.pFiles=20`, `fWide=TRUE`, a Unicode absolute path,
and double-NUL termination. Short ASCII input fails in the same way as Chinese
or longer input, so encoding, path length, and OTTO's automatic-copy contents
are not the root cause.

The discriminating variable is source process bitness:

- x86 `CF_HDROP`-only DragProbe -> Melodyne succeeds.
- x64 `CF_HDROP`-only DragProbe -> OLE reports a successful copy drop, then
  Melodyne 3.2.2 opens its Bug Reporter.
- Original x64 Electron behaves like the x64 probe.

Melodyne 3.2.2 therefore has a cross-bitness compatibility defect in the path
used for a generic 64-bit OLE file source. Explorer's richer Shell data object
avoids that defective path, but the extra Explorer formats are not a Melodyne
requirement: the x86 preset proves that `CF_HDROP` alone is sufficient.

## Explorer vs OTTO

Explorer exposes:

1. `Shell IDList Array`
2. `CF_HDROP`
3. `FileName`
4. `FileContents`
5. `FileNameW`
6. `FileGroupDescriptorW`

Electron exposes:

1. `DragContext`
2. `DragImageBits`
3. `CF_HDROP`

This difference is observable but is not the cause of the crash. Matching the
whole Explorer object would add code without fixing the x64 DragProbe result.

## Melodyne Requirement

The minimum verified data contract is:

- x86 OLE drag source
- one `FORMATETC`: `CF_HDROP`
- `TYMED_HGLOBAL`
- `DVASPECT_CONTENT`
- `lindex=-1`
- `DROPFILES.fWide=TRUE`
- `DROPEFFECT_COPY`

The helper also creates a transparent 16x16 Win32 source window and attaches to
the foreground input thread. This transfers mouse capture from Chromium so the
separate x86 process receives movement and button release during `DoDragDrop`.

## Verified Fix

When the optional **Melodyne 3 compatibility mode** setting is enabled, OTTO
spawns `native/otto-drag-helper.exe` with the selected source or managed-copy
path. The helper is compiled x86 with the static MSVC runtime and exposes only
the minimum verified contract above.

The setting defaults to off. With it off, OTTO still calls Electron
`webContents.startDrag()` exactly as before. Missing helper files also fall back
to the Electron path.

Packaging builds the helper before Electron and installs it as:

```text
resources\native\otto-drag-helper.exe
```

## Evidence

Key observations:

- Melodyne statically imports `RegisterDragDrop`, `DoDragDrop`,
  `DragAcceptFiles`, and `DragQueryFileA/W`.
- x86 preset A receives `QueryGetData(CF_HDROP)` and `GetData(CF_HDROP)`, then
  returns `DRAGDROP_S_DROP` with `COPY`.
- x64 preset A receives the same calls and returns the same OLE result, but the
  application opens Bug Reporter afterward.
- Final helper runs returned exit code `0`, Melodyne stayed responsive, no Bug
  Reporter appeared, and Melodyne generated `.mdd` analysis files.

Controlled acceptance results:

| Case | Result |
| --- | --- |
| Short ASCII original | Pass |
| Same sample dragged again through OTTO managed copy | Pass |
| Real Chinese path `C:\otto-dnd-test\中文路径\中文采样.wav` | Pass |
| 199-character nested path | Pass |
| Automatic-copy logic | Pass; copied WAV and copied `.mdd` both created |
| Compatibility mode off | Pass; no helper process, original Electron formats |
| Unit tests | 13 files, 66 tests passed |
| Type checks | Main and renderer passed |
| Windows package | Setup, portable, and unpacked builds passed |
| Packaged helper architecture | PE machine `0x014C` (x86) |

## Remaining Risks

- A physical user drag with compatibility mode enabled still needs acceptance.
  The reported manual failure on 2026-08-11 used the default Electron path
  because the active settings did not contain `melodyneCompatibilityMode`.
- Other Melodyne 3.x point releases may have different behavior.
- A high-integrity Melodyne process would reintroduce a UIPI boundary.
- Windows releases older than the tested build may differ in OLE focus rules.
- The helper is an additional unsigned executable until release signing is
  configured.
- FL Studio and VEGAS were not installed in the tested environment. Their
  default path was protected by keeping compatibility mode off and was verified
  against DropInspector, but direct application tests remain outstanding.
