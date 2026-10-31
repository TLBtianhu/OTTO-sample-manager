//! app 侧单元测试的根：只拉适配层、取图层、选择模型、预览契约与拖拽快照，
//! 不 import nanoui（测试进程不起窗口、不写剪贴板）。搜索框与键盘的接线在
//! `search_ui.zig`（要窗口），由 `--nanoui-script` 的无头脚本覆盖；这里测它
//! 下面的纯函数。
//!
//!   * `live.zig` / `live_adapt.zig` —— `Live` 的驱动与 ports 事件 → core.Change 的
//!                         适配（合成事件，不碰磁盘）；
//!   * `thumbs_test.zig`—— 缓存键与载荷头的纯函数（线程与真实 Shell 由 `--demo-thumbs` 覆盖）；
//!   * `thumbs_icon.zig` / `thumbs_keys.zig` / `audio/coarse.zig` —— 行内小图的
//!     provider 入口、深拷贝与有界负缓存、WAV 图标粗采样（真实取图由快照/`--bench` 覆盖）；
//!   * `selection.zig`  —— 普通/Ctrl/Shift 点击、拖拽取集合、行号 → 路径；
//!   * `filter.zig`     —— 搜索的行→样本映射、↑↓ 越界不环绕、过滤后光标保持/回落；
//!   * `transport.zig`  —— 帧里的拖拽快照、取消、无窗口执行（真拖拽由人工验收）；
//!   * `options.zig`    —— 命令行解析（--version / --select / --preview / --copy-now / --demo-transport）；
//!   * `mode_test.zig` —— dev/portable/installed 判定、数据目录与默认库（纯函数 + 真标记文件）；
//!   * `version.zig`    —— 编译期注入的版本号与 `--version` 输出格式；
//!   * `preview.zig`    —— 注册表顺序、谢绝（none）后继续问、最终原因优先级、行数统计；
//!   * `preview_test.zig` —— 上面这些契约行为的测试（从 `preview.zig` 拆出来，守住单文件行数）；
//!   * `preview_snapshot.zig` —— 请求快照的深拷贝（跨线程所有权）；
//!   * `sample_facts.zig` —— 事实（名称/大小/时长/路径/扩展名）的格式化；
//!   * `audio/peaks.zig` —— 波形峰值的桶切分、多声道混合、空/单帧/满幅；
//!   * `audio/waveform.zig` —— 峰值到位图的尺寸、BGRA 顺序、静音细线与越界写；
//!   * `providers/`     —— 缩略图 provider 的纯逻辑（真实 Shell 取图由
//!                         `--preview` / `--demo-thumbs` 覆盖）与音频 provider 的
//!                         `supports`/文件缺失分支；WAV/FLAC/MP3/AIFF/Ogg 的整段
//!                         解码测试在 `audio/decode_test.zig` 与
//!                         `providers/native_audio_*_test.zig`（真实播放由
//!                         `--play-test` 覆盖）。
//!   * `providers/image*.zig` —— WIC 解码链与图片 provider（真 PNG/BMP/缩放/坏文件）；
//!                         WIC 是系统解码器，不需要窗口、Shell 或音频设备。
test {
    _ = @import("live.zig");
    // 监听判据：没有监听根 / 根里没有本库样本 / 样本在根下 / 显式 --watch。
    _ = @import("live_test.zig");
    // 溢出重扫：防抖 / Hold 的纯逻辑 + 真实文件系统上的增删改与注释保留。
    _ = @import("rescan_ui.zig");
    _ = @import("rescan_test.zig");
    _ = @import("thumbs_test.zig");
    // 取图队列的优先级规则（预取不能饿死可见请求）与空闲预取的窗口/节流。
    _ = @import("thumbs_queue.zig");
    _ = @import("thumbs_prefetch.zig");
    // 行就绪探针（`--bench-scroll` 的 ready/visited 账）。
    _ = @import("row_probe.zig");
    // 行内小图的 provider 入口、深拷贝快照与失败/谢绝键表（缓存键在 thumbs_test）。
    _ = @import("thumbs_icon.zig");
    _ = @import("thumbs_keys.zig");
    _ = @import("audio/coarse.zig");
    _ = @import("selection.zig");
    _ = @import("filter.zig");
    _ = @import("transport.zig");
    _ = @import("options.zig");
    _ = @import("options_test.zig");
    _ = @import("library_io.zig");
    // 导入流水线：id 规则、两条去重、Sample 装配、端到端（真临时目录）。
    _ = @import("import_cli.zig");
    _ = @import("import_cli_test.zig");
    // 导入的保存目标策略（纯字符串）与 UI 状态机文案（线程/对话框走人工验收）。
    _ = @import("import_target.zig");
    _ = @import("import_ui.zig");
    // 拖入：合成 DROPFILES 的 HGLOBAL 读写，以及目录/文件/缺失路径的分类。
    _ = @import("drop_files.zig");
    _ = @import("drop_ui.zig");
    _ = @import("mode.zig");
    // 形态判定与数据目录的测试；拆文件是为了守住 mode.zig 的行数。
    _ = @import("mode_test.zig");
    // 设置文件的 JSON 编解码 / 原子写 / 路径（真临时目录；坏文件必须回默认值）。
    _ = @import("settings_store.zig");
    _ = @import("version.zig");
    // 预览契约与注册表顺序；`providers/root.zig` 里的 comptime 检查也会在这里跑。
    _ = @import("preview.zig");
    _ = @import("preview_test.zig");
    _ = @import("preview_snapshot.zig");
    _ = @import("sample_facts.zig");
    // 行内时长文本（精确 / ≈估算 / 未知）与 app 侧的可信度 side table。
    _ = @import("duration_text.zig");
    _ = @import("duration_trust.zig");
    // side table 的测试（真临时文件 + 真 probe）：缓存命中/未命中/失败/文件变了。
    _ = @import("duration_trust_test.zig");
    // 列表行里的 Ogg 时长：`display` → `format` 给出 3.0s（不带 ≈）。
    _ = @import("duration_trust_ogg_test.zig");
    _ = @import("media_key.zig");
    _ = @import("audio/peaks.zig");
    _ = @import("audio/waveform.zig");
    // 解码层：zig-audio 的 WAV 全变体 / AIFF / 老编码，以及四态映射。
    _ = @import("audio/decode_test.zig");
    // 多声道下混的文件级回归：真 FLAC/WAV（ffmpeg 现场生成，缺失时 Skip）。
    _ = @import("audio/downmix_files_test.zig");
    _ = @import("providers/root.zig");
    // 真实注册表的 legacy 对照：.wav 里装 FLAC、截断 ADPCM、AIFF 改名 .xyz。
    _ = @import("providers/legacy_registry_test.zig");
    // 纯 Zig 音频 provider 的三侧测试：FLAC（含 ffmpeg 逐字节 SHA）、MP3
    // （真 viper.mp3 的时长/样本数 + 与 ffmpeg 的逐样本对比）、Ogg Vorbis
    // （真 ogg 的帧数/时长 + 与 ffmpeg 逐样本对比 + Opus 的谢绝语义）。拆文件
    // 是为了 provider 正文只留解码路径。
    _ = @import("providers/native_audio_test.zig");
    _ = @import("providers/native_audio_mp3_test.zig");
    _ = @import("providers/native_audio_ogg_test.zig");
    // WIC 解码器的真解码测试（素材不在时 Skip）；拆文件是为了守住 600 行。
    _ = @import("providers/image_wic_test.zig");
    // 更新检查的纯逻辑（M5）：feed 解析、版本判定、minisign 信封与真实签名向量。
    _ = @import("update_check.zig");
    // 更新检查的接线：表头文案、poll 落地、本地 feed 的三种判定与信封失败。
    _ = @import("update_ui.zig");
    _ = @import("update_ui_test.zig");
    // `--check-update` 的一行格式。
    _ = @import("update_cli.zig");
    // 下载 → 流式哈希 → 验签 → 落盘（真安装包 + 真 .sig；缺失时 Skip）。
    _ = @import("update_download.zig");
    _ = @import("update_download_test.zig");
    // 启动安装包的判断（>32 才算成功）；真的 ShellExecute 只由 --no-exec 之外的
    // 人工验收触发，测试进程绝不执行安装包。
    _ = @import("installer.zig");
}
