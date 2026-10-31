# One command: build OTTO Lite, then verify all three run forms (CHARTER section 9)
# end to end, in real processes:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\verify-distribution.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\verify-distribution.ps1 -SkipBuild
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\verify-distribution.ps1 -Release
#   powershell -NoProfile -ExecutionPolicy Bypass -File zig\verify-distribution.ps1 -KeepTemp
#
# What it proves, form by form:
#
#   dev        exe under zig-out\bin -> "--version" says (dev); no %APPDATA%\OTTO,
#              no <exe>\data, settings in <exe>\.otto-settings.json (written through
#              the real settings panel, then removed); second start reads that same
#              file back; fixtures/library.json stays read-only; updates go to
#              <exe>\updates.
#   portable   two exes + otto-portable.flag in a temp dir -> (portable); import
#              writes <exe>\data\library.otto; settings at <exe>\data\settings.json;
#              cache at <exe>\data\cache; updates at <exe>\data\updates; the real
#              %APPDATA%\OTTO snapshot is unchanged.
#   installed  two exes in a temp dir, no flag, path without a zig-out segment ->
#              (installed); APPDATA is pointed at a throw-away directory for the
#              child process, so the library / settings / cache / updates must all
#              land under <fake>\OTTO\. The real %APPDATA%\OTTO is only ever read
#              for a before/after snapshot. The fake APPDATA is deleted at the end.
#
# Each form is driven twice: the first process writes settings (through the real
# settings panel: click "设置", drag the opacity slider to 60%, click "关闭"),
# the second process must read the same settings file back and print opacity=153.
# The library is imported once and read back through --filter on the second run,
# which resolves the default library the same way a normal startup does (the
# .otto written by the import wins over the nominal library.json).
#
# The updates check uses a local feed with a well-formed minisign envelope
# (algorithm + key id copied from zig/keys/otto-lite.key.pub, 64 zero signature
# bytes): the app must create the updates directory, write the .part, fail the
# Ed25519 check with SignatureMismatch, and delete the .part. The directory is
# created *before* the download (update_download.zig step 3), so its location is
# observable without a valid signature and without any network access.
#
# Constraints: no window is ever shown (--nanoui-snapshot runs hidden), nothing
# is activated, no registry / installer is touched, and the real user data is
# never written. Temporary state is removed on every run, including failures.
#
# This file is UTF-8 **with BOM** on purpose: Windows PowerShell 5.1 reads a
# BOM-less .ps1 as ANSI and would garble the Chinese table headers.

[CmdletBinding()]
param(
  [string]$Zig = 'C:\Users\30680\zig\zig-x86_64-windows-0.17.0\zig.exe',
  [string]$AppDir = '',
  [string]$Samples = 'C:\src\otto-testkit\samples',
  [string]$TempRoot = '',
  [switch]$SkipBuild,
  [switch]$Release,
  [switch]$KeepTemp
)

# Native stderr becomes an ErrorRecord in Windows PowerShell; every native call
# below is wrapped and its exit code checked explicitly instead.
$ErrorActionPreference = 'Continue'

$script:root = $PSScriptRoot
if (-not $AppDir) { $AppDir = Join-Path $script:root 'app' }
if (-not $TempRoot) { $TempRoot = Join-Path $env:TEMP 'otto-verify-distribution' }

$script:appDir = [IO.Path]::GetFullPath($AppDir)
$script:tempRoot = [IO.Path]::GetFullPath($TempRoot)
$script:exe = Join-Path $script:appDir 'zig-out\bin\otto-lite.exe'
$script:helper = Join-Path $script:appDir 'zig-out\bin\otto-thumb-host.exe'
$script:manifest = Join-Path $script:appDir 'build.zig.zon'
$script:samples = [IO.Path]::GetFullPath($Samples)
$script:devBin = Join-Path $script:appDir 'zig-out\bin'
$script:fixturesDir = Join-Path $script:appDir 'fixtures'
$script:fixtureLibrary = Join-Path $script:fixturesDir 'library.json'
$script:fixtureOtto = Join-Path $script:fixturesDir 'library.otto'
$script:publicKeyPath = Join-Path $script:root 'keys\otto-lite.key.pub'

$script:portableDir = Join-Path $script:tempRoot 'portable'
$script:installedDir = Join-Path $script:tempRoot 'installed'
$script:fakeAppData = Join-Path $script:tempRoot 'appdata-installed'
$script:feedDir = Join-Path $script:tempRoot 'feed'
$script:shotsDir = Join-Path $script:tempRoot 'shots'
$script:devStashDir = Join-Path $script:tempRoot 'dev-stash'

$script:checks = New-Object System.Collections.ArrayList
$script:rows = @{}
foreach ($form in @('dev', 'portable', 'installed')) {
  $script:rows[$form] = New-Object psobject -Property @{
    Form = $form
    VersionLine = '(not run)'
    Library = '(not run)'
    Settings = '(not run)'
  }
}

# The real user data directory: read once for a before/after snapshot. The
# installed form never uses it (APPDATA is redirected for the child only).
$script:realAppData = $env:APPDATA
if ([string]::IsNullOrEmpty($script:realAppData)) {
  throw 'APPDATA is not set; cannot take the real-data snapshot.'
}
$script:realOtto = Join-Path $script:realAppData 'OTTO'

# Settings-panel geometry. The window is 380x700 points and the panel layout is
# fixed (the same coordinates opacity.ps1 documents and uses):
#   header "设置" button            -> 352,57
#   slider track x=40..340, y=196   -> 60% is 218
# Text clicks are used for open/close so only the slider position is geometric.
$script:panelScript = 'click:设置;at:218,196;click:关闭'
$script:devArtifactNames = @('.otto-settings.json', 'data', 'cache', 'updates')

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

function Write-Head([string]$text) {
  Write-Output ''
  Write-Output $text
}

function Add-Check {
  param(
    [string]$Form,
    [string]$Name,
    [bool]$Ok,
    [string]$Detail = ''
  )
  $null = $script:checks.Add((New-Object psobject -Property @{
    Form = $Form
    Name = $Name
    Ok = $Ok
    Detail = $Detail
  }))
  $tag = if ($Ok) { 'PASS' } else { 'FAIL' }
  Write-Output ("  [{0}] {1}" -f $tag, $Name)
  if ($Detail -and $Detail.Length -gt 0) { Write-Output ("         {0}" -f $Detail) }
}

function Test-FormPassed([string]$Form) {
  $mine = @($script:checks | Where-Object { $_.Form -eq $Form })
  $bad = @($mine | Where-Object { -not $_.Ok })
  return ($mine.Count -gt 0 -and $bad.Count -eq 0)
}

function Test-Dir([string]$Path) {
  return (Test-Path -LiteralPath $Path -PathType Container)
}

function Test-File([string]$Path) {
  return (Test-Path -LiteralPath $Path -PathType Leaf)
}

# "yes"/"no" for check details, instead of PowerShell's True/False.
function YesNo([bool]$Value) {
  if ($Value) { return 'yes' }
  return 'no'
}

# Runs the exe with stdout+stderr merged; returns exit code and one string per line.
function Invoke-Otto {
  param(
    [string]$Exe,
    [string]$Cwd,
    [string[]]$Argv,
    [string]$AppDataOverride = ''
  )
  if (-not (Test-Path -LiteralPath $Exe)) {
    return New-Object psobject -Property @{ Code = -1; Lines = [string[]]@("missing exe: $Exe") }
  }
  $previousAppData = $env:APPDATA
  if (-not [string]::IsNullOrEmpty($AppDataOverride)) { $env:APPDATA = $AppDataOverride }
  $pushed = $false
  try {
    Push-Location -LiteralPath $Cwd
    $pushed = $true
    # `$global:` matters: assigning `$LASTEXITCODE` inside a function creates a
    # local shadow that the native command does not update, so the code would
    # always read back as 0.
    $global:LASTEXITCODE = 0
    $all = @(& $Exe @Argv 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $code = $global:LASTEXITCODE
  } finally {
    if ($pushed) { Pop-Location }
    if ([string]::IsNullOrEmpty($previousAppData)) {
      Remove-Item Env:APPDATA -ErrorAction SilentlyContinue
    } else {
      $env:APPDATA = $previousAppData
    }
  }
  return New-Object psobject -Property @{ Code = $code; Lines = [string[]]$all }
}

function Get-NonEmptyLines($Lines) {
  # `@($Lines)`: a single string must stay one line, not be unrolled into chars.
  $result = @()
  foreach ($line in @($Lines)) {
    if ($line.Trim().Length -gt 0) { $result += [string]$line }
  }
  return $result
}

function Get-LineMatching($Lines, [string]$Pattern) {
  $found = @()
  foreach ($line in @($Lines)) {
    if ($line -match $Pattern) { $found += [string]$line }
  }
  if ($found.Count -eq 0) { return '' }
  return [string]$found[$found.Count - 1]
}

# A settings file must be valid JSON and carry all five fields.
function Test-SettingsFile([string]$Path, [int]$Opacity) {
  if (-not (Test-File $Path)) {
    return New-Object psobject -Property @{ Ok = $false; Detail = "missing: $Path" }
  }
  try {
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $obj = $raw | ConvertFrom-Json
  } catch {
    return New-Object psobject -Property @{ Ok = $false; Detail = "invalid JSON: $($_.Exception.Message)" }
  }
  $names = @($obj.PSObject.Properties | ForEach-Object { $_.Name })
  $want = @('always_on_top', 'update_url', 'l2_budget_mib', 'l3_budget_mib', 'opacity')
  $missing = @($want | Where-Object { $names -notcontains $_ })
  $ok = ($missing.Count -eq 0) -and ([int]$obj.opacity -eq $Opacity)
  $detail = 'opacity={0} fields={1}' -f $obj.opacity, ($names -join ',')
  if ($missing.Count -gt 0) { $detail += ' missing=' + ($missing -join ',') }
  return New-Object psobject -Property @{ Ok = $ok; Detail = $detail }
}

# First 8 bytes of an OTTOLIB file: "OTTOLIB\0".
function Test-OttoMagic([string]$Path) {
  if (-not (Test-File $Path)) {
    return New-Object psobject -Property @{ Ok = $false; Detail = "missing: $Path" }
  }
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
  } catch {
    return New-Object psobject -Property @{ Ok = $false; Detail = "unreadable: $($_.Exception.Message)" }
  }
  if ($bytes.Length -lt 8) {
    return New-Object psobject -Property @{ Ok = $false; Detail = "too short: $($bytes.Length) bytes" }
  }
  $magic = [Text.Encoding]::ASCII.GetString($bytes, 0, 7)
  $ok = ($magic -eq 'OTTOLIB') -and ($bytes[7] -eq 0)
  return New-Object psobject -Property @{ Ok = $ok; Detail = 'bytes={0} magic={1}<NUL>' -f $bytes.Length, $magic }
}

# Shallow but strict snapshot: existence + directory mtime + top-level names,
# sizes and mtimes. A settings / library write replaces a file (directory mtime
# changes); creating any new entry also changes the directory mtime.
function Get-PathSnapshot([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    return New-Object psobject -Property @{ Exists = $false; Stamp = ''; Entries = '' }
  }
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop |
      Sort-Object Name |
      ForEach-Object {
        $kind = if ($_.PSIsContainer) { 'dir' } else { [string]$_.Length }
        '{0}|{1}|{2}' -f $_.Name, $_.LastWriteTimeUtc.Ticks, $kind
      })
    return New-Object psobject -Property @{
      Exists = $true
      Stamp = $item.LastWriteTimeUtc.Ticks.ToString()
      Entries = ($entries -join ';')
    }
  } catch {
    return New-Object psobject -Property @{
      Exists = $true
      Stamp = 'unreadable'
      Entries = $_.Exception.Message
    }
  }
}

function Format-Snapshot($Snapshot) {
  if (-not $Snapshot.Exists) { return 'absent' }
  if ($Snapshot.Stamp -eq 'unreadable') { return 'unreadable' }
  $count = 0
  if ($Snapshot.Entries.Length -gt 0) { $count = @($Snapshot.Entries -split ';').Count }
  return ('present mtime={0} entries={1}' -f $Snapshot.Stamp, $count)
}

function Test-SnapshotEqual($Before, $After) {
  return ($Before.Exists -eq $After.Exists) -and
    ($Before.Stamp -eq $After.Stamp) -and
    ($Before.Entries -eq $After.Entries)
}

# Runs after every form that must not touch the real user data.
function Assert-RealAppDataUntouched([string]$Form) {
  $after = Get-PathSnapshot $script:realOtto
  $ok = Test-SnapshotEqual $script:realOttoBefore $after
  Add-Check $Form 'real %APPDATA%\OTTO untouched (before/after snapshot)' $ok (
    'before: {0}; after: {1}; path={2}' -f (Format-Snapshot $script:realOttoBefore), (Format-Snapshot $after), $script:realOtto)
}

# The dev exe dir is a build output, not a scratch pad: move anything that could
# change the verdict aside (and put it back afterwards), so the run starts from
# a known-clean dev state without destroying a developer's own files.
function Initialize-DevStash {
  New-Item -ItemType Directory -Force -Path $script:devStashDir | Out-Null
  $script:devStashed = @{}
  foreach ($name in $script:devArtifactNames) {
    $source = Join-Path $script:devBin $name
    $script:devStashed[$name] = $false
    if (Test-Path -LiteralPath $source) {
      Move-Item -LiteralPath $source -Destination (Join-Path $script:devStashDir $name) -Force
      $script:devStashed[$name] = $true
    }
  }
  $script:fixtureOttoStashed = $false
  if (Test-Path -LiteralPath $script:fixtureOtto) {
    Move-Item -LiteralPath $script:fixtureOtto -Destination (Join-Path $script:devStashDir 'fixtures-library.otto') -Force
    $script:fixtureOttoStashed = $true
  }
}

function Restore-DevStash {
  if ($null -eq $script:devStashed) { return }
  foreach ($name in $script:devArtifactNames) {
    $target = Join-Path $script:devBin $name
    if (Test-Path -LiteralPath $target) {
      Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($script:devStashed[$name]) {
      $backup = Join-Path $script:devStashDir $name
      if (Test-Path -LiteralPath $backup) {
        Move-Item -LiteralPath $backup -Destination $target -Force
      }
    }
  }
  if (Test-Path -LiteralPath $script:fixtureOtto) {
    Remove-Item -LiteralPath $script:fixtureOtto -Force -ErrorAction SilentlyContinue
  }
  if ($script:fixtureOttoStashed) {
    $backup = Join-Path $script:devStashDir 'fixtures-library.otto'
    if (Test-Path -LiteralPath $backup) {
      Move-Item -LiteralPath $backup -Destination $script:fixtureOtto -Force
    }
  }
  $script:devStashed = $null
}

# ---------------------------------------------------------------------------
# Distribution-specific helpers
# ---------------------------------------------------------------------------

function Invoke-Snapshot {
  param(
    [string]$Exe,
    [string]$Cwd,
    [string]$Shot,
    [string]$Script = '',
    [string]$AppDataOverride = ''
  )
  $argv = @("--nanoui-snapshot=$Shot")
  if (-not [string]::IsNullOrEmpty($Script)) { $argv += "--nanoui-script=$Script" }
  return Invoke-Otto -Exe $Exe -Cwd $Cwd -Argv $argv -AppDataOverride $AppDataOverride
}

function Invoke-FilterReadback {
  param([string]$Exe, [string]$Cwd, [string]$AppDataOverride = '')
  return Invoke-Otto -Exe $Exe -Cwd $Cwd -Argv @('--filter=') -AppDataOverride $AppDataOverride
}

function Invoke-UpdateProbe {
  param([string]$Exe, [string]$Cwd, [string]$AppDataOverride = '')
  return Invoke-Otto -Exe $Exe -Cwd $Cwd -Argv @('--update-download', $script:feedPath) -AppDataOverride $AppDataOverride
}

function Assert-UpdateDir {
  param(
    [string]$Form,
    [string]$UpdatesDir,
    [string]$ForbiddenDir,
    [string]$ForbiddenLabel,
    $Result
  )
  $failedLine = Get-LineMatching $Result.Lines '^update-download: failed error='
  $ok = Test-Dir $UpdatesDir
  Add-Check $Form 'updates dir created at the form-specific location' $ok (
    'expected: {0}; download says: {1}' -f $UpdatesDir, $failedLine)
  $signed = ($Result.Code -eq 1) -and ($failedLine -match 'error=SignatureMismatch')
  Add-Check $Form 'local feed reached the signature step (SignatureMismatch, no network)' $signed (
    'exit={0}; line={1}' -f $Result.Code, $failedLine)
  $left = 0
  if (Test-Dir $UpdatesDir) { $left = @(Get-ChildItem -LiteralPath $UpdatesDir -Force).Count }
  Add-Check $Form 'failed download left no .part / installer behind' ($left -eq 0) (
    'entries in {0}: {1}' -f $UpdatesDir, $left)
  if ($ForbiddenDir) {
    $forbidden = Test-Dir $ForbiddenDir
    Add-Check $Form ("updates did not appear in {0}" -f $ForbiddenLabel) (-not $forbidden) (
      'forbidden path: {0} exists={1}' -f $ForbiddenDir, (YesNo $forbidden))
  }
}

function Assert-Readback {
  param(
    [string]$Form,
    [string]$ExpectedLibrary,
    [string]$ExpectedSettings,
    [string]$AppDataOverride = ''
  )
  # 1) settings: the second process must load the file the first process saved.
  $r = Invoke-Snapshot -Exe $script:currentExe -Cwd $script:currentCwd -Shot (Join-Path $script:shotsDir "$Form-readback.png") -AppDataOverride $AppDataOverride
  $settingsPattern = '^otto-lite: settings path=' + [regex]::Escape($ExpectedSettings) + ' .*opacity=153'
  $settingsLine = Get-LineMatching $r.Lines $settingsPattern
  Add-Check $Form 'second start reads the settings file back (opacity=153)' (($r.Code -eq 0) -and $settingsLine.Length -gt 0) (
    'exit={0}; line={1}' -f $r.Code, $settingsLine)

  # 2) library: --filter without a path resolves the default library exactly as a
  #    normal startup does (the .otto written by the import wins over library.json).
  $f = Invoke-FilterReadback -Exe $script:currentExe -Cwd $script:currentCwd -AppDataOverride $AppDataOverride
  $libLine = Get-LineMatching $f.Lines '^otto-lite: library='
  $filterLine = Get-LineMatching $f.Lines '^otto-lite: filter=".*" total=\d+ matched=\d+'
  $expectedLibLine = 'otto-lite: library=' + $ExpectedLibrary
  $total = -1
  $matched = -1
  if ($filterLine -match 'total=(\d+) matched=(\d+)') {
    $total = [int]$Matches[1]
    $matched = [int]$Matches[2]
  }
  $libOk = ($f.Code -eq 0) -and ($libLine -eq $expectedLibLine) -and ($total -gt 0) -and ($matched -eq $total)
  Add-Check $Form 'second start reads the library back (default-path --filter)' $libOk (
    'exit={0}; {1}; {2}' -f $f.Code, $libLine, $filterLine)
}

# ---------------------------------------------------------------------------
# Form: dev
# ---------------------------------------------------------------------------

function Invoke-DevForm {
  Write-Head '== dev: zig-out\bin (no user directory writes) =='
  $bin = $script:devBin
  $exe = $script:devExe
  $settings = Join-Path $bin '.otto-settings.json'
  $data = Join-Path $bin 'data'
  $cache = Join-Path $bin 'cache'
  $updates = Join-Path $bin 'updates'

  $script:rows['dev'].Library = 'fixtures/library.json（只读）'
  $script:rows['dev'].Settings = 'zig-out\bin\.otto-settings.json'

  $expectedVersion = "otto-lite $($script:version) (dev)"
  $r = Invoke-Otto -Exe $exe -Cwd $script:appDir -Argv @('--version')
  $lines = @(Get-NonEmptyLines $r.Lines)
  $line = if ($lines.Count -gt 0) { $lines[$lines.Count - 1].Trim() } else { '(no output)' }
  $script:rows['dev'].VersionLine = $line
  $versionOk = ($r.Code -eq 0) -and ($lines.Count -eq 1) -and ($line -eq $expectedVersion)
  Add-Check 'dev' '--version says (dev)' $versionOk ('exit={0}; expected="{1}"; actual="{2}"' -f $r.Code, $expectedVersion, $line)

  $clean = (-not (Test-Path -LiteralPath $data)) -and (-not (Test-Path -LiteralPath $cache)) -and (-not (Test-Path -LiteralPath $settings))
  Add-Check 'dev' '--version does not create data / cache / settings' $clean (
    'data={0} cache={1} settings={2}' -f (YesNo (Test-Path -LiteralPath $data)), (YesNo (Test-Path -LiteralPath $cache)), (YesNo (Test-Path -LiteralPath $settings)))

  # First start: open the real settings panel, drag opacity to 60%, close -> save.
  $run1 = Invoke-Snapshot -Exe $exe -Cwd $script:appDir -Shot (Join-Path $script:shotsDir 'dev-write.png') -Script $script:panelScript
  $savedLine = Get-LineMatching $run1.Lines ('^otto-lite: settings saved path=' + [regex]::Escape($settings) + ' ')
  Add-Check 'dev' 'settings written through the panel to <exe>\.otto-settings.json' (($run1.Code -eq 0) -and $savedLine.Length -gt 0) (
    'exit={0}; line={1}' -f $run1.Code, $savedLine)
  $content = Test-SettingsFile $settings 153
  Add-Check 'dev' 'dev settings file is valid JSON with opacity=153' $content.Ok $content.Detail
  $noData = (-not (Test-Path -LiteralPath $data)) -and (-not (Test-Path -LiteralPath $cache)) -and (-not (Test-Path -LiteralPath (Join-Path $bin 'data\settings.json')))
  Add-Check 'dev' 'dev wrote no <exe>\data and no <exe>\cache' $noData (
    'data={0} cache={1}' -f (YesNo (Test-Path -LiteralPath $data)), (YesNo (Test-Path -LiteralPath $cache)))

  # Second start: read the settings back from the same file.
  $script:currentExe = $exe
  $script:currentCwd = $script:appDir
  Assert-Readback -Form 'dev' -ExpectedLibrary 'fixtures/library.json' -ExpectedSettings $settings

  # Library read-only: the fixture hash must be identical, no .otto created.
  $fixturesNow = Get-FileHash -LiteralPath $script:fixtureLibrary -Algorithm SHA256
  Add-Check 'dev' 'fixtures/library.json is read-only (SHA-256 unchanged)' ($fixturesNow.Hash -eq $script:fixtureHash) (
    'before={0} after={1}' -f $script:fixtureHash, $fixturesNow.Hash)
  Add-Check 'dev' 'dev did not convert fixtures/library.json into fixtures/library.otto' (-not (Test-Path -LiteralPath $script:fixtureOtto)) (
    'fixtures/library.otto exists={0}' -f (YesNo (Test-Path -LiteralPath $script:fixtureOtto)))

  # Updates: dev puts the download beside the exe (mode.updatesDirFor .dev).
  $updateResult = Invoke-UpdateProbe -Exe $exe -Cwd $script:appDir
  Assert-UpdateDir -Form 'dev' -UpdatesDir $updates -ForbiddenDir $data -ForbiddenLabel '<exe>\data' -Result $updateResult

  # Cache is the negative assertion for dev: it must not exist anywhere near the exe.
  Add-Check 'dev' 'dev cache is not on disk (<exe>\cache absent)' (-not (Test-Path -LiteralPath $cache)) (
    'path: {0}' -f $cache)

  Assert-RealAppDataUntouched 'dev'
}

# ---------------------------------------------------------------------------
# Form: portable
# ---------------------------------------------------------------------------

function Invoke-PortableForm {
  Write-Head '== portable: otto-portable.flag next to the exe =='
  $dir = $script:portableDir
  $exe = Join-Path $dir 'otto-lite.exe'
  $data = Join-Path $dir 'data'
  $library = Join-Path $data 'library.otto'
  $settings = Join-Path $data 'settings.json'
  $cache = Join-Path $data 'cache'
  $updates = Join-Path $data 'updates'
  $exeSettings = Join-Path $dir '.otto-settings.json'

  Copy-Item -LiteralPath $script:exe -Destination $exe
  Copy-Item -LiteralPath $script:helper -Destination (Join-Path $dir 'otto-thumb-host.exe')
  [IO.File]::WriteAllText((Join-Path $dir 'otto-portable.flag'), '', (New-Object Text.UTF8Encoding($false)))

  $script:rows['portable'].Library = $library
  $script:rows['portable'].Settings = $settings

  $expectedVersion = "otto-lite $($script:version) (portable)"
  $r = Invoke-Otto -Exe $exe -Cwd $dir -Argv @('--version')
  $lines = @(Get-NonEmptyLines $r.Lines)
  $line = if ($lines.Count -gt 0) { $lines[$lines.Count - 1].Trim() } else { '(no output)' }
  $script:rows['portable'].VersionLine = $line
  Add-Check 'portable' '--version says (portable)' (($r.Code -eq 0) -and ($lines.Count -eq 1) -and ($line -eq $expectedVersion)) (
    'exit={0}; expected="{1}"; actual="{2}"' -f $r.Code, $expectedVersion, $line)
  Add-Check 'portable' '--version does not create data next to the exe' (-not (Test-Path -LiteralPath $data)) (
    'data exists={0}' -f (YesNo (Test-Path -LiteralPath $data)))

  # Import into the default library: import_target turns <data>\library.json into
  # <data>\library.otto and creates the data directory first (first run).
  $imp = Invoke-Otto -Exe $exe -Cwd $dir -Argv @('--import-into', $script:samples)
  $wroteLine = Get-LineMatching $imp.Lines 'wrote=.* bytes='
  $wrotePath = ''
  if ($wroteLine -match 'wrote=(.*?) bytes=') { $wrotePath = $Matches[1] }
  Add-Check 'portable' '--import-into wrote <exe>\data\library.otto' (($imp.Code -eq 0) -and ($wrotePath -eq $library)) (
    'exit={0}; wrote="{1}"; expected="{2}"' -f $imp.Code, $wrotePath, $library)
  $magic = Test-OttoMagic $library
  Add-Check 'portable' 'portable library is a real OTTOLIB file' $magic.Ok $magic.Detail
  Add-Check 'portable' 'portable import created no settings yet' (-not (Test-Path -LiteralPath $settings)) (
    'settings exists={0}' -f (YesNo (Test-Path -LiteralPath $settings)))

  # First start: the panel writes <data>\settings.json; L3 creates <data>\cache\thumbs.
  $run1 = Invoke-Snapshot -Exe $exe -Cwd $dir -Shot (Join-Path $script:shotsDir 'portable-write.png') -Script $script:panelScript
  $savedLine = Get-LineMatching $run1.Lines ('^otto-lite: settings saved path=' + [regex]::Escape($settings) + ' ')
  Add-Check 'portable' 'settings written to <exe>\data\settings.json' (($run1.Code -eq 0) -and $savedLine.Length -gt 0) (
    'exit={0}; line={1}' -f $run1.Code, $savedLine)
  $content = Test-SettingsFile $settings 153
  Add-Check 'portable' 'portable settings file is valid JSON with opacity=153' $content.Ok $content.Detail
  Add-Check 'portable' 'portable cache lives at <exe>\data\cache\thumbs' (Test-Dir (Join-Path $cache 'thumbs')) (
    'path: {0}' -f (Join-Path $cache 'thumbs'))
  Add-Check 'portable' 'portable wrote no settings next to the exe' (-not (Test-Path -LiteralPath $exeSettings)) (
    '.otto-settings.json exists={0}' -f (YesNo (Test-Path -LiteralPath $exeSettings)))

  # Second start: read settings and library back.
  $script:currentExe = $exe
  $script:currentCwd = $dir
  Assert-Readback -Form 'portable' -ExpectedLibrary $library -ExpectedSettings $settings

  # Updates: portable puts them under <data>\updates, never beside the exe.
  $updateResult = Invoke-UpdateProbe -Exe $exe -Cwd $dir
  Assert-UpdateDir -Form 'portable' -UpdatesDir $updates -ForbiddenDir (Join-Path $dir 'updates') -ForbiddenLabel '<exe>\updates' -Result $updateResult
  Add-Check 'portable' 'portable cache lives only under <exe>\data (not <exe>\cache)' (-not (Test-Path -LiteralPath (Join-Path $dir 'cache'))) (
    '<exe>\cache exists={0}' -f (YesNo (Test-Path -LiteralPath (Join-Path $dir 'cache'))))

  Assert-RealAppDataUntouched 'portable'
}

# ---------------------------------------------------------------------------
# Form: installed
# ---------------------------------------------------------------------------

function Invoke-InstalledForm {
  Write-Head '== installed: no flag, extra exe directory, fake APPDATA =='
  $dir = $script:installedDir
  $exe = Join-Path $dir 'otto-lite.exe'
  $ottoDir = Join-Path $script:fakeAppData 'OTTO'
  $library = Join-Path $ottoDir 'library.otto'
  $settings = Join-Path $ottoDir 'settings.json'
  $cache = Join-Path $ottoDir 'cache'
  $updates = Join-Path $ottoDir 'updates'
  $exeSettings = Join-Path $dir '.otto-settings.json'
  $exeData = Join-Path $dir 'data'

  Copy-Item -LiteralPath $script:exe -Destination $exe
  Copy-Item -LiteralPath $script:helper -Destination (Join-Path $dir 'otto-thumb-host.exe')

  $script:rows['installed'].Library = $library
  $script:rows['installed'].Settings = $settings

  $expectedVersion = "otto-lite $($script:version) (installed)"
  $r = Invoke-Otto -Exe $exe -Cwd $dir -Argv @('--version') -AppDataOverride $script:fakeAppData
  $lines = @(Get-NonEmptyLines $r.Lines)
  $line = if ($lines.Count -gt 0) { $lines[$lines.Count - 1].Trim() } else { '(no output)' }
  $script:rows['installed'].VersionLine = $line
  Add-Check 'installed' '--version says (installed)' (($r.Code -eq 0) -and ($lines.Count -eq 1) -and ($line -eq $expectedVersion)) (
    'exit={0}; expected="{1}"; actual="{2}"' -f $r.Code, $expectedVersion, $line)
  Add-Check 'installed' '--version does not create <fake APPDATA>\OTTO or <exe>\data' (
    (-not (Test-Path -LiteralPath $ottoDir)) -and (-not (Test-Path -LiteralPath $exeData))) (
    'OTTO exists={0}; data exists={1}' -f (YesNo (Test-Path -LiteralPath $ottoDir)), (YesNo (Test-Path -LiteralPath $exeData)))

  # Import with the fake APPDATA: the library must land in <fake>\OTTO\.
  $imp = Invoke-Otto -Exe $exe -Cwd $dir -Argv @('--import-into', $script:samples) -AppDataOverride $script:fakeAppData
  $wroteLine = Get-LineMatching $imp.Lines 'wrote=.* bytes='
  $wrotePath = ''
  if ($wroteLine -match 'wrote=(.*?) bytes=') { $wrotePath = $Matches[1] }
  Add-Check 'installed' '--import-into wrote <fake APPDATA>\OTTO\library.otto' (($imp.Code -eq 0) -and ($wrotePath -eq $library)) (
    'exit={0}; wrote="{1}"; expected="{2}"' -f $imp.Code, $wrotePath, $library)
  $magic = Test-OttoMagic $library
  Add-Check 'installed' 'installed library is a real OTTOLIB file' $magic.Ok $magic.Detail
  Add-Check 'installed' 'installed import wrote nothing next to the exe' (
    (-not (Test-Path -LiteralPath $exeData)) -and (-not (Test-Path -LiteralPath $exeSettings))) (
    'data exists={0}; settings exists={1}' -f (YesNo (Test-Path -LiteralPath $exeData)), (YesNo (Test-Path -LiteralPath $exeSettings)))

  # First start: settings and cache in <fake>\OTTO\.
  $run1 = Invoke-Snapshot -Exe $exe -Cwd $dir -Shot (Join-Path $script:shotsDir 'installed-write.png') -Script $script:panelScript -AppDataOverride $script:fakeAppData
  $savedLine = Get-LineMatching $run1.Lines ('^otto-lite: settings saved path=' + [regex]::Escape($settings) + ' ')
  Add-Check 'installed' 'settings written to <fake APPDATA>\OTTO\settings.json' (($run1.Code -eq 0) -and $savedLine.Length -gt 0) (
    'exit={0}; line={1}' -f $run1.Code, $savedLine)
  $content = Test-SettingsFile $settings 153
  Add-Check 'installed' 'installed settings file is valid JSON with opacity=153' $content.Ok $content.Detail
  Add-Check 'installed' 'installed cache lives at <fake APPDATA>\OTTO\cache\thumbs' (Test-Dir (Join-Path $cache 'thumbs')) (
    'path: {0}' -f (Join-Path $cache 'thumbs'))
  Add-Check 'installed' 'installed wrote no data or settings next to the exe' (
    (-not (Test-Path -LiteralPath $exeData)) -and (-not (Test-Path -LiteralPath $exeSettings))) (
    'data exists={0}; settings exists={1}' -f (YesNo (Test-Path -LiteralPath $exeData)), (YesNo (Test-Path -LiteralPath $exeSettings)))

  # Second start: read settings and library back.
  $script:currentExe = $exe
  $script:currentCwd = $dir
  Assert-Readback -Form 'installed' -ExpectedLibrary $library -ExpectedSettings $settings -AppDataOverride $script:fakeAppData

  # Updates: installed puts them under <fake>\OTTO\updates, never beside the exe.
  $updateResult = Invoke-UpdateProbe -Exe $exe -Cwd $dir -AppDataOverride $script:fakeAppData
  Assert-UpdateDir -Form 'installed' -UpdatesDir $updates -ForbiddenDir (Join-Path $dir 'updates') -ForbiddenLabel '<exe>\updates' -Result $updateResult

  Add-Check 'installed' 'installed did not write <exe>\data or <exe>\cache' (
    (-not (Test-Path -LiteralPath $exeData)) -and (-not (Test-Path -LiteralPath (Join-Path $dir 'cache')))) (
    'data exists={0}; cache exists={1}' -f (YesNo (Test-Path -LiteralPath $exeData)), (YesNo (Test-Path -LiteralPath (Join-Path $dir 'cache'))))

  # The fake APPDATA is throw-away: library, settings, cache and updates all exist
  # under it, so deleting it is the whole cleanup.
  $expected = @($library, $settings, (Join-Path $cache 'thumbs'), $updates)
  $missing = @($expected | Where-Object { -not (Test-Path -LiteralPath $_) })
  Add-Check 'installed' 'all installed state is under <fake APPDATA>\OTTO' ($missing.Count -eq 0) (
    'missing: {0}' -f ($missing -join ', '))

  Assert-RealAppDataUntouched 'installed'
}

# ---------------------------------------------------------------------------
# Inputs, build and the local update feed
# ---------------------------------------------------------------------------

function Assert-Preconditions {
  if (-not (Test-Path -LiteralPath $Zig)) { throw "zig not found: $Zig" }
  if (-not (Test-Path -LiteralPath $script:manifest)) { throw "build.zig.zon not found: $($script:manifest)" }
  if (-not (Test-Path -LiteralPath $script:samples -PathType Container)) { throw "samples folder not found: $($script:samples)" }
  if (-not (Test-Path -LiteralPath $script:fixtureLibrary)) { throw "fixture library not found: $($script:fixtureLibrary)" }
  if (-not (Test-Path -LiteralPath $script:publicKeyPath)) { throw "update public key not found: $($script:publicKeyPath)" }
  if (-not (Test-Path -LiteralPath $script:appDir -PathType Container)) { throw "app dir not found: $($script:appDir)" }

  # The installed form is recognised by the *absence* of a zig-out path segment.
  # If the temp root ever contained one, the form would silently be tested as dev.
  foreach ($path in @($script:installedDir, $script:portableDir)) {
    $segments = @($path -split '[\\/]')
    foreach ($segment in $segments) {
      if ($segment -ieq 'zig-out') { throw "temp path contains a zig-out segment and would be detected as dev: $path" }
    }
  }
}

function Invoke-Build {
  Write-Output ''
  Write-Output ('== build: {0} ==' -f $script:appDir)
  if ($SkipBuild) {
    Write-Output '  skipped (-SkipBuild)'
    return
  }
  $buildArgs = @('build')
  if ($Release) { $buildArgs += '-Drelease=true' }
  Push-Location -LiteralPath $script:appDir
  try {
    $global:LASTEXITCODE = 0
    $output = @(& $Zig @buildArgs 2>&1 | ForEach-Object {
      if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ }
    })
    $code = $global:LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($code -ne 0) {
    Write-Output ($output -join [Environment]::NewLine)
    throw "zig build failed (exit $code)"
  }
  Write-Output '  build: OK'
}

function Read-Version {
  $text = [IO.File]::ReadAllText($script:manifest, [Text.Encoding]::UTF8)
  if ($text -notmatch '\.version\s*=\s*"([^"]+)"') {
    throw "no .version in $($script:manifest)"
  }
  $script:version = $Matches[1]
  Write-Output ('== version: {0} (from build.zig.zon) ==' -f $script:version)
}

# Builds a minisign envelope from the embedded public key: ED + key id + 64 zero
# signature bytes. inspectSignature() only checks structure/algorithm/key id, so
# this passes the envelope check and fails later, at the real Ed25519 check.
function New-LocalUpdateFeed {
  $pubText = ([IO.File]::ReadAllText($script:publicKeyPath, [Text.Encoding]::UTF8)).Trim()
  $pubOuter = [Convert]::FromBase64String($pubText)
  $pubInnerText = [Text.Encoding]::UTF8.GetString($pubOuter)
  $pubLines = @()
  foreach ($line in @($pubInnerText -split "`n")) {
    if ($line.Trim().Length -gt 0) { $pubLines += [string]$line }
  }
  if ($pubLines.Count -lt 2) { throw 'public key file has no base64 key line' }
  $pubBytes = [Convert]::FromBase64String($pubLines[$pubLines.Count - 1].Trim())
  if ($pubBytes.Length -ne 42) { throw "public key is $($pubBytes.Length) bytes, expected 42" }
  if (-not (([char]$pubBytes[0] -eq 'E') -and ([char]$pubBytes[1] -eq 'd'))) { throw 'public key is not Ed' }

  $sigInner = New-Object byte[] 74
  $sigInner[0] = [byte][char]'E'   # "ED" = prehashed variant
  $sigInner[1] = [byte][char]'D'
  [Array]::Copy($pubBytes, 2, $sigInner, 2, 8)   # same key id as the embedded key
  $sigLine = [Convert]::ToBase64String($sigInner)
  $sigText = "untrusted comment: verify-distribution`n$sigLine`ntrusted comment: verify-distribution`n"
  $signature = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sigText))

  New-Item -ItemType Directory -Force -Path $script:feedDir | Out-Null
  $setup = Join-Path $script:feedDir 'otto-lite-9.9.9-setup.exe'
  $setupBytes = New-Object byte[] 64
  for ($i = 0; $i -lt $setupBytes.Length; $i++) { $setupBytes[$i] = [byte](($i % 251) + 1) }
  [IO.File]::WriteAllBytes($setup, $setupBytes)

  # Plain local paths work in feed.fetch / feed.download (file:// also works);
  # forward slashes avoid JSON backslash escaping.
  $url = $setup -replace '\\', '/'
  $json = '{"version":"9.9.9","notes":"verify-distribution","pub_date":"2026-01-01T00:00:00Z",' +
    '"platforms":{"windows-x86_64":{"url":"' + $url + '","size":64,"signature":"' + $signature + '"}}}'
  $script:feedPath = Join-Path $script:feedDir 'latest.json'
  [IO.File]::WriteAllText($script:feedPath, $json, (New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------------------
# Table
# ---------------------------------------------------------------------------

function Get-DisplayWidth([string]$Text) {
  $width = 0
  foreach ($ch in $Text.ToCharArray()) {
    $code = [int][char]$ch
    if ($code -ge 0x1100 -and (
        ($code -le 0x115F) -or ($code -eq 0x2329) -or ($code -eq 0x232A) -or
        ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
        ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
        ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6))) {
      $width += 2
    } else {
      $width += 1
    }
  }
  return $width
}

function Format-Row([string[]]$Cells, [int[]]$Widths) {
  $parts = @()
  for ($i = 0; $i -lt $Cells.Count; $i++) {
    $pad = $Widths[$i] - (Get-DisplayWidth $Cells[$i])
    if ($pad -lt 0) { $pad = 0 }
    $parts += ($Cells[$i] + (' ' * $pad))
  }
  return (($parts -join '  ').TrimEnd())
}

function Print-Table {
  $header = @('形态', '版本行', '库文件', '设置文件', 'PASS/FAIL')
  # A script-level failure (build, cleanup, restore) must not leave three green
  # rows above a non-zero exit code: every row fails with it.
  $scriptFailed = (@($script:checks | Where-Object { $_.Form -eq 'script' -and -not $_.Ok }).Count -gt 0)
  $rows = @()
  foreach ($form in @('dev', 'portable', 'installed')) {
    $row = $script:rows[$form]
    $passed = (Test-FormPassed $form) -and (-not $scriptFailed)
    $rows += ,@($form, $row.VersionLine, $row.Library, $row.Settings, $(if ($passed) { 'PASS' } else { 'FAIL' }))
  }
  $widths = @()
  for ($i = 0; $i -lt $header.Count; $i++) { $widths += (Get-DisplayWidth $header[$i]) }
  foreach ($cells in $rows) {
    for ($i = 0; $i -lt $cells.Count; $i++) {
      $w = Get-DisplayWidth $cells[$i]
      if ($w -gt $widths[$i]) { $widths[$i] = $w }
    }
  }
  Write-Output (Format-Row $header $widths)
  foreach ($cells in $rows) { Write-Output (Format-Row $cells $widths) }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$script:devExe = $script:exe
$script:devStashed = $null
$script:fixtureOttoStashed = $false
$script:version = ''
$script:feedPath = ''

$exitCode = 0
try {
  Assert-Preconditions
  Read-Version
  Invoke-Build

  if (-not (Test-Path -LiteralPath $script:exe)) { throw "missing exe after build: $($script:exe)" }
  if (-not (Test-Path -LiteralPath $script:helper)) { throw "missing helper after build: $($script:helper)" }

  # Fresh scratch space on every run: the script must be repeatable.
  if (Test-Path -LiteralPath $script:tempRoot) {
    Remove-Item -LiteralPath $script:tempRoot -Recurse -Force
  }
  foreach ($dir in @($script:tempRoot, $script:portableDir, $script:installedDir, $script:fakeAppData, $script:feedDir, $script:shotsDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  New-LocalUpdateFeed

  $script:fixtureHash = (Get-FileHash -LiteralPath $script:fixtureLibrary -Algorithm SHA256).Hash
  $script:realOttoBefore = Get-PathSnapshot $script:realOtto
  Write-Output ('== real %APPDATA%\OTTO snapshot: {0} ==' -f (Format-Snapshot $script:realOttoBefore))

  Initialize-DevStash

  try {
    Invoke-DevForm
  } catch {
    Add-Check 'dev' 'form aborted by an unexpected error' $false $_.Exception.Message
  }
  try {
    Invoke-PortableForm
  } catch {
    Add-Check 'portable' 'form aborted by an unexpected error' $false $_.Exception.Message
  }
  try {
    Invoke-InstalledForm
  } catch {
    Add-Check 'installed' 'form aborted by an unexpected error' $false $_.Exception.Message
  }
} catch {
  Add-Check 'script' 'fatal error before the forms could run' $false $_.Exception.Message
} finally {
  # Restore the developer's own dev artifacts and the real APPDATA value; remove
  # the throw-away tree unless -KeepTemp was asked for. If the restore failed,
  # keep the tree: it holds the only copy of whatever was moved aside.
  $restoreOk = $true
  try {
    Restore-DevStash
  } catch {
    $restoreOk = $false
    Add-Check 'script' 'failed to restore dev artifacts' $false (($_.Exception.Message) + '; temporary tree kept at ' + $script:tempRoot)
  }
  $env:APPDATA = $script:realAppData
  if (-not $restoreOk) {
    Write-Output ('kept temporary tree because the dev stash could not be restored: {0}' -f $script:tempRoot)
  } elseif (-not $KeepTemp) {
    try {
      if (Test-Path -LiteralPath $script:tempRoot) { Remove-Item -LiteralPath $script:tempRoot -Recurse -Force }
    } catch {
      Add-Check 'script' 'failed to remove the temporary tree' $false $_.Exception.Message
    }
  } else {
    Write-Output ('kept temporary tree: {0}' -f $script:tempRoot)
  }
  if (@($script:checks | Where-Object { -not $_.Ok }).Count -gt 0) { $exitCode = 1 }
}

Print-Table
exit $exitCode
