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

## Library files (`OTTOLIB` v1)

The positional library argument is opened by **file header**, not by extension:
`OTTOLIB\0` goes through `core.library_binary`, anything that looks like a JSON
object still goes through `core.store` (old electron-store dumps remain
readable). A new library is written as `OTTOLIB` v1: versioned header, fixed
little-endian records, per-string/count limits and a trailing CRC32.

```powershell
# old JSON -> new binary snapshot, atomically (same-dir .tmp + fsync + MoveFileExW)
zig-out/bin/otto-lite.exe --convert fixtures/library.json %TEMP%\big.otto

# format is decided by magic; corrupted files report BadMagic / UnknownVersion /
# Truncated / ChecksumMismatch instead of a generic parse error
zig-out/bin/otto-lite.exe --library-info %TEMP%\big.otto
zig-out/bin/otto-lite.exe --library-info fixtures/library.json

# the UI opens the binary snapshot exactly like a JSON library
zig-out/bin/otto-lite.exe %TEMP%\big.otto --nanoui-wait=2 --nanoui-snapshot=lib.png
```

`--convert` prints `samples=… groups=… folders=… bytes=… write_ms=…`;
`--library-info` prints `format=json|otto samples=… groups=… bytes=…` plus a
`read_ms` line. This first slice does **not** write back from the UI yet.

## Folder import (headless)

```powershell
zig-out/bin/otto-lite.exe --import C:\packs\drums --save %TEMP%\kit.otto
# on top of an existing library (JSON or OTTOLIB, format decided by magic):
zig-out/bin/otto-lite.exe --import C:\packs\drums --library old.otto --save kit.otto
# the UI button's headless entry: same importRun, same save-target rule:
zig-out/bin/otto-lite.exe old.json --import-into C:\packs\drums
```

The UI has the same thing behind a 「导入文件夹」 button next to the search
field: `IFileOpenDialog` picks a folder, `importRun` runs on a worker thread,
and the list is reloaded from the file that was just written. A JSON library is
saved as the sibling `<stem>.otto` and the header flashes 「已转为 OTTOLIB」;
`.otto` is saved in place. `OTTO_NO_DIALOG=1` makes the picker return
`error.Cancelled` before COM is touched, so `--nanoui-script` can click the
button without a real dialog (the real dialog itself needs a human).

Folders can also be dropped on the window (nanoui's `WM_DROPFILES` event,
`drop_ui.zig`): a dropped folder enters `Import.start` — the same worker
thread, state machine and reload as the button. Dropped files are ignored with
one `只接受文件夹` log line; when several folders are dropped, the first is
imported and the rest are logged. `--drop-probe=<path>` posts a synthetic
`DROPFILES` (`fWide`) message to a hidden window and exits when the import is
done, so the whole chain is testable without a mouse.

The pipeline is scan (L0) → probe (L1, header only) → dedupe → merge → atomic
write; it never creates a window or touches nanoui:

- `ports/scan.zig` walks recursively, skips hidden/system entries and `.tmp`,
  and records absolute path, name, extension, size, mtime and the NTFS file
  identity (`GetFileInformationByHandle`). Per-file failures go into a list and
  do not abort the scan; results are sorted by path and deduplicated.
- `ports/probe.zig` reads at most the first 64 KiB. WAV headers are parsed by
  `ports/wav_header.zig`, the same code the player uses (`audio/wav.zig`), so
  there is exactly one chunk scanner. Non-WAV files return `null` and are stored
  with `pendingMetadata = true` — no invented durations.
- ids are `im_` + 16 hex chars of `Wyhash(path)`: stable across runs/machines and
  independent of scan order; collisions get a `_1` suffix.
- duplicates: an existing `filePath` is `skipped_path`; an existing
  volume+file-index under a *different* path (rename/move) is
  `skipped_identity`.

`--save` is also the fallback base library: re-running the same command loads
the output and reports `added=0` instead of starting from scratch. A summary
line goes to stdout:

```text
scanned=12 added=12 skipped_path=0 skipped_identity=0 failed=0 wrote=… bytes=2110 ms=7.32
```

On the M3 fixtures this imports 500 WAVs in **85 ms** (36 ms on re-run) and
2000 WAVs in **297 ms**, including the atomic write. Not in this slice: a
progress bar/cancel button during an import, thumbnail pre-warming, and L1 for
non-WAV formats.

## Thumbnails

Every row asks `src/thumbs.zig` for one 64px thumbnail (32 points) on its left:

1. **cache** (`core.cache.Cache`, kind `.thumbnail`) — hit returns the pixels;
2. **capability gate** (`otto_caps`) — no registered thumbnail handler means
   "no preview", and `thumb.get` is never called;
3. **bounded queue + one worker thread** — only files with a handler are
   fetched, off the UI thread; the queue drops the oldest request when full
   (and counts it).

Pixels are owned by the cache. Rows pin their entry while the frame is drawn
(`view` → `paint`) and unpin at the start of the next frame. `tick` redraws when
the atomic ready counter changes.

### Third-party handlers run in a separate process (M4)

`IShellItemImageFactory::GetImage` loads the handler DLL into the calling
process; a crashing or hanging handler would take OTTO with it. Since M4 the
worker thread calls `ports/thumb_host.zig` instead of `thumb.get` directly:

- `otto-thumb-host.exe` is built by the same `zig build` (two exes, no script);
- the protocol is bytes only: `u32 path_len | path` in, `status | width |
  height | stride | bytes | BGRA` out; no COM pointers cross the boundary;
- lazy start (`CREATE_NO_WINDOW`, hidden, no message loop), one process serves
  every request, per-request timeout of 3 s, one restart + retry when the
  helper dies, and a `KILL_ON_JOB_CLOSE` job so OTTO being killed leaves no
  orphan helper.

`--no-isolation` is the only way back to in-process fetching; it exists for
side-by-side comparison, not as a supported mode. A missing helper is a startup
error with a named message, never a silent fallback.

```powershell
# byte-for-byte parity + 200-image timing, in-process vs helper (no window)
zig-out/bin/otto-lite.exe --thumb-bench C:\src\otto-testkit\samples
# same fixture through the in-process path, for comparison
zig-out/bin/otto-lite.exe --demo-thumbs <dir> --no-isolation
```

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

## Search and keyboard

A full-width field (`搜索素材…`) sits above the list:

- **Ctrl+F** focuses it; **Esc** clears the query and gives the keyboard back;
- typing filters as it goes (no debounce: a 2000-sample library is one pass over
  memory);
- matching is a case-insensitive substring of the **file name**, the same
  `containsIgnoreCase` rule as `core.query`: `core.query.matchingIndices` gives
  the row → sample mapping, and the app does not carry a second matcher;
- an empty query shows everything.

The header reads `N 个素材 · M 命中 · K 选中`.

| key | action |
| --- | --- |
| ↑ / ↓ | move the cursor row (clamped at both ends, no wrap) and select that row |
| Home / End | first / last row |
| Enter | preview the cursor row; an audio row starts playing |
| Esc | clear the search first, then the selection |

**Why a filter change clears the selection:** rows are positions, and filtering
renumbers every one of them; a selection kept across a filter change would point
at different files. The list only walks the row → sample-index mapping, while
selection, preview and drag-out stay keyed by sample index — so the selection is
dropped honestly instead of being silently rewritten. The cursor keeps a sample
index of its own: if the old sample is still in the result it stays on it (at its
new row), otherwise it falls back to row 0.

Shift+click selects only the **visible** rows between the anchor and the target:
doing it by sample index would also select filtered-out files the user cannot
see while the count and drag-out would include them.

The preview follows the cursor (so a filtered row can be looked at without a
click); the selection count stays 0 until an arrow key or a click selects it.
The "hit" rows are renumbered from 1 in the filtered list.

Not in this half: pinyin / initials, the input-method (IME) composition path,
matching-substring highlighting and fuzzy matching.

## Headless checks

```powershell
zig-out/bin/otto-lite.exe --nanoui-snapshot=shot.png       # first frame only
zig-out/bin/otto-lite.exe --nanoui-wait=2 --nanoui-snapshot=shot.png   # after thumbnails land

# two selected rows (tint + "N 个素材 · M 命中 · K 选中" header), no input at all:
zig-out/bin/otto-lite.exe --select=0,1 --nanoui-snapshot=sel.png

# the search field: type into it, then ↓↓ and Enter, all headless
zig-out/bin/otto-lite.exe C:\src\otto-testkit\library.json --nanoui-script="chord:ctrl+f;type:img;key:down;key:down;key:enter" --nanoui-snapshot=search.png

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
- Selected rows are tinted; the header reads `N 个素材 · M 命中 · K 选中`.

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
# filter without a window: load → filter → matched=N and the first 3 hits
zig-out/bin/otto-lite.exe C:\src\otto-testkit\library.json --filter=img
#   otto-lite: filter="img" total=12 matched=8
#     1. img00.bmp
#     2. img00.png
#     3. img01.bmp
zig-out/bin/otto-lite.exe C:\src\otto-testkit\library.json --filter=
#   otto-lite: filter="" total=12 matched=12   (empty query = everything)

# file watching: 3 empty wavs → watch → a 4th arrives
zig-out/bin/otto-lite.exe --demo <dir>

# overflow rescan: 3 files → delete/change/add → injected overflow → debounced
# re-scan; prints before=3 after=3 added=1 removed=1 modified=1, then a clean
# second scan must be 0/0/0 (exit 0/1)
zig-out/bin/otto-lite.exe --demo-rescan <dir>

# thumbnail layer: creates red.bmp (real 64×64 BMP), tone.wav and mystery.xyz
# (no handler), fetches them twice, prints the account and exits 0/1
zig-out/bin/otto-lite.exe --demo-thumbs <dir>

# in-process vs isolated helper: per-file byte parity, then 200 images timed
# through both backends (the helper's one process start amortized over 200)
zig-out/bin/otto-lite.exe --thumb-bench C:\src\otto-testkit\samples
```

`--demo-thumbs` also writes `<dir>/library.json`, so the picture it just made can
be looked at:

```powershell
zig-out/bin/otto-lite.exe <dir>/library.json --nanoui-wait=2 --nanoui-snapshot=thumbs.png
```

### Real-window memory (the charter's ≤ 50 MiB line)

`--mem-probe` measures the memory a *real window* holds, not a headless tester:
it builds the same state as a normal start in a 380×700 HWND that is never shown
(no popup, no focus, no taskbar entry), builds the first frame (font scan, glyph
atlas), presents once, scrolls the list until 8 / 50 / 100 thumbnails are cached
and drawn, then idles for `--mem-probe-idle` seconds while the app's own 150 ms
tick keeps running. Each moment prints `WorkingSetSize`, `PrivateUsage`, the
resident pages split by type (image / mapped / private, via
`K32QueryWorkingSet` + `VirtualQuery`), and the layers' own accounts (L2
thumbnails, image atlas, glyph atlas, loaded fonts, canvas, threads, modules).

```powershell
# one command: builds a probe library (2000 rows over 100 real image files) and
# runs the probe twice, isolation on and off  — see zig/MEMORY.md for the tables
powershell -NoProfile -ExecutionPolicy Bypass -File zig\mem.ps1 -Release
```

Frames are presented through GDI by default: measured against the D3D11 flip
swap chain it is 27 MiB smaller and 18× cheaper per present (0.22 ms vs 4.16 ms),
at the cost of vsync. `--d3d` switches back to the flip swap chain.

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

## Settings panel (topmost, opacity, budgets)

The header's 「设置」 entry opens a card over the list. Three kinds of state live
in `<exe dir>\.otto-settings.json` (dev) or `<data dir>\settings.json` (portable /
installed), all with defaults when the field is missing:

```json
{"always_on_top":false,"update_url":null,"l2_budget_mib":64,"l3_budget_mib":256,"opacity":255}
```

| field | effect | when it applies |
| --- | --- | --- |
| `always_on_top` | `SetWindowPos(HWND_TOPMOST, SWP_NOACTIVATE)` | on the click, and once at startup |
| `opacity` | `WS_EX_LAYERED` + `SetLayeredWindowAttributes(LWA_ALPHA)` | on every slider frame (hot), and once at startup |
| `l2_budget_mib` / `l3_budget_mib` | thumbnail caches | on close |
| `update_url` | feed used by 「检查更新」 | on close |

`opacity` is 0..255 (`60%` is 153). At **255 the layered bit is removed** instead
of leaving an alpha=255 layered window: same pixels, but a window nobody has
touched stays on the plain DWM path. `getOpacity` therefore returns `null` for a
fully opaque window — the port documents that (`src/win_window.zig`).

With `--d3d` the alpha may not work: the DXGI flip model is composed by DWM and
ignores `SetLayeredWindowAttributes`. That run prints one
`opacity-d3d-warning` line instead of failing silently; the default GDI present
path is the one that supports it.

```powershell
# one command: real hidden HWND, flags read back from Windows, panel screenshots
powershell -NoProfile -ExecutionPolicy Bypass -File ../opacity.ps1
```

## Update check (M5)

The header has a small 「检查更新」 entry at its right edge. Clicking it starts one
background thread (`ports/feed.zig` → `update_check.zig`), and the result becomes one
line under the header:

| state | header line |
| --- | --- |
| feed is newer | `有新版本 0.2.0` + 「下载」 button |
| downloading | `正在下载… 42%（688/1590 KiB）` or `正在下载… N 字节` when the server sends no length |
| downloaded + verified | `已下载，可安装` + 「安装 0.3.0」 button |
| same version | `已是最新 (0.1.1)` |
| feed is older | `本地版本更新 (0.1.0)` — the local build is newer, so no downgrade is offered |
| any check failure | `检查失败：NetFailure` / `检查失败：InvalidJson` / … |
| any download failure | `签名不匹配` / `大小不符…` / `下载地址不存在` / … (named, never a dialog) |

**Nothing is fetched unless the user clicks.** There is no startup check, no timer and
no retry, and the feed URL is empty by default (`--update-url` or the settings panel).
"A freshly unpacked OTTO has never made a network request" is a
property of the code path, not a promise to remember: `Update.init` only stores the URL,
`tick` only polls a thread that may not exist, and `begin()` has exactly one caller —
the click in `main.zig`'s view.

```powershell
# headless: one check, one line; exit 0 = checked (all three verdicts), 1 = failed
zig-out/bin/otto-lite.exe --check-update file:///C:/feed/latest.json
#   update: available 0.2.0 (current 0.1.1) signature=ok size=1465543 url=https://…
#   update: up_to_date (current 0.1.1) signature=ok
#   update: ahead 0.1.0 (current 0.1.1) signature=ok
#   update: failed error=NetFailure code=12029 http=0

# the UI entry reads the same URL source; the snapshot clicks the real button
zig-out/bin/otto-lite.exe fixtures/library.json --update-url=file:///C:/feed/latest.json ^
  --nanoui-script="click:检查更新;live:1" --nanoui-snapshot=update.png
```

The feed is our own `latest.json` (`update_check.parseFeed` is the only reader):

```json
{
  "version": "0.2.0",
  "notes": "…",
  "pub_date": "2026-11-01T00:00:00Z",
  "platforms": {
    "windows-x86_64": {
      "url": "https://example.com/otto-lite-0.2.0-setup.exe",
      "size": 1465543,
      "signature": "<base64 minisign>"
    }
  }
}
```

`version` is the only compared field and must be `x.y.z` (`core.semver`: no
prerelease suffixes, no leading zeros). `notes` / `pub_date` are for display and may
be missing; `platforms.windows-x86_64` is required because that is the only thing we
ship. `size` is the installer's byte count (to be checked at download time) and
`signature` is the **installer's** minisign signature, not the feed's.

`ports/feed.zig` does the transfer: `http(s)` through WinHTTP (`WinHttpOpen` →
`WinHttpConnect` → `WinHttpOpenRequest` → `WinHttpSendRequest` → `WinHttpReceiveResponse`
→ `WinHttpReadData`), 5 s per phase, redirects followed with
`WINHTTP_OPTION_REDIRECT_POLICY = ALWAYS` and at most 5 hops. It has two exits:
`fetch` reads a whole feed into memory (256 KiB hard limit) and `download` streams
64 KiB chunks into a caller-owned `.part` file (64 MiB hard limit), with the same
`TooLarge` / `NotFound` / `NetFailure` / `BadUrl` names (plus `WriteFailed` for the
file sink). `file://` and plain paths go through both for offline tests.

### Signature: envelope at check time, whole file after download

A check has no installer, so it verifies the **envelope only**: the two base64
layers, the 74-byte structure, the algorithm (`ED` = BLAKE2b-512 then Ed25519,
`Ed` = plain), and that the **key id matches the built-in public key**
(`zig/keys/otto-lite.key.pub`, read at configure time into
`build_options.update_public_key` — one source, no copy). A key-id mismatch fails the
check instead of showing "new version".

Downloading is the next step (`--update-download <feed>` or the header button):

1. fetch the feed again and parse it; reject a declared `size` over 64 MiB;
2. check the envelope before spending bandwidth;
3. stream the installer into `<updates>\otto-lite-<version>-setup.exe.part`
   (`feed.download`, 64 KiB chunks, limit 64 MiB, `TooLarge` past that);
4. `File.sync`, then read the `.part` back in 64 KiB chunks and feed both
   BLAKE2b-512 (for minisign) and SHA-256 (for the report);
5. `verifyPrehashedSignature(public_key, feed.signature, digest)` — the first real
   call to the minisign verifier, over the whole file without loading it into RAM;
6. compare the byte count to `feed.platform.size` (`SizeMismatch` otherwise);
7. only then rename `.part` to the final name. Any failure deletes the `.part`;
   a tampered package never appears under an installable name.

After success the header reads `已下载，可安装` and offers `安装 0.3.0`. Clicking it
calls `ShellExecuteW("open", path)` and **the app exits** so NSIS can replace the
running exe. There is no `/S` silent install and no self-replacement. `--no-exec`
(acceptance only) prints the path and asserts it exists, but never launches it.

Boundaries of this slice: no Authenticode (we have no code-signing certificate; the
minisign signature is the trust root), no incremental update, no resume/range
requests, and only the minisign `ED` variant is streamed (`Ed` needs the whole
message in memory; our artifacts are all `ED`).

A tampered signature, a truncated file, a size mismatch and a `.part` left by an
earlier crash are pinned by `update_download_test.zig` against the real
`otto-lite-0.3.0-setup.exe` + `.sig` (the test skips when `dist/` is absent).

```powershell
# headless: download + verify, no window, never executes the installer
zig-out/bin/otto-lite.exe --update-download file:///C:/feed/latest.json
#   downloaded bytes=1629043 sha256=… verify=ok path=…\updates\otto-lite-0.3.0-setup.exe

# UI snapshot: check -> download -> verified -> (no-exec) install click
zig-out/bin/otto-lite.exe fixtures/library.json --update-url=file:///C:/feed/latest.json ^
  --update-current=0.2.9 --no-exec ^
  --nanoui-script="click:检查更新;live:1;click:下载;live:2;click:安装 0.3.0" ^
  --nanoui-snapshot=update-verified.png
```

`--update-current` is an acceptance probe (like `--select` / `--settings-probe`):
it overrides only the local version used for `decide`, so a historical fixture can
drive the real `available → downloading → verified` path on a newer build.

## Packaging

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ../package.ps1 -Version 0.0.1
```

The script refuses to build when `-Version` does not match `build.zig.zon`, then
verifies the built exe reports the same version. It produces exactly two
artifacts in `zig/dist/`:

- `otto-lite-0.0.1-portable.zip` — `otto-lite.exe`, `otto-thumb-host.exe`,
  `otto-portable.flag`, `README.txt`, `LICENSE`;
- `otto-lite-0.0.1-setup.exe` — NSIS installer (Chinese + English), installs to
  `Program Files\OTTO Lite`, writes no data there, keeps `%APPDATA%\OTTO` on
  uninstall. It is **not** code-signed: SmartScreen will warn on first run.

Both artifacts ship the thumbnail helper next to the main exe; `otto-lite.exe`
refuses to start (with a named error) if `otto-thumb-host.exe` is missing, so a
stripped-down package fails loudly instead of quietly loading third-party
handlers into the app again.

