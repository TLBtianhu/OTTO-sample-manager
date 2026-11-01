# Repeatable OTTO thumbnail-helper contract acceptance.
# Runs only headless --preview processes in a unique temporary distribution.
# Requires ports zig-out fake helpers; run `zig build test` under zig/ports first.

[CmdletBinding()]
param(
  [string]$Exe = '',
  [string]$Helper = '',
  [string]$TimeoutHelper = '',
  [string]$CrashHelper = ''
)

$ErrorActionPreference = 'Stop'
$script:root = $PSScriptRoot
if (-not $Exe) { $Exe = Join-Path $script:root 'app\zig-out\bin\otto-lite.exe' }
$Exe = [IO.Path]::GetFullPath($Exe)
if (-not $Helper) { $Helper = Join-Path (Split-Path -Parent $Exe) 'otto-thumb-host.exe' }
if (-not $TimeoutHelper) { $TimeoutHelper = Join-Path $script:root 'ports\zig-out\bin\otto-thumb-host-fake.exe' }
if (-not $CrashHelper) { $CrashHelper = Join-Path $script:root 'ports\zig-out\bin\otto-thumb-host-crash-fake.exe' }
$Helper = [IO.Path]::GetFullPath($Helper)
$TimeoutHelper = [IO.Path]::GetFullPath($TimeoutHelper)
$CrashHelper = [IO.Path]::GetFullPath($CrashHelper)

foreach ($required in @($Exe, $Helper, $TimeoutHelper, $CrashHelper)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "required executable missing: $required (run zig/ports build test first)"
  }
}

$script:tempRoot = Join-Path $env:TEMP ('otto-helper-contract-' + [Guid]::NewGuid().ToString('N'))
$script:tempRoot = [IO.Path]::GetFullPath($script:tempRoot)
$script:distDir = Join-Path $script:tempRoot 'dist'
$script:sample = Join-Path $script:tempRoot 'fixture.webp'
$script:appData = Join-Path $script:tempRoot 'appdata'
$script:localAppData = Join-Path $script:tempRoot 'localappdata'
$script:failures = 0

function Get-PreviewField {
  param([string[]]$Lines, [string]$Pattern)
  foreach ($line in $Lines) {
    if ($line -match $Pattern) { return [string]$Matches[1] }
  }
  return ''
}

function Invoke-HeadlessPreview {
  param(
    [string]$ExePath,
    [string]$HelperPath,
    [bool]$NoIsolation
  )
  $exeArgs = @('--preview', ('"{0}"' -f $script:sample))
  if ($NoIsolation) { $exeArgs += '--no-isolation' }
  $arguments = $exeArgs -join ' '
  Write-Host ('  $ "{0}" {1}' -f $ExePath, $arguments)

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ExePath
  $psi.Arguments = $arguments
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.EnvironmentVariables['OTTO_THUMB_HOST'] = $HelperPath
  $psi.EnvironmentVariables['APPDATA'] = $script:appData
  $psi.EnvironmentVariables['LOCALAPPDATA'] = $script:localAppData

  $process = [System.Diagnostics.Process]::Start($psi)
  $mainPid = $process.Id
  $outTask = $process.StandardOutput.ReadToEndAsync()
  $errTask = $process.StandardError.ReadToEndAsync()
  $finished = $process.WaitForExit(15000)
  if (-not $finished) {
    $process.Kill()
    $process.WaitForExit()
  }
  $stdout = [string]$outTask.Result
  $stderr = [string]$errTask.Result
  $code = if ($finished) { $process.ExitCode } else { -9 }
  $process.Dispose()

  $lines = @()
  foreach ($stream in @($stdout, $stderr)) {
    foreach ($line in ($stream -split "`r?`n")) {
      if ($line -ne '') { $lines += $line }
    }
  }
  if (-not $finished) { $lines += 'acceptance: main process exceeded 15s and was killed' }

  $spawnPids = @()
  $spawnPaths = @()
  foreach ($line in $lines) {
    if ($line -match '^\[thumb-host\] helper .* pid=(\d+) size=\d+ exe=(.*) spawn_total=\d+$') {
      $spawnPids += [int]$Matches[1]
      $spawnPaths += [string]$Matches[2]
    }
  }

  return New-Object psobject -Property @{
    Code = $code
    MainPid = $mainPid
    Lines = [string[]]$lines
    Text = [string]::Join("`n", [string[]]$lines)
    Provider = (Get-PreviewField $lines '^preview: provider=(\S+) kind=')
    Outcome = (Get-PreviewField $lines '^preview: outcome=(\w+)')
    Reason = (Get-PreviewField $lines '^preview: outcome=none reason=(\w+)')
    Domain = (Get-PreviewField $lines '^preview: provider=.* execution_domain=(\w+)')
    SpawnPids = [int[]]$spawnPids
    SpawnPaths = [string[]]$spawnPaths
  }
}

function Wait-HelperExit {
  param([int[]]$ProcessIds)
  foreach ($pidValue in $ProcessIds) {
    $gone = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
      if (-not (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) {
        $gone = $true
        break
      }
      Start-Sleep -Milliseconds 50
    }
    if (-not $gone) { return $false }
  }
  return $true
}

function Test-PreviewContract {
  param(
    $Run,
    [string]$ExpectedOutcome,
    [string]$ExpectedReason,
    [string]$ExpectedDomain,
    [string]$ExpectedError,
    [string]$ExpectedHelperPath,
    [bool]$ExpectSpawn
  )
  $problems = @()
  if ($Run.Code -ne 0) { $problems += "exit=$($Run.Code), expected 0" }
  if ($Run.Provider -ne 'shell-thumbnail') { $problems += "provider=$($Run.Provider), expected shell-thumbnail" }
  if ($Run.Outcome -ne $ExpectedOutcome) { $problems += "outcome=$($Run.Outcome), expected $ExpectedOutcome" }
  if ($Run.Reason -ne $ExpectedReason) { $problems += "reason=$($Run.Reason), expected '$ExpectedReason'" }
  if ($Run.Domain -ne $ExpectedDomain) { $problems += "summary domain=$($Run.Domain), expected $ExpectedDomain" }
  if ($Run.Text -notmatch [regex]::Escape("execution_domain=$ExpectedDomain")) {
    $problems += "missing execution_domain=$ExpectedDomain log"
  }
  if ($Run.Text -notmatch 'preview: OK') { $problems += 'missing preview: OK' }
  if ($Run.Text -match 'leaked') { $problems += 'SafeAllocator leak reported' }

  if ($ExpectedDomain -eq 'helper') {
    if ($Run.Text -match 'Shell .*execution_domain=in_process') { $problems += 'main-process fetch log is forbidden' }
  } else {
    if ($Run.Text -match 'Shell .*execution_domain=helper') { $problems += 'helper fetch log is forbidden under --no-isolation' }
    if ($Run.SpawnPids.Count -ne 0) { $problems += 'helper spawned under --no-isolation' }
  }

  if ($ExpectedError) {
    if ($Run.Text -notmatch [regex]::Escape("result=$ExpectedError")) {
      $problems += "missing named error result=$ExpectedError"
    }
  }

  if ($ExpectSpawn) {
    if ($Run.SpawnPids.Count -eq 0) { $problems += 'no helper process was spawned' }
    foreach ($actualPath in $Run.SpawnPaths) {
      if ([IO.Path]::GetFullPath($actualPath) -ine [IO.Path]::GetFullPath($ExpectedHelperPath)) {
        $problems += "helper path=$actualPath, expected $ExpectedHelperPath"
      }
    }
  } elseif ($Run.SpawnPids.Count -ne 0) {
    $problems += 'unexpected helper spawn'
  }

  if (-not (Wait-HelperExit $Run.SpawnPids)) {
    $problems += "helper process left running: $($Run.SpawnPids -join ',')"
  }
  return $problems
}

function Get-ReverseProblems {
  param(
    $Run,
    [string]$ExpectedOutcome,
    [string]$ExpectedReason,
    [string]$ExpectedDomain,
    [string]$ExpectedError,
    [string]$ExpectedHelperPath,
    [bool]$ExpectSpawn
  )
  # Deliberately corrupt both the four-state answer and the execution-domain log.
  # A checker that accepts this mutated record is vacuous and must fail the run.
  $bad = $Run | Select-Object *
  if ($ExpectedReason -eq 'failed') {
    $bad.Reason = 'unsupported'
  } else {
    $bad.Outcome = 'none'
    $bad.Reason = 'failed'
  }
  $otherDomain = if ($ExpectedDomain -eq 'helper') { 'in_process' } else { 'helper' }
  $bad.Lines = @($bad.Lines) + "otto-lite: Shell thumbnail execution_domain=$otherDomain result=image file=reverse-control"
  $bad.Text = [string]::Join("`n", [string[]]$bad.Lines)
  return @(Test-PreviewContract -Run $bad -ExpectedOutcome $ExpectedOutcome -ExpectedReason $ExpectedReason -ExpectedDomain $ExpectedDomain -ExpectedError $ExpectedError -ExpectedHelperPath $ExpectedHelperPath -ExpectSpawn $ExpectSpawn)
}

try {
  New-Item -ItemType Directory -Path $script:distDir -Force | Out-Null
  New-Item -ItemType Directory -Path $script:appData -Force | Out-Null
  New-Item -ItemType Directory -Path $script:localAppData -Force | Out-Null
  Write-Output "temporary distribution: $script:distDir"

  $localExe = Join-Path $script:distDir 'otto-lite.exe'
  $localHelper = Join-Path $script:distDir 'otto-thumb-host.exe'
  $localTimeout = Join-Path $script:distDir 'otto-thumb-host-timeout.exe'
  $localCrash = Join-Path $script:distDir 'otto-thumb-host-crash.exe'
  Copy-Item -LiteralPath $Exe -Destination $localExe
  Copy-Item -LiteralPath $Helper -Destination $localHelper
  Copy-Item -LiteralPath $TimeoutHelper -Destination $localTimeout
  Copy-Item -LiteralPath $CrashHelper -Destination $localCrash

  # A valid 96x96 WebP, embedded so acceptance needs no source-tree or user asset.
  [IO.File]::WriteAllBytes($script:sample, [Convert]::FromBase64String('UklGRlwAAABXRUJQVlA4IFAAAABQBQCdASpgAGAAPjEYi0QiIaEQdAAgAwS0gDsAfgB+AAAIHVXy9xp7yb6dOnTp06dOjgAA/vWJH//7B0wZc/xXv//pokeP36KE7cAAAAAAAA=='))
  $missingHelper = Join-Path $script:distDir 'missing\otto-thumb-host.exe'
  $directoryHelper = Join-Path $script:distDir 'helper-is-directory.exe'
  New-Item -ItemType Directory -Path $directoryHelper -Force | Out-Null

  $cases = @(
    [pscustomobject]@{ Name = 'helper-present'; Helper = $localHelper; NoIsolation = $false; Outcome = 'image'; Reason = ''; Domain = 'helper'; Error = ''; Spawn = $true },
    [pscustomobject]@{ Name = 'helper-missing'; Helper = $missingHelper; NoIsolation = $false; Outcome = 'none'; Reason = 'failed'; Domain = 'helper'; Error = 'HelperUnavailable'; Spawn = $false },
    [pscustomobject]@{ Name = 'helper-start-failure-directory'; Helper = $directoryHelper; NoIsolation = $false; Outcome = 'none'; Reason = 'failed'; Domain = 'helper'; Error = 'HelperUnavailable'; Spawn = $false },
    [pscustomobject]@{ Name = 'helper-timeout'; Helper = $localTimeout; NoIsolation = $false; Outcome = 'none'; Reason = 'failed'; Domain = 'helper'; Error = 'Timeout'; Spawn = $true },
    [pscustomobject]@{ Name = 'helper-crash'; Helper = $localCrash; NoIsolation = $false; Outcome = 'none'; Reason = 'failed'; Domain = 'helper'; Error = 'ShellFailure'; Spawn = $true },
    [pscustomobject]@{ Name = 'explicit-no-isolation'; Helper = $missingHelper; NoIsolation = $true; Outcome = 'image'; Reason = ''; Domain = 'in_process'; Error = ''; Spawn = $false }
  )

  foreach ($case in $cases) {
    Write-Output ''
    Write-Output "=== $($case.Name) ==="
    $run = Invoke-HeadlessPreview -ExePath $localExe -HelperPath $case.Helper -NoIsolation $case.NoIsolation
    foreach ($line in $run.Lines) { Write-Output ('  | ' + $line) }

    $actualProblems = @(Test-PreviewContract -Run $run -ExpectedOutcome $case.Outcome -ExpectedReason $case.Reason -ExpectedDomain $case.Domain -ExpectedError $case.Error -ExpectedHelperPath $case.Helper -ExpectSpawn $case.Spawn)
    $reverseProblems = @(Get-ReverseProblems -Run $run -ExpectedOutcome $case.Outcome -ExpectedReason $case.Reason -ExpectedDomain $case.Domain -ExpectedError $case.Error -ExpectedHelperPath $case.Helper -ExpectSpawn $case.Spawn)

    foreach ($problem in $actualProblems) { Write-Output "  [FAIL] $problem" }
    if ($actualProblems.Count -eq 0) {
      Write-Output ('  [PASS] outcome={0} reason={1} domain={2} main_pid={3} helper_pids={4}' -f $run.Outcome, $run.Reason, $run.Domain, $run.MainPid, ($run.SpawnPids -join ','))
    }
    if ($reverseProblems.Count -eq 0) {
      Write-Output '  [FAIL] reverse control was accepted (checker is vacuous)'
    } else {
      Write-Output "  [PASS] reverse control rejected: $($reverseProblems[0])"
    }
    if ($actualProblems.Count -ne 0 -or $reverseProblems.Count -eq 0) { $script:failures++ }
  }

  if ($script:failures -eq 0) {
    Write-Output ''
    Write-Output 'helper-contract: PASS (6/6 scenarios + 6/6 reverse controls; no helper processes left)'
  } else {
    Write-Output ''
    Write-Output "helper-contract: FAIL ($script:failures scenario(s))"
  }
} finally {
  $fullTemp = [IO.Path]::GetFullPath($script:tempRoot)
  $tempParent = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
  $leaf = Split-Path -Leaf $fullTemp
  $parent = (Split-Path -Parent $fullTemp).TrimEnd('\')
  if ($parent -ieq $tempParent -and $leaf.StartsWith('otto-helper-contract-')) {
    if (Test-Path -LiteralPath $fullTemp) { Remove-Item -LiteralPath $fullTemp -Recurse -Force }
    Write-Output "temporary tree removed: $fullTemp"
  } else {
    Write-Warning "refused to remove unexpected temp path: $fullTemp"
  }
}

if ($script:failures -ne 0) { exit 1 }
