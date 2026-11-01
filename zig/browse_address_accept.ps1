# Address bar / breadcrumbs / drives acceptance. Dot-sourced by browse.ps1; ASCII-only for PS 5.1.

function Invoke-AddressAcceptance {
  $nav = Join-Path $Root 'nav'
  $child = Join-Path $nav 'sub1'
  $rootDisk = @(Get-ChildItem -LiteralPath $nav -Force).Count
  $notFound = [regex]::Unescape('\u8def\u5f84\u4e0d\u5b58\u5728')
  $notDirectory = [regex]::Unescape('\u4e0d\u662f\u76ee\u5f55')

  Write-Step '28. Absolute address, trailing slash and surrounding spaces'
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $nav), ('--steps="set:  {0}\  ,enter"' -f $child))
  $line = Get-NavActionLine $r 'enter'
  $disk = @(Get-ChildItem -LiteralPath $child -Force).Count
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'path') -eq $child -and
    (Get-NavField $line 'rows') -eq [string]$disk -and (Get-NavField $line 'error') -eq 'none')
  Add-Row 'Address absolute' ($(if ($ok) {'PASS'} else {'FAIL'})) ('path={0} rows={1}' -f (Get-NavField $line 'path'), (Get-NavField $line 'rows')) 'Spaces and trailing slash are trimmed/resolved only on Enter'

  Write-Step '29. Relative path and ..'
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $nav), '--steps=set:sub1,enter,set:..\sub3,enter')
  $line = @($r.Lines | Where-Object { $_ -match ' action=enter ' }) | Select-Object -Last 1
  $target = Join-Path $nav 'sub3'
  $disk = @(Get-ChildItem -LiteralPath $target -Force).Count
  $ok = ((Get-NavField $line 'path') -eq $target -and (Get-NavField $line 'rows') -eq [string]$disk -and
    (Get-NavField $line 'error') -eq 'none')
  Add-Row 'Address relative / ..' ($(if ($ok) {'PASS'} else {'FAIL'})) ('path={0} rows={1}' -f (Get-NavField $line 'path'), (Get-NavField $line 'rows')) 'Relative input resolves against the current directory'

  Write-Step '30. Missing path is named and does not navigate'
  $missing = Join-Path $nav 'definitely-missing'
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $nav), ('--steps=set:{0},enter' -f $missing))
  $line = Get-NavActionLine $r 'enter'
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'error') -eq $notFound -and
    (Get-NavField $line 'path') -eq $nav -and (Get-NavField $line 'rows') -eq [string]$rootDisk -and
    (Get-NavField $line 'history') -eq '1')
  Add-Row 'Address missing path' ($(if ($ok) {'PASS'} else {'FAIL'})) ('error={0} history={1}' -f (Get-NavField $line 'error'), (Get-NavField $line 'history')) 'Path, rows and history remain unchanged'

  Write-Step '31. File submitted as a directory'
  $file = Join-Path $nav 'a-small.txt'
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $nav), ('--steps=set:{0},enter' -f $file))
  $line = Get-NavActionLine $r 'enter'
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'error') -eq $notDirectory -and
    (Get-NavField $line 'path') -eq $nav -and (Get-NavField $line 'rows') -eq [string]$rootDisk)
  Add-Row 'Address file rejection' ($(if ($ok) {'PASS'} else {'FAIL'})) ('error={0}' -f (Get-NavField $line 'error')) 'Named Not a directory; no crash and no jump'

  Write-Step '32. Breadcrumb jumps to the selected ancestor'
  $deep = Join-Path $child 'sub2'
  $segments = @($deep.TrimEnd('\') -split '\\' | Where-Object { $_.Length -gt 0 })
  $parentCrumb = $segments.Count - 1
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $deep), ('--steps=crumb:{0}' -f $parentCrumb))
  $line = Get-NavActionLine $r ('crumb:' + $parentCrumb)
  $disk = @(Get-ChildItem -LiteralPath $child -Force).Count
  $ok = ((Get-NavField $line 'path') -eq $child -and (Get-NavField $line 'rows') -eq [string]$disk -and
    (Get-NavField $line 'error') -eq 'none' -and (Get-NavField $line 'history') -eq '2')
  Add-Row 'Breadcrumb' ($(if ($ok) {'PASS'} else {'FAIL'})) ('crumb={0} rows={1} history={2}' -f $parentCrumb, (Get-NavField $line 'rows'), (Get-NavField $line 'history')) 'Deep paths render ellipsis + parent + current; indices remain absolute'

  Write-Step '33. Drive list, type labels and root navigation'
  $letter = $env:SystemDrive.Substring(0, 1).ToUpperInvariant()
  $driveRoot = $env:SystemDrive + '\'
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $nav), ('--steps=drive:{0}' -f $letter))
  $line = Get-NavActionLine $r ('drive:' + $letter)
  $drives = Get-NavField $line 'drives'
  $entries = @($drives -split ';' | Where-Object { $_.Length -gt 0 })
  $logical = @([Environment]::GetLogicalDrives())
  $listed = $true
  foreach ($logicalRoot in $logical) {
    if ($drives -notmatch ('(^|;)' + [regex]::Escape($logicalRoot) + '=')) { $listed = $false }
  }
  $unavailableNamed = (($drives -notmatch 'no_root') -or ($drives -match 'no_root\(unavailable\)'))
  $disk = @(Get-ChildItem -LiteralPath $driveRoot -Force).Count
  $rowsOk = ((Get-NavField $line 'rows') -eq [string][math]::Min($disk, 50000))
  $ok = ($r.Code -eq 0 -and (Get-NavField $line 'path') -eq $driveRoot -and $rowsOk -and
    $entries.Count -eq $logical.Count -and $listed -and $unavailableNamed -and
    $drives -match ('(^|;)' + $letter + ':\\=fixed'))
  Add-Row 'Drives' ($(if ($ok) {'PASS'} else {'FAIL'})) ('drives={0} rows={1}' -f $entries.Count, (Get-NavField $line 'rows')) ('{0}=fixed; no_root entries retain (unavailable)' -f $letter)

  Write-Step '34. Address and click navigation share history and identity selection'
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $nav), ('--steps=select:a-small.txt,set:{0},enter,back' -f $child))
  $entered = Get-NavActionLine $r 'enter'
  $back = Get-NavActionLine $r 'back'
  $click = Invoke-Exe $Exe @('--browse-nav-probe', ('"{0}"' -f $nav), '--steps=select:a-small.txt,enter:sub1,back')
  $clickBack = Get-NavActionLine $click 'back'
  $ok = ((Get-NavField $entered 'history') -eq '2' -and (Get-NavField $back 'history') -eq '2' -and
    (Get-NavField $back 'history') -eq (Get-NavField $clickBack 'history') -and
    (Get-NavField $back 'selected') -eq 'a-small.txt' -and
    (Get-NavField $back 'selected') -eq (Get-NavField $clickBack 'selected'))
  Add-Row 'Shared history / selection' ($(if ($ok) {'PASS'} else {'FAIL'})) ('history={0} selected={1}' -f (Get-NavField $back 'history'), (Get-NavField $back 'selected')) 'Same enter/activate stack as row clicks; File ID restore on Back'

  Write-Step '35. Escape cancels the draft without navigation'
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $nav), ('--steps=set:{0},esc' -f $missing))
  $setLine = Get-NavActionLine $r ('set:' + $missing)
  $line = Get-NavActionLine $r 'esc'
  $ok = ((Get-NavField $setLine 'path') -eq $nav -and (Get-NavField $setLine 'rows') -eq [string]$rootDisk -and
    (Get-NavField $line 'path') -eq $nav -and (Get-NavField $line 'rows') -eq [string]$rootDisk -and
    (Get-NavField $line 'history') -eq '1' -and (Get-NavField $line 'editing') -eq 'false' -and
    (Get-NavField $line 'error') -eq 'none')
  Add-Row 'Address Escape' ($(if ($ok) {'PASS'} else {'FAIL'})) ('path={0} editing={1}' -f (Get-NavField $line 'path'), (Get-NavField $line 'editing')) 'set performs no stat/navigation; Esc restores the current path'

  Write-Step '36. 100k directory address jump and Back stay under 90 MiB'
  $large = Join-Path $Root '100k'
  $largeChild = Join-Path $large 'a-nav-child'
  New-Item -ItemType Directory -Force -Path $largeChild | Out-Null
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $large), '--pages=3', ('--set-path="{0}"' -f $largeChild), '--steps=back')
  $start = Get-NavActionLine $r 'start'
  $jump = Get-NavActionLine $r 'set-path'
  $back = Get-NavActionLine $r 'back'
  $peak = [double](Get-NavField $back 'peak_mib')
  $startRows = [int](Get-NavField $start 'rows')
  $backRows = [int](Get-NavField $back 'rows')
  $ok = ($r.Code -eq 0 -and (Get-NavField $jump 'path') -eq $largeChild -and
    (Get-NavField $back 'path') -eq $large -and $startRows -ge 100000 -and
    ($backRows -eq 50000 -or $backRows -eq $startRows) -and $peak -le 90)
  Add-Row '100k address navigation' ($(if ($ok) {'PASS'} else {'FAIL'})) ('rows={0} peak_mib={1:N2}' -f $backRows, $peak) 'Address jump -> child -> Back; peak working set <= 90 MiB'

  Write-Step '37. Address navigation zero-write fingerprint'
  $beforeMap = Get-TreeFingerprint $nav
  $r = Invoke-Exe $Exe @('--browse-address-probe', ('"{0}"' -f $nav), ('--steps=set:{0},enter,back,set:{1},enter,esc' -f $child, $missing))
  $afterMap = Get-TreeFingerprint $nav
  $diff = Compare-DirSnapshot $beforeMap $afterMap
  $generated = @(Get-ChildItem -LiteralPath $nav -Recurse -Force -File | Where-Object { $_.Name -eq 'settings.json' -or $_.Name -eq 'library.otto' }).Count
  $ok = ($r.Code -eq 0 -and $diff -eq 0 -and $generated -eq 0)
  Add-Row 'Address zero-write' ($(if ($ok) {'PASS'} else {'FAIL'})) ('fingerprint_diff={0} generated={1}' -f $diff, $generated) 'No settings.json/library.otto; recursive source fingerprint unchanged'

  $bad = @($script:rows | Where-Object { $_.Result -ne 'PASS' }).Count
  $count = @($script:rows).Count
  $ok = ($bad -eq 0 -and $count -eq 37)
  Add-Row 'Full browse regression' ($(if ($ok) {'PASS'} else {'FAIL'})) ('checked_rows={0} non_pass={1}' -f $count, $bad) 'Original 27 + ten address checks; health and three test suites run separately'
}
