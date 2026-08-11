param([string]$Root)

$ErrorActionPreference = 'Stop'
if (-not $Root) {
  $Root = Join-Path $PSScriptRoot '..\test-data'
}
$rootPath = [IO.Path]::GetFullPath($Root)
$chineseDirectory = -join ([char[]](0x4E2D, 0x6587, 0x8DEF, 0x5F84))
$chineseFileName = (-join ([char[]](0x4E2D, 0x6587, 0x91C7, 0x6837))) + '.wav'
$paths = @(
  (Join-Path $rootPath 'ascii\a.wav'),
  (Join-Path (Join-Path $rootPath $chineseDirectory) $chineseFileName),
  (Join-Path $rootPath ('long-path\' + ('segment-' + ('x' * 24) + '\') * 5 + 'a.wav'))
)

function Write-TestWave([string]$Path) {
  $sampleRate = 44100
  $seconds = 1
  $samples = $sampleRate * $seconds
  $dataSize = $samples * 2
  $directory = Split-Path -Parent $Path
  New-Item -ItemType Directory -Force -Path $directory | Out-Null

  $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write)
  $writer = [IO.BinaryWriter]::new($stream, [Text.Encoding]::ASCII, $false)
  try {
    $writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'))
    $writer.Write([int](36 + $dataSize))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('WAVE'))
    $writer.Write([Text.Encoding]::ASCII.GetBytes('fmt '))
    $writer.Write([int]16)
    $writer.Write([int16]1)
    $writer.Write([int16]1)
    $writer.Write([int]$sampleRate)
    $writer.Write([int]($sampleRate * 2))
    $writer.Write([int16]2)
    $writer.Write([int16]16)
    $writer.Write([Text.Encoding]::ASCII.GetBytes('data'))
    $writer.Write([int]$dataSize)
    for ($i = 0; $i -lt $samples; $i++) {
      $value = [Math]::Sin(2 * [Math]::PI * 440 * $i / $sampleRate) * 0.2
      $writer.Write([int16]($value * [int16]::MaxValue))
    }
  } finally {
    $writer.Dispose()
  }
}

foreach ($path in $paths) {
  Write-TestWave $path
}

$paths | ForEach-Object {
  Get-Item -LiteralPath $_ | Select-Object FullName, Length, LastWriteTime
}
