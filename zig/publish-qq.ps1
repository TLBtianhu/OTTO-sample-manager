# 把 OTTO 的安装包发到**指定 QQ 群**。
#
#   & '.\zig\publish-qq.ps1' -Version 0.39.0              # 预演：只打印，不发
#   & '.\zig\publish-qq.ps1' -Version 0.39.0 -Send       # 真的发
#
# 为什么单独一个脚本而不是"让机器人自己发"：
#   发布是对外出口，必须是人的动作。机器人只负责答疑和收反馈，
#   不该有"替作者对外发安装包"的能力。（与 release-announce.mjs 同一条原则）
#
# 默认 dry-run；只有显式 -Send 才会调用 upload_group_file。
# 群白名单写死在下面，不在名单里的群一律拒绝。
param(
  [Parameter(Mandatory = $true)][string]$Version,
  [switch]$Send,
  [switch]$PortableOnly,
  [string]$Notes = '',
  [string]$BridgeDir = 'C:\qq机器人\qq-bridge'
)

$ErrorActionPreference = 'Stop'
$script:here = Split-Path -Parent $MyInvocation.MyCommand.Path

# 只允许这四个群。名字 -> 群号在运行时向网关节析，不写死群号。
$allowedGroups = @(
  'TLB天狐の资源群②',
  'TLB天狐の哈基群①',
  'Cutrans/MediaForge测试群③',
  'OTTO_Sample_Manager用户群',
  '蓝振兴 S2【Bilibili同人only激励计划】'
)

function Read-BridgeConfig {
  param([string]$Dir)
  $raw = [System.IO.File]::ReadAllText((Join-Path $Dir 'config.json'))
  if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
  return ($raw | ConvertFrom-Json)
}

function Invoke-OneBot {
  param(
    [string]$BaseUrl,
    [string]$Token,
    [string]$Action,
    [hashtable]$Payload
  )
  $headers = @{}
  if ($Token) { $headers['authorization'] = "Bearer $Token" }
  $body = $Payload | ConvertTo-Json -Depth 6 -Compress
  return Invoke-RestMethod -Method Post -Uri "$BaseUrl/$Action" -Headers $headers `
    -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
}

$cfg = Read-BridgeConfig -Dir $BridgeDir
$baseUrl = ([string]$cfg.snowluma.httpUrl).TrimEnd('/')
$token = [string]$cfg.snowluma.accessToken

$dist = Join-Path $script:here 'dist'
$setup = Join-Path $dist ("otto-lite-{0}-setup.exe" -f $Version)
$zip = Join-Path $dist ("otto-lite-{0}-portable.zip" -f $Version)
$artifacts = @()
if (-not $PortableOnly) { $artifacts += $setup }
$artifacts += $zip

Write-Output "OTTO 发布到 QQ 群"
Write-Output "版本：$Version"
Write-Output "接口：$baseUrl"
Write-Output "模式：$(if ($Send) { '发送（-Send）' } else { '预演（默认，不会发）' })"
Write-Output ''

foreach ($f in $artifacts) {
  if (-not (Test-Path -LiteralPath $f)) { throw "缺少产物：$f（先跑 zig\package.ps1 -Version $Version）" }
  $sig = "$f.sig"
  if (-not (Test-Path -LiteralPath $sig)) { throw "缺少签名：$sig" }
  $len = (Get-Item -LiteralPath $f).Length
  Write-Output ("  产物 {0}  {1:N0} B" -f (Split-Path $f -Leaf), $len)
  # 验签：发出去的东西必须能验。
  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if ($node) {
    $pub = Join-Path $script:here 'keys\otto-lite.key.pub'
    & $node (Join-Path $script:here 'tools\verify-minisign.js') $pub $sig $f | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "验签失败：$f" }
    Write-Output '    验签 OK'
  } else {
    Write-Output '    （没有 node，跳过验签——仅预演允许）'
    if ($Send) { throw '发送前必须能验签（需要 node）' }
  }
}

Write-Output ''
Write-Output '解析群号（get_group_list）…'
$groups = Invoke-OneBot -BaseUrl $baseUrl -Token $token -Action 'get_group_list' -Payload @{}
$list = @($groups.data)
Write-Output ("  网关里共 {0} 个群" -f $list.Count)

$targets = @()
foreach ($name in $allowedGroups) {
  $hit = $list | Where-Object { $_.group_name -eq $name } | Select-Object -First 1
  if ($hit) {
    $targets += $hit
    Write-Output ("  [白名单] {0} -> {1}" -f $name, $hit.group_id)
  } else {
    Write-Output ("  [白名单] {0} -> 网关中找不到（跳过，不发）" -f $name)
  }
}
if ($targets.Count -eq 0) { throw '白名单里的群一个都找不到，停止。' }

Write-Output ''
if (-not $Send) {
  Write-Output '预演：以下动作不会执行。加 -Send 才会真的发。'
  foreach ($g in $targets) {
    foreach ($f in $artifacts) {
      Write-Output ("  upload_group_file 群={0}({1}) 文件={2}" -f $g.group_name, $g.group_id, (Split-Path $f -Leaf))
    }
  }
  exit 0
}

$failures = @()
foreach ($g in $targets) {
  foreach ($f in $artifacts) {
    Write-Output ("上传到 {0}（{1}）：{2}" -f $g.group_name, $g.group_id, (Split-Path $f -Leaf))
    $resp = Invoke-OneBot -BaseUrl $baseUrl -Token $token -Action 'upload_group_file' -Payload @{
      group_id = [int64]$g.group_id
      file = $f
      name = (Split-Path $f -Leaf)
    }
    Write-Output ("  返回：{0}" -f ($resp | ConvertTo-Json -Depth 4 -Compress))
    # 网关 HTTP 200 也可能带着 failed：必须看 status，不能只看"请求没报错"。
    if ($resp.status -ne 'ok') {
      $failures += ("{0} / {1}：{2}" -f $g.group_name, (Split-Path $f -Leaf), $resp.wording)
    }
  }
  if ($Notes) {
    Invoke-OneBot -BaseUrl $baseUrl -Token $token -Action 'send_group_msg' -Payload @{
      group_id = [int64]$g.group_id
      message = $Notes
    } | Out-Null
  }
}

if ($failures.Count -gt 0) {
  Write-Output ''
  Write-Output ("有 {0} 个文件没发出去：" -f $failures.Count)
  foreach ($x in $failures) { Write-Output ("  - {0}" -f $x) }
  exit 1
}
Write-Output '完成。'
