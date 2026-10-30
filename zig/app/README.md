# OTTO Lite (spike)

The native shell: `zig/core` for the library, nanoui for the window, Win32 for
everything the toolkit does not cover yet.

```
zig/
  core/      library data layer (its own package, `zig build test`)
  ports/     Win32 ports: file watching, shell thumbnails, capability table
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

## Headless checks

```powershell
zig-out/bin/otto-lite.exe --nanoui-snapshot=shot.png       # first frame only
zig-out/bin/otto-lite.exe --nanoui-wait=2 --nanoui-snapshot=shot.png   # after thumbnails land
```

`--nanoui-snapshot` draws before any background fetch can finish, so a real
thumbnail needs `--nanoui-wait` (seconds). Both keep the window hidden.

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
