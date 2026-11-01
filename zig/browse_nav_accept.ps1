# Stage 1 navigation acceptance. Dot-sourced by browse.ps1; ASCII-only for PS 5.1.

function Initialize-NavFixture {
  param([string]$Base)
  $nav = Join-Path $Base 'nav'
  if (Test-Path -LiteralPath $nav) { Remove-Item -LiteralPath $nav -Recurse -Force }
  $dirs = @('sub1\sub2', 'sub1\sub3', 'sub3', 'hidden-dir', 'system-dir')
  foreach ($name in $dirs) { New-Item -ItemType Directory -Force -Path (Join-Path $nav $name) | Out-Null }
  $bytes = [System.Text.Encoding]::ASCII
  [IO.File]::WriteAllBytes((Join-Path $nav 'a-small.txt'), $bytes.GetBytes('a'))
  [IO.File]::WriteAllBytes((Join-Path $nav 'b-mid.mp3'), $bytes.GetBytes('0123456789'))
  [IO.File]::WriteAllBytes((Join-Path $nav 'z-large.wav'), $bytes.GetBytes(('x' * 100)))
  [IO.File]::WriteAllBytes((Join-Path $nav 'sub1\one.txt'), $bytes.GetBytes('1'))
  [IO.File]::WriteAllBytes((Join-Path $nav 'sub1\two.wav'), $bytes.GetBytes('22'))
  [IO.File]::WriteAllBytes((Join-Path $nav 'sub1\sub2\deep.txt'), $bytes.GetBytes('deep'))
  [IO.File]::WriteAllBytes((Join-Path $nav 'sub3\three.txt'), $bytes.GetBytes('3'))
  [IO.File]::SetLastWriteTimeUtc((Join-Path $nav 'a-small.txt'), [datetime]'2024-03-01T00:00:00Z')
  [IO.File]::SetLastWriteTimeUtc((Join-Path $nav 'b-mid.mp3'), [datetime]'2024-01-01T00:00:00Z')
  [IO.File]::SetLastWriteTimeUtc((Join-Path $nav 'z-large.wav'), [datetime]'2024-02-01T00:00:00Z')
  (Get-Item -LiteralPath (Join-Path $nav 'hidden-dir') -Force).Attributes += [IO.FileAttributes]::Hidden
  (Get-Item -LiteralPath (Join-Path $nav 'system-dir') -Force).Attributes += [IO.FileAttributes]::System
  return $nav
}

function Get-NavField {
  param([string]$Line, [string]$Name)
  $match = [regex]::Match($Line, '(?:^| )' + [regex]::Escape($Name) + '=(\S*)')
  if ($match.Success) { return $match.Groups[1].Value }
  return ''
}

function Get-NavActionLine {
  param($Result, [string]$Action)
  return @($Result.Lines | Where-Object { $_ -match (' action=' + [regex]::Escape($Action) + ' ') }) | Select-Object -Last 1
}

function Get-TreeFingerprint {
  param([string]$Base)
  $map = @{}
  foreach ($item in (Get-ChildItem -LiteralPath $Base -Recurse -Force -ErrorAction SilentlyContinue)) {
    $relative = $item.FullName.Substring($Base.Length).TrimStart('\')
    $length = if ($item.PSIsContainer) { 0 } else { $item.Length }
    # Directory mtime can be flushed lazily after fixture creation. Track directory
    # identity/attributes, and track full size+mtime for every file (product writes).
    $map[$relative] = if ($item.PSIsContainer) { 'dir:{0}' -f [int]$item.Attributes } else { '{0}:{1}:{2}' -f $length, $item.LastWriteTimeUtc.Ticks, [int]$item.Attributes }
  }
  return $map
}

function Invoke-NavAcceptance {
  $nav = Initialize-NavFixture $Root
  $dirPrefix = 'hidden-dir;sub1;sub3;system-dir;'

  Write-Step '16. Enter a subdirectory (directories/hidden/system included)'
  $r = Invoke-Exe $Exe @('--browse-nav-probe', ('"{0}"' -f $nav), '--steps=enter:sub1')
  $start = Get-NavActionLine $r 'start'
  $entered = Get-NavActionLine $r 'enter:sub1'
  $disk = @(Get-ChildItem -LiteralPath (Join-Path $nav 'sub1') -Force).Count
  $rootDisk = @(Get-ChildItem -LiteralPath $nav -Force).Count
  $ok = ($r.Code -eq 0 -and (Get-NavField $start 'rows') -eq [string]$rootDisk -and
    (Get-NavField $start 'order') -eq ($dirPrefix + 'a-small.txt;b-mid.mp3;z-large.wav') -and
    (Get-NavField $entered 'path') -eq (Join-Path $nav 'sub1') -and
    (Get-NavField $entered 'rows') -eq [string]$disk -and (Get-NavField $entered 'error') -eq 'none')
  Add-Row 'Enter directory' ($(if ($ok) {'PASS'} else {'FAIL'})) ('root_rows={0} child_rows={1}' -f (Get-NavField $start 'rows'), (Get-NavField $entered 'rows')) 'Directories first; hidden/system remain listed'

  Write-Step '17. Back / forward and unique history'
  $r = Invoke-Exe $Exe @('--browse-nav-probe', ('"{0}"' -f $nav), '--steps=enter:sub1,enter:sub2,back,forward')
  $one = Get-NavActionLine $r 'enter:sub1'
  $two = Get-NavActionLine $r 'enter:sub2'
  $back = Get-NavActionLine $r 'back'
  $forward = Get-NavActionLine $r 'forward'
  $historyOk = (@($r.Lines | Where-Object { [int](Get-NavField $_ 'history') -gt 3 }).Count -eq 0)
  $ok = ((Get-NavField $back 'path') -eq (Get-NavField $one 'path') -and
    (Get-NavField $back 'rows') -eq (Get-NavField $one 'rows') -and
    (Get-NavField $forward 'path') -eq (Get-NavField $two 'path') -and
    (Get-NavField $forward 'rows') -eq (Get-NavField $two 'rows') -and $historyOk)
  Add-Row 'Back / forward' ($(if ($ok) {'PASS'} else {'FAIL'})) ('back={0} forward={1} history_max<=3' -f (Get-NavField $back 'path'), (Get-NavField $forward 'path')) 'Rows restored; no duplicate directory nodes'

  Write-Step '18. Parent and named filesystem-root refusal'
  $r = Invoke-Exe $Exe @('--browse-nav-probe', ('"{0}"' -f $nav), '--steps=enter:sub1,up')
  $up = Get-NavActionLine $r 'up'
  $rootProbe = Invoke-Exe $Exe @('--browse-nav-probe', 'C:\', '--browse-limit=1', '--steps=up')
  $rootUp = Get-NavActionLine $rootProbe 'up'
  $ok = ((Get-NavField $up 'path') -eq $nav -and (Get-NavField $up 'rows') -eq [string]$rootDisk -and
    (Get-NavField $up 'history') -eq '2' -and (Get-NavField $rootUp 'error') -eq 'AtFilesystemRoot')
  Add-Row 'Parent directory' ($(if ($ok) {'PASS'} else {'FAIL'})) ('up_rows={0} root_error={1}' -f (Get-NavField $up 'rows'), (Get-NavField $rootUp 'error')) 'root->sub->up keeps two unique history nodes'

  Write-Step '19. Selection restored by identity after Back'
  $r = Invoke-Exe $Exe @('--browse-nav-probe', ('"{0}"' -f $nav), '--steps=select:a-small.txt,enter:sub1,back')
  $back = Get-NavActionLine $r 'back'
  $ok = ((Get-NavField $back 'selected') -eq 'a-small.txt' -and (Get-NavField $back 'path') -eq $nav)
  Add-Row 'Selection restore' ($(if ($ok) {'PASS'} else {'FAIL'})) ('selected={0}' -f (Get-NavField $back 'selected')) 'Path locates candidate; File ID is verified'

  Write-Step '20. Watcher follows entered directory (copy 20 externally)'
  $child = Join-Path $nav 'sub1'
  foreach ($item in @(Get-ChildItem -LiteralPath $child -File -Filter 'nav-copy-*.txt' -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $item.FullName -Force }
  $source = Join-Path $nav 'a-small.txt'
  $action = {
    for ($i = 0; $i -lt 20; $i++) { Copy-Item -LiteralPath $source -Destination (Join-Path $child ('nav-copy-{0:d2}.txt' -f $i)) -Force }
  }.GetNewClosure()
  $r = Invoke-ExeWhile $Exe @('--browse-nav-watch-probe', ('"{0}"' -f $nav), '--steps=enter:sub1', '--watch-seconds=4') 1000 $action
  $line = @($r.Lines | Where-Object { $_ -like 'browse-nav-watch-probe:*' }) | Select-Object -Last 1
  $events = [int](Get-NavField $line 'events')
  $before = [int](Get-NavField $line 'rows_before')
  $after = [int](Get-NavField $line 'rows_after')
  $ok = ($r.Code -eq 0 -and $events -gt 0 -and ($after - $before) -eq 20 -and (Get-NavField $line 'path') -eq $child)
  Add-Row 'Watcher follows' ($(if ($ok) {'PASS'} else {'FAIL'})) ('events={0} rows={1}->{2}' -f $events, $before, $after) 'Changes are from the new child, not the old root'

  Write-Step '21. Four sort keys; directories first; selection stable'
  $r = Invoke-Exe $Exe @('--browse-nav-probe', ('"{0}"' -f $nav), '--steps=select:b-mid.mp3,sort:size,sort:mtime,sort:type,sort:name')
  $expected = @{ 'sort:size' = 'a-small.txt;b-mid.mp3;z-large.wav'; 'sort:mtime' = 'b-mid.mp3;z-large.wav;a-small.txt'; 'sort:type' = 'b-mid.mp3;a-small.txt;z-large.wav'; 'sort:name' = 'a-small.txt;b-mid.mp3;z-large.wav' }
  $ok = $true
  foreach ($key in @('sort:size', 'sort:mtime', 'sort:type', 'sort:name')) {
    $line = Get-NavActionLine $r $key
    $parts = @((Get-NavField $line 'order') -split ';')
    if ($parts.Count -ne 7) { $ok = $false; continue }
    $files = ($parts[4..6] -join ';')
    $dirs = @($parts[0..3] | Sort-Object) -join ';'
    if ($files -ne $expected[$key] -or $dirs -ne 'hidden-dir;sub1;sub3;system-dir' -or
      (Get-NavField $line 'selected') -ne 'b-mid.mp3') { $ok = $false }
  }
  Add-Row 'Sort modes' ($(if ($ok) {'PASS'} else {'FAIL'})) 'size/mtime/type/name order OK' 'Directories always first; selected=b-mid.mp3 throughout'

  Write-Step '22. 100k directory enter/back under pagination and 90 MiB'
  $large = Join-Path $Root '100k'
  New-Item -ItemType Directory -Force -Path (Join-Path $large 'a-nav-child') | Out-Null
  $r = Invoke-Exe $Exe @('--browse-nav-probe', ('"{0}"' -f $large), '--pages=3', '--steps=enter:a-nav-child,back')
  $start = Get-NavActionLine $r 'start'
  $entered = Get-NavActionLine $r 'enter:a-nav-child'
  $back = Get-NavActionLine $r 'back'
  $peak = [double](Get-NavField $back 'peak_mib')
  $startRows = [int](Get-NavField $start 'rows')
  $budgetOk = ($startRows -eq 100001 -or ($startRows -eq 100000 -and (Get-NavField $start 'mem_refused') -eq 'true' -and (Get-NavField $start 'remaining') -eq '1'))
  $backRows = [int](Get-NavField $back 'rows')
  $backPagingOk = ($backRows -eq 50000 -or $backRows -eq $startRows)
  $ok = ($r.Code -eq 0 -and $startRows -ge 100000 -and $budgetOk -and $backPagingOk -and
    (Get-NavField $entered 'error') -eq 'none' -and (Get-NavField $back 'error') -eq 'none' -and
    (Get-NavField $back 'path') -eq $large -and $peak -le 90)
  Add-Row '100k navigation' ($(if ($ok) {'PASS'} else {'FAIL'})) ('rows={0} peak_mib={1:N2}' -f (Get-NavField $back 'rows'), $peak) 'First page restored on Back; prior pages/budget refusal stay named'

  Write-Step '23. Navigation zero-write fingerprint'
  $beforeMap = Get-TreeFingerprint $nav
  $r = Invoke-Exe $Exe @('--browse-nav-probe', ('"{0}"' -f $nav), '--steps=select:a-small.txt,enter:sub1,enter:sub2,back,up,sort:size,enter:sub3,back')
  $afterMap = Get-TreeFingerprint $nav
  $diff = Compare-DirSnapshot $beforeMap $afterMap
  if ($diff -ne 0) {
    foreach ($key in $beforeMap.Keys) {
      if (-not $afterMap.ContainsKey($key)) { Write-Output ('  fingerprint removed: ' + $key) }
      elseif ($afterMap[$key] -ne $beforeMap[$key]) { Write-Output ('  fingerprint changed: {0} {1} -> {2}' -f $key, $beforeMap[$key], $afterMap[$key]) }
    }
    foreach ($key in $afterMap.Keys) { if (-not $beforeMap.ContainsKey($key)) { Write-Output ('  fingerprint added: ' + $key) } }
  }
  $generated = @(Get-ChildItem -LiteralPath $nav -Recurse -Force -File | Where-Object { $_.Name -eq 'settings.json' -or $_.Name -eq 'library.otto' }).Count
  $ok = ($r.Code -eq 0 -and $diff -eq 0 -and $generated -eq 0)
  Add-Row 'Navigation zero-write' ($(if ($ok) {'PASS'} else {'FAIL'})) ('fingerprint_diff={0} generated={1}' -f $diff, $generated) 'Recursive directory names/attributes + file relative path/size/mtime fingerprint'

  $bad = @($script:rows | Where-Object { $_.Result -ne 'PASS' }).Count
  $count = @($script:rows).Count
  $ok = ($bad -eq 0 -and $count -eq 26)
  Add-Row 'Stage 0 + Stage 1 regression' ($(if ($ok) {'PASS'} else {'FAIL'})) ('checked_rows={0} non_pass={1}' -f $count, $bad) 'health.ps1 -Quick and all three test suites are run separately'
}
