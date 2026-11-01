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

## 3. 起别的程序：先看它是 GUI 还是控制台子系统

GUI 子系统（PE Subsystem = 2）的程序不分配控制台：双击、开始菜单、以及从没有控制台的
宿主里启动，都不会有黑框。控制台子系统（= 3）的程序会继承当前控制台——一般没问题；但在
**没有控制台的宿主**里起它，Windows 会给它新开一个控制台（Win11 上通常是一个 Windows
Terminal 窗口），那就是用户看到的黑框。这种程序必须用第 2 条的 `ProcessStartInfo` +
`CreateNoWindow = $true`。

`otto-thumb-host.exe` 是控制台子系统，但**由应用自己用 `CREATE_NO_WINDOW` 拉起**、走管道
通信，所以测试里也不会有窗口；不要跟着把它的子系统改掉（改成 windows 子系统反而可能影响
它自己的 stdio）。

`otto-lite.exe` **现在是 windows 子系统**（`zig/app/build.zig` 里 `exe.subsystem = .windows`）：
从 Explorer / 开始菜单双击启动时不再先分配控制台，**从无控制台的宿主启动它反而更安全**，
不会再有黑框。它不是控制台程序，但 stdio 不归子系统管：stdout/stderr 被 PowerShell / 第 2 条
的 `ProcessStartInfo` 重定向成管道或文件后照常继承并写入，所以 `& otto-lite.exe --preview …`
和 `RedirectStandardOutput` 都能拿到输出。直接连到 cmd 控制台的设备句柄本来对没附着控制台的
GUI 子系统进程无效，所以 CLI 入口（`commands.run` 之前、只在无窗口命令时）会
`AttachConsole(ATTACH_PARENT_PROCESS)` 并重开 `CONOUT$`——见 `app/src/console.zig`；
**GUI 路径绝不 attach**（双击的 GUI 进程不该挂到任何控制台上）。脚本读输出仍然一律重定向，
因为要的是捕获而不是显示；`CreateNoWindow` 只是让"控制台程序"和"GUI 程序"共用同一条启动路径。
它自己的窗口只由无头参数关掉（见第 5 条）。

## 4. 应用自己：`--nanoui-snapshot` 与探针一律隐藏

所有验收走 `--nanoui-snapshot` / `--settings-probe` / `--drop-probe` 这类入口，
它们建真 HWND 但 `hidden` + `no_activate`；脚本要断言 `visible=false`，并采样
`GetForegroundWindow()` 证明"我们的窗口从不是前台"。

## 5. PowerShell 脚本的参数拼接

**不要把函数形参命名成自动变量。** `$args`、`$input`、`$error`、`$matches`、`$this`、
`$LASTEXITCODE` 都是 PowerShell 的自动变量：形参叫 `$args` 会被当成"命令剩余参数"，
`@args` 展开成空数组，拼出来的命令行就少了关键参数。上一轮有代理因此把
`otto-lite.exe --nanoui-snapshot ...` 拼成了 `otto-lite.exe`，**误开了一个可见窗口，
在用户桌面上挂了约两分钟**。形参一律用有意义的实词（`$ExeArgs`、`$ChildArgs`）。

**拼接完的命令行要先回显、再执行。** 回显是唯一能在"窗口已经弹出来"之前发现参数为
空的机会：

```powershell
# 对：先回显（Write-Host 不进入函数返回流），再启动
Write-Host ('  $ "{0}" {1}' -f $ExePath, $arguments)
$psi.Arguments = $arguments
```

两个细节：

- 回显用 `Write-Host` / `[Console]::Out`，**不要用 `Write-Output`**——后者会进函数的
  成功流，`$r = Invoke-Xxx` 拿到的就变成"几行回显 + 结果"的数组，后面的断言全部失效
  （`provider-matrix.ps1` 的 `Invoke-LeakCheck` 踩过一次）；
- 需要加引号的路径自己加（`'"{0}"' -f $Path`）：`ProcessStartInfo.Arguments` 是原始
  命令行字符串，不会替你补引号。

**GUI（或任何会建窗口的）程序必须显式带 `--nanoui-*` 或 headless 参数，绝不能无参数
启动。** 无参数启动 = 打开主窗口 = 抢焦点。`otto-lite.exe` 的窗口只由无头参数关掉：

| 用途 | 参数 |
| --- | --- |
| 建真 HWND 但隐藏、不激活 | `--nanoui-snapshot <png>` |
| 隐藏窗口的设置探针 | `--settings-probe` / `--drop-probe` |
| 不建窗口的自检 | `--preview` / `--play-test` / `--demo-*` / `--bench-*` |

脚本里每一处启动 `otto-lite.exe` 的地方都要能指着一个具体的无头参数。另外，
`otto-lite.exe` 是 **windows 子系统**：双击启动不会弹控制台（0.22.0 起的行为）。
脚本读它的输出时仍然走第 2 条的 `ProcessStartInfo` + 重定向（`provider-matrix.ps1` 的
`Invoke-HeadlessExe`、`health.ps1` 的 `Invoke-Exe` 都是这么写的）——**抓输出靠的是重定向，
不是子系统**，别把 `CreateNoWindow` 当成"因为它还是控制台程序"才需要的。

## 6. 一条自查

交付前问自己：**"如果用户就坐在电脑前看，他会看到几个窗口闪过去？"**

答案应该是零。不是"应该很快"，是零。

## 7. 函数名不要和外部命令同名

PowerShell 的命令名**大小写不敏感**，所以

```powershell
function Gh { param([string[]]$ghArgs) & gh @ghArgs }   # ← 函数里的 gh 调用了自己
```

会 `CallDepthOverflow`，而且是**静默失败**（输出被 `2>$null` 吞掉时只看到"没有数据"）。

我踩过两次同类：`$args`（自动变量）与 `Gh`（遮蔽 `gh` 命令）。**规则：函数名一律 `Verb-Noun` 形式**
（`Invoke-GhApi`），形参一律不用自动变量名。