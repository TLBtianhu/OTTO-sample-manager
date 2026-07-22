param(
  [Parameter(Mandatory = $true)]
  [string]$Installer,

  [Parameter(Mandatory = $true)]
  [string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = (Resolve-Path -LiteralPath (Join-Path $repoRoot $Installer)).Path
$builtExecutable = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'src-tauri\target\release\otto-sample-manager.exe')).Path
$verifier = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'scripts\verify-tauri-release.mjs')).Path
$tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar)
$installRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot ("otto-electron-tauri-{0}" -f [guid]::NewGuid().ToString('N'))))

function Assert-ChildPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Parent
  )

  $parentPrefix = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  if (-not $Path.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to operate outside the temporary root: $Path"
  }
}

function Stop-TestProcesses {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root
  )

  Assert-ChildPath -Path $Root -Parent $tempRoot
  $rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $processes = Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
  }

  foreach ($process in $processes) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Wait-ForPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [int]$TimeoutSeconds = 30
  )

  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while (-not (Test-Path -LiteralPath $Path)) {
    if ([DateTime]::UtcNow -ge $deadline) {
      throw "Timed out waiting for $Path"
    }
    Start-Sleep -Milliseconds 200
  }
}

Assert-ChildPath -Path $installRoot -Parent $tempRoot
New-Item -ItemType Directory -Path $installRoot | Out-Null

try {
  $installerArguments = @('--updated', '/S', '--force-run', "/D=$installRoot")
  $installerProcess = Start-Process -FilePath $installerPath -ArgumentList $installerArguments -Wait -PassThru
  if ($installerProcess.ExitCode -ne 0) {
    throw "Electron-style NSIS invocation failed with exit code $($installerProcess.ExitCode)"
  }

  $installedExecutable = Join-Path $installRoot 'otto-sample-manager.exe'
  Wait-ForPath -Path $installedExecutable

  $installedVersion = (Get-Item -LiteralPath $installedExecutable).VersionInfo.ProductVersion
  if ($installedVersion -ne $ExpectedVersion) {
    throw "Installed executable version is $installedVersion; expected $ExpectedVersion"
  }

  & node $verifier `
    --exe $builtExecutable `
    --installer $installerPath `
    --installed-exe $installedExecutable `
    --expected-version $ExpectedVersion
  if ($LASTEXITCODE -ne 0) {
    throw "Installed executable verification failed with exit code $LASTEXITCODE"
  }

  [pscustomobject]@{
    InstallerArguments = $installerArguments -join ' '
    InstallRoot = $installRoot
    InstalledVersion = $installedVersion
    InstalledSubsystem = 2
  } | ConvertTo-Json
} finally {
  Stop-TestProcesses -Root $installRoot

  $uninstaller = Get-ChildItem -LiteralPath $installRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(?:uninstall|unins).*\.exe$' } |
    Select-Object -First 1
  if ($uninstaller) {
    $uninstallerProcess = Start-Process -FilePath $uninstaller.FullName -ArgumentList '/S' -PassThru
    if (-not $uninstallerProcess.WaitForExit(30000)) {
      throw 'Temporary uninstaller did not exit within 30 seconds'
    }
    if ($uninstallerProcess.ExitCode -ne 0) {
      Write-Warning "Temporary uninstaller exited with code $($uninstallerProcess.ExitCode)"
    }
  }

  Stop-TestProcesses -Root $installRoot
  Assert-ChildPath -Path $installRoot -Parent $tempRoot
  if (Test-Path -LiteralPath $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
  }
}
