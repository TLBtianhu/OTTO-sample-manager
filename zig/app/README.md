# OTTO Lite (spike)

The native shell: `zig/core` for the library, nanoui for the window, Win32 for
everything the toolkit does not cover yet.

```
zig/
  core/      library data layer (its own package, `zig build test`)
  ports/     Win32 ports: file watching, shell thumbnails, capability table, drag-out
  app/       this app
  vendor/    nanoui checkout (git-ignored; see below)
```

## Build

nanoui is a path dependency at `zig/vendor/nanoui`:

```powershell
git clone https://github.com/TLBtianhu/nanoui zig/vendor/nanoui   # fork with the Windows patches
cd zig/app
zig build
zig build test
zig-out/bin/otto-lite.exe fixtures/library.json
```

`fixtures/library.json` is a synthetic 2000-sample electron-store dump; no real
user data is committed. Its files (`D:/lib/...`) do not exist on a normal
machine, so the default list shows the "file missing" placeholder in every
thumbnail slot — that is the honest state, not a broken image.

## Thumbnails

Every row asks `src/thumbs.zig` for one 64px thumbnail (32 points) on its left:

1. **cache** (`core.cache.Cache`, kind `.thumbnail`) — hit returns the pixels;
2. **capability gate** (`otto_caps`) — no registered thumbnail handler means
   "no preview", and `thumb.get` is never called;
3. **bounded queue + one worker thread** — only files with a handler are
   fetched, off the UI thread, so a third-party shell handler can't freeze the
   window. The queue drops the oldest request when full (and counts it).

Pixels are owned by the cache. Rows pin their entry while the frame is drawn
(`view` → `paint`) and unpin at the start of the next frame. `tick` redraws when
the atomic ready counter changes.

## Preview and selection

The strip below the list (150 points) has three parts:

- **the preview area** (left slot + outcome text), driven only by the registry;
- **the facts footer** (name / size / duration / extension, then the path), taken
  straight from the `Sample` and always shown, even when there is no preview;
- the registry decides the preview, not the view:

```
src/preview.zig          the contract: Kind / Request / Outcome (5 branches) / Provider / Registry
src/providers/thumb.zig  Windows shell thumbnail, gated by otto_caps
src/providers/root.zig   the one provider list (order = preference)
src/preview_snapshot.zig the Sample copy a worker may keep (no dangling strings)
src/sample_facts.zig     name / size / duration / path / extension — not a provider
src/preview_panel.zig    worker thread + the five-branch strip (the only view)
```

`none.*` is a **decline**, not the final answer: a provider declares "I might
handle this" cheaply in `supports`, and only `open` knows the truth. When `open`
returns `none.*`, the registry asks the next provider; only a success branch
(`image / audio / frames / text`) ends the search. If every provider declines,
the most specific reason wins: `file_missing > failed > no_handler >
unsupported` (no provider claiming the file at all is `unsupported`). That is
how a shell handler which claims `.wav` but yields no bitmap stops hiding the
honest answer.

`Provider.open` is synchronous and may enter a third-party shell handler, so the
panel runs it on its own thread: one pending request, newest wins, results land
through `poll` (the same convention as `thumbs.zig`). A stuck handler blocks
that thread, not the frame. Outcomes are owned by the caller's allocator and
released with `Outcome.deinit`.

The view switches on `image / audio / frames / text / none` only. It never looks
at the file extension: adding an audio or frame provider changes
`providers/root.zig` (and nothing in `main.zig` or `preview_panel.zig`).

`audio` and `frames` are placeholders in M1 (WASAPI and Media Foundation come
next); the branches exist so the view is written once.

```powershell
# facts + what the registry answers for one file, without a window:
zig-out/bin/otto-lite.exe --preview C:\src\otto-testkit\samples\img00.png
#   provider=shell-thumbnail kind=image  →  outcome=image 96x96 stride=384
zig-out/bin/otto-lite.exe --preview C:\src\otto-testkit\samples\tone_440.wav
#   provider=shell-thumbnail kind=image  →  outcome=none reason=no_handler
zig-out/bin/otto-lite.exe --preview C:\src\otto-testkit\samples\mystery.xyz
#   provider=<none> kind=unknown         →  outcome=none reason=unsupported
#   (its facts are printed before the outcome either way)
```

## Headless checks

```powershell
zig-out/bin/otto-lite.exe --nanoui-snapshot=shot.png       # first frame only
zig-out/bin/otto-lite.exe --nanoui-wait=2 --nanoui-snapshot=shot.png   # after thumbnails land

# two selected rows (tint + "N 个素材 · M 选中" header), no input at all:
zig-out/bin/otto-lite.exe --select=0,1 --nanoui-snapshot=sel.png

# a real click through the script runner: row 1, then the empty area below it
# (use a library with fewer rows than fit the window)
zig-out/bin/otto-lite.exe small-library.json --nanoui-script="at:190,60;at:190,500" --nanoui-snapshot=clear.png
```

`--select=0,1` seeds the selection: headless snapshots get no mouse, so it is
the only way to photograph the selected state deterministically. It is a
debug/screenshot flag, not a user-facing selection feature.

`--nanoui-snapshot` draws before any background fetch can finish, so a real
thumbnail (or a preview-strip outcome) needs `--nanoui-wait` (seconds). Both keep
the window hidden. With `--select=<row>` the strip resolves to that row's
registry answer; without a selection it reads `选中一行查看预览`, and before the
worker answers it reads `正在读取预览…`.

## Selecting and dragging out

The list is the only view: select rows, then drag them into a host (FL Studio,
Melodyne, Explorer) or copy them to the clipboard.

- **Click** a row: select only it.
- **Ctrl+click**: toggle that row.
- **Shift+click**: select the range from the anchor (the last clicked row) to
  this one.
- **Click the empty area** below the rows: clear the selection.
- Selected rows are tinted; the header reads `N 个素材 · M 选中`.

**Drag out**: press on a row and move more than 6 points. If the row is part of
the selection, the whole selection is dragged; otherwise only that row. The
drag is staged during the frame (paths are copied into the transport's own
arena) and started right after the frame, by a timer: `DoDragDrop` blocks until
the mouse is released, so it must never run inside `view`. Esc or a drop on an
invalid target is a cancel, not an error (only a log line); OLE failures are
logged too, never shown as a dialog.

**Ctrl+C** puts the selected files on the clipboard (`CF_HDROP`); with nothing
selected it copies the last clicked row. The header flashes
`· 已复制 N 个素材` for 1.5 s.

### Verifying by hand (the only way for real drag and clipboard)

The port itself is exercised headlessly by `--demo-transport`, but a real drop
needs a real host window and real mouse:

```powershell
# 1) select two rows, then drag them onto FL Studio / Melodyne
zig-out/bin/otto-lite.exe fixtures/library.json

# 2) Ctrl+C on a selection, then Ctrl+V in an Explorer folder
#    (the fixture paths do not exist, so use a library of real files)

# 3) clipboard without the UI: explicit, one file, writes CF_HDROP
zig-out/bin/otto-lite.exe --copy-now C:\path\to\a.wav
#    paste in Explorer: the file appears (copied, not moved)

# 4) headless: no clipboard, no OLE drag loop, no window
zig-out/bin/otto-lite.exe --demo-transport
#    prints selected=… paths=… drag_pending=… and checks the validation-only
#    paths of copyToClipboard (empty list, a directory) + ports' selftest
```

## Self-checks

```powershell
# file watching: 3 empty wavs → watch → a 4th arrives
zig-out/bin/otto-lite.exe --demo <dir>

# thumbnail layer: creates red.bmp (real 64×64 BMP), tone.wav and mystery.xyz
# (no handler), fetches them twice, prints the account and exits 0/1
zig-out/bin/otto-lite.exe --demo-thumbs <dir>
```

`--demo-thumbs` also writes `<dir>/library.json`, so the picture it just made can
be looked at:

```powershell
zig-out/bin/otto-lite.exe <dir>/library.json --nanoui-wait=2 --nanoui-snapshot=thumbs.png
```

## Version and run modes

`build.zig.zon` is the only place the version is written. `build.zig` reads
`.version` at configure time and injects it as `build_options.version`, so the
binary cannot disagree with the manifest:

```powershell
zig-out/bin/otto-lite.exe --version     # otto-lite 0.0.1 (dev)
```

The mode is detected from the executable itself (`src/mode.zig`), never from the
working directory or a path guess:

| mode | judgement | data directory |
| --- | --- | --- |
| dev | exe path contains a whole `zig-out` segment | none — default library is `fixtures/library.json` |
| portable | `otto-portable.flag` next to the exe | `<exe dir>\data` |
| installed | everything else | `%APPDATA%\OTTO` |

`--version` prints the mode in parentheses and exits 0; it never opens the
library or a window, so it works on a freshly unpacked portable copy.

## Packaging

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ../package.ps1 -Version 0.0.1
```

The script refuses to build when `-Version` does not match `build.zig.zon`, then
verifies the built exe reports the same version. It produces exactly two
artifacts in `zig/dist/`:

- `otto-lite-0.0.1-portable.zip` — `otto-lite.exe`, `otto-portable.flag`,
  `README.txt`, `LICENSE`;
- `otto-lite-0.0.1-setup.exe` — NSIS installer (Chinese + English), installs to
  `Program Files\OTTO Lite`, writes no data there, keeps `%APPDATA%\OTTO` on
  uninstall. It is **not** code-signed: SmartScreen will warn on first run.

