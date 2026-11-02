# On-demand completion, path robustness and Explorer keys. Dot-sourced by browse.ps1.
# ASCII-only for Windows PowerShell 5.1; Chinese probe text is escaped at runtime.

function Invoke-RobustAcceptance {
  $robust = Join-Path $Root ('robust-' + [guid]::NewGuid().ToString('N'))
  $complete = Join-Path $robust 'complete'
  foreach ($name in @('alpha', 'alpine', 'beta')) {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $complete $name)
  }
  [IO.File]::WriteAllText((Join-Path $complete 'alpha-note.txt'), 'not a directory')
  [IO.File]::WriteAllText((Join-Path $complete 'only-file.txt'), 'not a directory')
  [IO.File]::WriteAllText((Join-Path $complete 'a-small.txt'), 'a')
  $noMatchText = [regex]::Unescape('无匹配')

  Write-Step '39. On-demand Tab completion cycles with one enumeration'
  $r = Invoke-Exe $Exe @('--browse-complete-probe', ('"{0}"' -f $complete), '--text=al')
  $line = @($r.Lines | Where-Object { $_ -like 'browse-complete-probe:*' }) | Select-Object -Last 1
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'matches') -eq '2' -and
    (Get-NavField $line 'sequence') -eq 'alpha;alpine;alpha' -and
    (Get-NavField $line 'current') -eq 'alpine' -and (Get-NavField $line 'enumerations') -eq '1' -and
    (Get-NavField $line 'writes') -eq '0')
  Add-Row 'Tab completion' ($(if ($ok) {'PASS'} else {'FAIL'})) ('matches={0} enumerations={1}' -f (Get-NavField $line 'matches'), (Get-NavField $line 'enumerations')) ('cycle={0}; reverse current={1}' -f (Get-NavField $line 'sequence'), (Get-NavField $line 'current'))

  Write-Step '40. No completion match is named and cached'
  $r = Invoke-Exe $Exe @('--browse-complete-probe', ('"{0}"' -f $complete), '--text=zzz-no-match')
  $line = @($r.Lines | Where-Object { $_ -like 'browse-complete-probe:*' }) | Select-Object -Last 1
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'matches') -eq '0' -and
    (Get-NavField $line 'message') -eq $noMatchText -and (Get-NavField $line 'enumerations') -eq '1' -and
    (Get-NavField $line 'error') -eq 'none')
  Add-Row 'No completion match' ($(if ($ok) {'PASS'} else {'FAIL'})) ('matches=0 enumerations={0}' -f (Get-NavField $line 'enumerations')) 'Two Tabs still enumerate once; no crash'

  Write-Step '41. Files never become address completion targets'
  $r = Invoke-Exe $Exe @('--browse-complete-probe', ('"{0}"' -f $complete), '--text=only')
  $line = @($r.Lines | Where-Object { $_ -like 'browse-complete-probe:*' }) | Select-Object -Last 1
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'matches') -eq '0' -and (Get-NavField $line 'sequence') -eq '')
  Add-Row 'Directories only' ($(if ($ok) {'PASS'} else {'FAIL'})) ('matches={0}' -f (Get-NavField $line 'matches')) 'only-file.txt is excluded'

  Write-Step '42. >260 path enumeration, explicit prefix and WIC preview'
  $long = $robust
  1..12 | ForEach-Object { $long = Join-Path $long (('segment-{0:d2}-' -f $_) + ('x' * 18)) }
  $null = [IO.Directory]::CreateDirectory('\\?\' + $long)
  $sample = 'C:\src\otto-testkit\samples\img00.png'
  if (-not (Test-Path -LiteralPath $sample)) { $sample = Join-Path $PSScriptRoot '..\..\otto-testkit\samples\img00.png' }
  $longFile = $long + '\cover.png'
  [IO.File]::WriteAllBytes('\\?\' + $longFile, [IO.File]::ReadAllBytes($sample))
  $normal = Invoke-Exe $Exe @('--browse-path-probe', ('"{0}"' -f $long))
  $extended = Invoke-Exe $Exe @('--browse-path-probe', ('"{0}"' -f ('\\?\' + $long)))
  $normalLine = @($normal.Lines | Where-Object { $_ -like 'browse-path-probe:*' }) | Select-Object -Last 1
  $extendedLine = @($extended.Lines | Where-Object { $_ -like 'browse-path-probe:*' }) | Select-Object -Last 1
  $preview = Invoke-Exe $Exe @('--preview', ('"{0}"' -f $longFile), '--no-shell-preview')
  $image = [regex]::Match($preview.Text, 'outcome=image (\d+)x(\d+)')
  $ok = ($long.Length -gt 260 -and (Get-NavField $normalLine 'kind') -eq 'long' -and
    (Get-NavField $normalLine 'error') -eq 'none' -and (Get-NavField $normalLine 'rows') -eq '1' -and
    (Get-NavField $extendedLine 'error') -eq 'none' -and (Get-NavField $extendedLine 'resolved').StartsWith('\\?\') -and
    $image.Success -and [int]$image.Groups[1].Value -gt 0)
  Add-Row 'Long path / preview' ($(if ($ok) {'PASS'} else {'FAIL'})) ('chars={0} rows={1} image={2}x{3}' -f $long.Length, (Get-NavField $normalLine 'rows'), $image.Groups[1].Value, $image.Groups[2].Value) 'Normal and explicit \\?\ forms; prefix preserved; WIC decode succeeds'

  Write-Step '43. Junction is followed and marked without recursive expansion'
  $junctionBase = Join-Path $robust 'junction'
  $target = Join-Path $junctionBase 'target'
  $link = Join-Path $junctionBase 'link'
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $target 'nested')
  [IO.File]::WriteAllText((Join-Path $target 'one.txt'), '1')
  [IO.File]::WriteAllText((Join-Path $target 'two.txt'), '2')
  [IO.File]::WriteAllText((Join-Path $target 'nested\deep.txt'), 'not direct')
  $null = New-Item -ItemType Junction -Path $link -Target $target
  $r = Invoke-Exe $Exe @('--browse-path-probe', ('"{0}"' -f $link))
  $line = @($r.Lines | Where-Object { $_ -like 'browse-path-probe:*' }) | Select-Object -Last 1
  $disk = @(Get-ChildItem -LiteralPath $target -Force).Count
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'kind') -eq 'junction' -and
    (Get-NavField $line 'error') -eq 'none' -and (Get-NavField $line 'rows') -eq [string]$disk -and
    (Get-NavField $line 'reparse') -eq 'true' -and (Get-NavField $line 'recursive') -eq 'false')
  Add-Row 'Junction' ($(if ($ok) {'PASS'} else {'FAIL'})) ('rows={0} reparse={1}' -f (Get-NavField $line 'rows'), (Get-NavField $line 'reparse')) 'Follows target; nested/deep.txt is not recursively listed'

  Write-Step '44. UNC syntax is accepted; real remote hardware is not tested'
  $unc = '\\localhost\otto-definitely-no-such-share\dir'
  $r = Invoke-Exe $Exe @('--browse-path-probe', ('"{0}"' -f $unc))
  $line = @($r.Lines | Where-Object { $_ -like 'browse-path-probe:*' }) | Select-Object -Last 1
  $reason = Get-NavField $line 'error'
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'kind') -eq 'unc' -and
    ($reason -eq 'PathNotFound' -or $reason -eq 'none') -and $reason -ne 'InvalidPath')
  Add-Row 'UNC syntax' ($(if ($ok) {'PASS'} else {'FAIL'})) ('kind=unc error={0}' -f $reason) 'Syntax/parser accepted; no real network share / hardware validation'

  Write-Step '45. Drive menu reports volume label with type fallback'
  $letter = $env:SystemDrive.Substring(0, 1).ToUpperInvariant()
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $complete), '--steps=f4')
  $line = Get-NavActionLine $r 'f4'
  $drives = Get-NavField $line 'drives'
  $shape = $drives -match ('(^|;)' + $letter + ':\\=(fixed|removable|remote|cdrom|ramdisk|unknown)(\[.*\])?(\(unavailable\))?(;|$)')
  $driveInfo = New-Object IO.DriveInfo $letter
  $labelOk = ($driveInfo.VolumeLabel.Length -eq 0 -or $drives.Contains('[' + $driveInfo.VolumeLabel + ']'))
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'menu') -eq 'true' -and $shape -and $labelOk)
  Add-Row 'Drive volume label' ($(if ($ok) {'PASS'} else {'FAIL'})) ('{0}: label={1}' -f $letter, $driveInfo.VolumeLabel) 'GetVolumeInformationW; kind remains visible for empty labels'

  Write-Step '46. F5 refreshes by epoch and restores selection by identity while editing'
  $disk = @(Get-ChildItem -LiteralPath $complete -Force).Count
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $complete), '--steps=select:a-small.txt,alt-d,f5')
  $start = Get-NavActionLine $r 'start'
  $line = Get-NavActionLine $r 'f5'
  $epochDelta = [int](Get-NavField $line 'epoch') - [int](Get-NavField $start 'epoch')
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'rows') -eq [string]$disk -and
    (Get-NavField $line 'selected') -eq 'a-small.txt' -and $epochDelta -eq 1 -and
    (Get-NavField $line 'editing') -eq 'true' -and (Get-NavField $line 'error') -eq 'none')
  Add-Row 'F5 refresh' ($(if ($ok) {'PASS'} else {'FAIL'})) ('rows={0} epoch+={1} selected={2}' -f (Get-NavField $line 'rows'), $epochDelta, (Get-NavField $line 'selected')) 'F5 refreshes in search/address edit states; drafts stay; never inserts a character'

  Write-Step '47. Alt+D equals Ctrl+L and F4 opens the drive menu'
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $complete), '--steps=ctrl-l,alt-d,f4')
  $ctrl = Get-NavActionLine $r 'ctrl-l'
  $alt = Get-NavActionLine $r 'alt-d'
  $f4 = Get-NavActionLine $r 'f4'
  $ok = ($r.Code -eq 0 -and (Get-NavField $ctrl 'editing') -eq 'true' -and
    (Get-NavField $alt 'editing') -eq 'true' -and (Get-NavField $f4 'menu') -eq 'true')
  Add-Row 'Alt+D / F4' ($(if ($ok) {'PASS'} else {'FAIL'})) ('alt_d_editing={0} f4_menu={1}' -f (Get-NavField $alt 'editing'), (Get-NavField $f4 'menu')) 'Same address focus path as Ctrl+L; menu remains inline and non-activating'

  Write-Step '48. Completion and F5 are zero-write operations'
  $beforeMap = Get-TreeFingerprint $complete
  $completeRun = Invoke-Exe $Exe @('--browse-complete-probe', ('"{0}"' -f $complete), '--text=al')
  $refreshRun = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $complete), '--steps=select:a-small.txt,f5')
  $afterMap = Get-TreeFingerprint $complete
  $diff = Compare-DirSnapshot $beforeMap $afterMap
  $generated = @(Get-ChildItem -LiteralPath $complete -Recurse -Force -File | Where-Object { $_.Name -eq 'settings.json' -or $_.Name -eq 'library.otto' }).Count
  $ok = ($completeRun.Code -eq 0 -and $refreshRun.Code -eq 0 -and $completeRun.Text -match 'writes=0' -and $diff -eq 0 -and $generated -eq 0)
  Add-Row 'Completion / refresh zero-write' ($(if ($ok) {'PASS'} else {'FAIL'})) ('fingerprint_diff={0} generated={1}' -f $diff, $generated) 'No source writes, settings or library files'

  $bad = @($script:rows | Where-Object { $_.Result -ne 'PASS' }).Count
  $count = @($script:rows).Count
  $ok = ($bad -eq 0 -and $count -eq 48)
  Add-Row 'Original 38 + robust checks' ($(if ($ok) {'PASS'} else {'FAIL'})) ('checked_rows={0} non_pass={1}' -f $count, $bad) 'Original 38 are unchanged; health -Quick and all three test suites run separately'
}
