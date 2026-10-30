# OTTO Lite (spike)

The native shell: `zig/core` for the library, nanoui for the window, Win32 for
everything the toolkit does not cover yet.

```
zig/
  core/      library data layer (its own package, `zig build test`)
  app/       this app
  vendor/    nanoui checkout (git-ignored; see below)
```

## Build

nanoui is a path dependency at `zig/vendor/nanoui`:

```powershell
git clone https://github.com/TLBtianhu/nanoui zig/vendor/nanoui   # fork with the Windows patches
cd zig/app
zig build
zig-out/bin/otto-lite.exe fixtures/library.json
```

`fixtures/library.json` is a synthetic 2000-sample electron-store dump; no real
user data is committed.

## Headless check

```powershell
zig-out/bin/otto-lite.exe --nanoui-snapshot=shot.png
```