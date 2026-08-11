param(
  [Parameter(Mandatory = $true)]
  [string]$MelodynePath,
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
if (-not $OutputPath) {
  $OutputPath = Join-Path $PSScriptRoot "..\logs\baseline-$((Get-Date).ToString('yyyyMMdd-HHmmss')).log"
}
$output = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class ProcessIntegrity {
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int tokenClass, IntPtr info, int length, out int returned);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern IntPtr GetSidSubAuthority(IntPtr sid, uint index);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public static string Get(System.Diagnostics.Process process) {
        IntPtr token;
        if (!OpenProcessToken(process.Handle, 0x0008, out token))
            return "OpenProcessToken failed: " + new Win32Exception().Message;
        try {
            int needed;
            GetTokenInformation(token, 25, IntPtr.Zero, 0, out needed);
            IntPtr buffer = Marshal.AllocHGlobal(needed);
            try {
                if (!GetTokenInformation(token, 25, buffer, needed, out needed))
                    return "GetTokenInformation failed: " + new Win32Exception().Message;
                IntPtr sid = Marshal.ReadIntPtr(buffer);
                IntPtr countPtr = GetSidSubAuthorityCount(sid);
                byte count = Marshal.ReadByte(countPtr);
                uint rid = (uint)Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
                if (rid >= 0x4000) return "System (0x" + rid.ToString("X") + ")";
                if (rid >= 0x3000) return "High (0x" + rid.ToString("X") + ")";
                if (rid >= 0x2000) return "Medium (0x" + rid.ToString("X") + ")";
                return "Low (0x" + rid.ToString("X") + ")";
            } finally { Marshal.FreeHGlobal(buffer); }
        } finally { CloseHandle(token); }
    }
}
'@

$lines = [Collections.Generic.List[string]]::new()
function Add-Line([string]$Text = '') { $lines.Add($Text) }

$file = Get-Item -LiteralPath $MelodynePath
Add-Line "Collected: $((Get-Date).ToString('o'))"
Add-Line "OS: $([Environment]::OSVersion.VersionString)"
Add-Line "64-bit OS: $([Environment]::Is64BitOperatingSystem)"
Add-Line "Melodyne: $($file.FullName)"
Add-Line "Melodyne file version: $($file.VersionInfo.FileVersion)"
Add-Line "Melodyne product version: $($file.VersionInfo.ProductVersion)"
Add-Line "Melodyne size: $($file.Length)"
Add-Line ''
Add-Line 'Running process integrity:'
foreach ($name in @('Melodyne', 'sample-manager', 'electron')) {
  $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
  if ($processes.Count -eq 0) {
    Add-Line "  ${name}: not running"
    continue
  }
  foreach ($process in $processes) {
    try {
      $integrity = [ProcessIntegrity]::Get($process)
      Add-Line "  $($process.ProcessName) pid=$($process.Id) integrity=$integrity path=$($process.Path)"
    } catch {
      Add-Line "  $($process.ProcessName) pid=$($process.Id) integrity=<error: $($_.Exception.Message)>"
    }
  }
}

Add-Line ''
Add-Line 'Relevant static imports:'
$objdump = Get-Command objdump.exe -ErrorAction SilentlyContinue
if ($objdump) {
  $imports = & $objdump.Source -p $file.FullName |
    Select-String -Pattern 'RegisterDragDrop|RevokeDragDrop|DoDragDrop|OleInitialize|DragAcceptFiles|DragQueryFileA|DragQueryFileW|RegisterClipboardFormatA|RegisterClipboardFormatW|GetClipboardFormatNameA|GetClipboardFormatNameW'
  foreach ($line in $imports) { Add-Line "  $($line.Line.Trim())" }
} else {
  Add-Line '  objdump.exe not found'
}

[IO.File]::WriteAllLines($output, $lines, [Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $output | Select-Object FullName, Length, LastWriteTime
