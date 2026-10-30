//! 缩略图隔离客户端用到的 Win32 声明与常量（等价于 windows.h / winbase.h / jobapi2.h）。
//!
//! 只有 ABI：结构体字段、`extern` 函数签名、标志位。没有逻辑、没有状态、没有 IO 循环。
//! 单独拆出来是因为 `thumb_host_win.zig`（进程生命周期）和 `thumb_host_ipc.zig`
//! （管道协议 + 看门狗）都要用同一份布局，而单文件 ≤600 行的规矩不允许把它们并回去。
//!
//! 和 `thumb_win.zig` 一样是手写声明：没有 @cImport、没有 C shim、没有外部依赖。
//! `ReadFile` / `WriteFile` / `GetStdHandle` / `GetLastError` 在 `thumb_host_pipe.zig` 里
//! （helper 也要用），这里不重复。

const pipe = @import("thumb_host_pipe.zig");

pub const Handle = pipe.Handle;
pub const BOOL = pipe.BOOL;
pub const DWORD = pipe.DWORD;

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?[*]u8,
    hStdInput: ?Handle,
    hStdOutput: ?Handle,
    hStdError: ?Handle,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: ?Handle,
    hThread: ?Handle,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

/// `JOBOBJECT_BASIC_LIMIT_INFORMATION`（x64 布局，C ABI 对齐）。
pub const JOB_BASIC_LIMIT = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: usize,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

/// `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`：只用到 BasicLimitInformation.LimitFlags
/// 里的 `KILL_ON_JOB_CLOSE`，其余字段留给系统。
pub const JOB_EXTENDED_LIMIT = extern struct {
    BasicLimitInformation: JOB_BASIC_LIMIT,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

pub extern "kernel32" fn CreateProcessW(
    application_name: ?[*:0]const u16,
    command_line: [*:0]u16,
    process_attributes: ?*SECURITY_ATTRIBUTES,
    thread_attributes: ?*SECURITY_ATTRIBUTES,
    inherit_handles: BOOL,
    creation_flags: DWORD,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const u16,
    startup_info: *STARTUPINFOW,
    process_info: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreatePipe(
    read: *?Handle,
    write: *?Handle,
    attributes: ?*SECURITY_ATTRIBUTES,
    size: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetHandleInformation(handle: Handle, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?Handle;
pub extern "kernel32" fn SetInformationJobObject(
    job: Handle,
    info_class: DWORD,
    info: *anyopaque,
    info_len: DWORD,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn AssignProcessToJobObject(job: Handle, process: Handle) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(process: Handle, exit_code: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(process: Handle, exit_code: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(
    attributes: ?*anyopaque,
    manual_reset: BOOL,
    initial_state: BOOL,
    name: ?[*:0]const u16,
) callconv(.winapi) ?Handle;
pub extern "kernel32" fn SetEvent(event: Handle) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(handle: Handle, milliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetModuleFileNameW(module: ?Handle, buffer: [*]u16, size: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: [*]u16, size: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) DWORD;

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

pub const CREATE_NO_WINDOW: DWORD = 0x0800_0000;
pub const STARTF_USESHOWWINDOW: DWORD = 0x0000_0001;
pub const STARTF_USESTDHANDLES: DWORD = 0x0000_0100;
pub const SW_HIDE: u16 = 0;

pub const HANDLE_FLAG_INHERIT: DWORD = 0x0000_0001;

pub const WAIT_TIMEOUT: DWORD = 258;

pub const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION: DWORD = 9;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x0000_2000;

pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFF_FFFF;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x0000_0010;
