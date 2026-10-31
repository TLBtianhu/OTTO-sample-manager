# 验收脚本的约定

这些脚本跑在别人的桌面上。**它们不许弹窗、不许抢焦点、不许闪控制台窗口**——
用户看到的是我们的工作过程，一闪而过的黑框会让他以为出了什么问题。

## 1. 调用脚本：在当前 shell 里跑，不要新建进程

```powershell
# 对：同一个 PowerShell 进程，没有新窗口
& 'C:\src\otto-zig-lite\zig\health.ps1' -Quick

# 错：从没有控制台的宿主里启动 powershell.exe，Windows 会给子进程新开一个
#     控制台窗口——那就是用户看到的"一堆 PowerShell 窗口"
powershell -NoProfile -ExecutionPolicy Bypass -File zig\health.ps1 -Quick
```

只有当脚本用 `exit` 结束、而调用方还需要继续跑时，才需要子进程（见第 2 条）。

## 2. 必须起子进程时：CreateNoWindow，并自己读走两个流

```powershell
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "x.ps1"'
$psi.UseShellExecute = $false      # 必须
$psi.CreateNoWindow = $true        # 必须：这一条决定了有没有黑框
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$p = [System.Diagnostics.Process]::Start($psi)
$out = $p.StandardOutput.ReadToEndAsync()
$err = $p.StandardError.ReadToEndAsync()
$p.WaitForExit()
```

- `Start-Process -WindowStyle Hidden` **不如** `CreateNoWindow` 可靠：前者是给窗口
  的提示，后者是进程创建标志；
- 两个流都要读：只读一个，另一个写满管道会把子进程卡住。

## 3. 起 GUI 程序：本来就没有控制台，不用处理

`otto-lite.exe` 是 GUI 子系统；`otto-thumb-host.exe` 是控制台子系统，但**由应用
自己用 `CREATE_NO_WINDOW` 拉起**，所以测试里也不会有窗口。只有你**直接**在脚本里
调用控制台程序（`ffmpeg.exe`、`zig.exe`、`git.exe`）时才需要注意——它们会继承当前
控制台，一般没问题；但如果你在无控制台的环境里起它们，同样要给
`CreateNoWindow`。

## 4. 应用自己：`--nanoui-snapshot` 与探针一律隐藏

所有验收走 `--nanoui-snapshot` / `--settings-probe` / `--drop-probe` 这类入口，
它们建真 HWND 但 `hidden` + `no_activate`；脚本要断言 `visible=false`，并采样
`GetForegroundWindow()` 证明"我们的窗口从不是前台"。

## 5. 一条自查

交付前问自己：**"如果用户就坐在电脑前看，他会看到几个窗口闪过去？"**

答案应该是零。不是"应该很快"，是零。
