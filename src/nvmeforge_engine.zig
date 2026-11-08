const std = @import("std");

// NVMeForge - clonador de discos NVMe para Windows.
// Copyright (C) 2026 Carlos Javier y los autores de NVMeForge.
// SPDX-License-Identifier: GPL-3.0-or-later
// Este programa es software libre: puede redistribuirlo y/o modificarlo bajo los terminos de la
// Licencia Publica General GNU version 3 o posterior (archivo LICENSE). Se distribuye SIN GARANTIA.

const VERSION = "3.1.1";

const UI_HTML = @embedFile("ui.html");
const ICO_FILE = @embedFile("assets/nvmeforge.ico");

const diskcheck = @import("diskcheck.zig");
const HANDLE = *anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_NO_BUFFERING: u32 = 0x20000000;
const FILE_FLAG_SEQUENTIAL_SCAN: u32 = 0x08000000;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x00000080;

const MEM_COMMIT: u32 = 0x00001000;
const MEM_RESERVE: u32 = 0x00002000;
const MEM_RELEASE: u32 = 0x00008000;
const PAGE_READWRITE: u32 = 0x04;

const FSCTL_LOCK_VOLUME: u32 = 0x00090018;
const FSCTL_UNLOCK_VOLUME: u32 = 0x0009001C;
const FSCTL_DISMOUNT_VOLUME: u32 = 0x00090020;
const FSCTL_GET_VOLUME_BITMAP: u32 = 0x0009006F;
const FSCTL_ALLOW_EXTENDED_DASD_IO: u32 = 0x00090083;
// CTL_CODE(FILE_DEVICE_FILE_SYSTEM, 25, METHOD_BUFFERED, FILE_ANY_ACCESS) -> NTFS_VOLUME_DATA_BUFFER (BytesPerCluster @ 44)
const FSCTL_GET_NTFS_VOLUME_DATA: u32 = 0x00090064;
const IOCTL_DISK_GET_LENGTH_INFO: u32 = 0x0007405C;
const IOCTL_DISK_GET_DRIVE_GEOMETRY_EX: u32 = 0x000700A0;
const IOCTL_DISK_GET_DRIVE_LAYOUT_EX: u32 = 0x00070050;

const ERROR_MORE_DATA: u32 = 234;
const CREATE_NO_WINDOW: u32 = 0x08000000;
const STARTF_USESHOWWINDOW: u32 = 0x00000001;
const STARTF_USESTDHANDLES: u32 = 0x00000100;
const CREATE_ALWAYS: u32 = 2;
// CTL_CODE(IOCTL_VOLUME_BASE=0x56, 0, METHOD_BUFFERED, FILE_ANY_ACCESS) -> works with dwDesiredAccess = 0 (no Admin)
const IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS: u32 = 0x00560000;
// NVF-E038 (v2.7): the target disk is the one the user picked and confirmed in the UI (or --target=N on
// the command line). It is no longer fixed to Disk 1. NO_DISK = nothing chosen; the clone refuses to start.
const NO_DISK: u32 = 0xFFFF_FFFF;
const MAX_DISKS: u32 = 16;
var g_target_disk = std.atomic.Value(u32).init(NO_DISK);
// Drive letters reserved by the clone flow: S = EFI destino, W = Windows destino, R = Recovery destino,
// Z = EFI origen (disco de C:), Y = WinRE origen (disco de C:, NVF-E020)
const RESERVED_LETTERS = [_]u8{ 'S', 'W', 'R', 'Z', 'Y' };
// v2.9 (F4): roles of the letters the clone uses. They are the preferred S, W, R, Z, Y when free; otherwise
// other free letters are chosen at the start of every clone (chooseCloneLetters) and used everywhere through
// the "@S @W @R @Z @Y" placeholders of substLetters. No clone fails any more because a letter is taken.
const LETTER_EFI = 0; // @S  EFI of the target
const LETTER_WIN = 1; // @W  Windows of the target
const LETTER_REC = 2; // @R  WinRE of the target
const LETTER_SRC_EFI = 3; // @Z  EFI of the source (mounted for a moment)
const LETTER_SRC_RE = 4; // @Y  WinRE of the source (mounted for a moment)
var g_letters: [5]u8 = RESERVED_LETTERS;
const FALLBACK_LETTERS = "TUVXQPONMLKJIHGFED";
const LOG_DIR_REL = "NVMeForge\\logs";

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: i32 = 1,
};

const SYSTEMTIME = extern struct {
    wYear: u16 = 0,
    wMonth: u16 = 0,
    wDayOfWeek: u16 = 0,
    wDay: u16 = 0,
    wHour: u16 = 0,
    wMinute: u16 = 0,
    wSecond: u16 = 0,
    wMilliseconds: u16 = 0,
};

const ES_CONTINUOUS: u32 = 0x80000000;
const ES_SYSTEM_REQUIRED: u32 = 0x00000001;
const ES_DISPLAY_REQUIRED: u32 = 0x00000002;
const ES_AWAYMODE_REQUIRED: u32 = 0x00000040;

const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?*anyopaque = null,
    hStdOutput: ?*anyopaque = null,
    hStdError: ?*anyopaque = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: ?*anyopaque = null,
    hThread: ?*anyopaque = null,
    dwProcessId: u32 = 0,
    dwThreadId: u32 = 0,
};

const SYSTEM_POWER_STATUS = extern struct {
    ACLineStatus: u8 = 1,
    BatteryFlag: u8 = 0,
    BatteryLifePercent: u8 = 100,
    SystemStatusFlag: u8 = 0,
    BatteryLifeTime: u32 = 0,
    BatteryFullLifeTime: u32 = 0,
};

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: i32,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) i32;

extern "kernel32" fn WaitForSingleObject(hHandle: *anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(hProcess: *anyopaque, lpExitCode: *u32) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn GetSystemPowerStatus(lpSystemPowerStatus: *SYSTEM_POWER_STATUS) callconv(.winapi) i32;
extern "kernel32" fn SetThreadExecutionState(esFlags: u32) callconv(.winapi) u32;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn GetTempPathW(nBufferLength: u32, lpBuffer: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn GetDiskFreeSpaceExW(
    lpDirectoryName: [*:0]const u16,
    lpFreeBytesAvailableToCaller: ?*u64,
    lpTotalNumberOfBytes: ?*u64,
    lpTotalNumberOfFreeBytes: ?*u64,
) callconv(.winapi) i32;

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) HANDLE;

extern "kernel32" fn DeviceIoControl(
    hDevice: HANDLE,
    dwIoControlCode: u32,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: u32,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: u32,
    lpBytesReturned: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

extern "kernel32" fn SetFilePointerEx(
    hFile: HANDLE,
    liDistanceToMove: i64,
    lpNewFilePointer: ?*i64,
    dwMoveMethod: u32,
) callconv(.winapi) i32;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: *anyopaque,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: *const anyopaque,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;

extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn VirtualAlloc(
    lpAddress: ?*anyopaque,
    dwSize: usize,
    flAllocationType: u32,
    flProtect: u32,
) callconv(.winapi) ?[*]u8;
extern "kernel32" fn VirtualFree(lpAddress: *anyopaque, dwSize: usize, dwFreeType: u32) callconv(.winapi) i32;
extern "kernel32" fn SetFileAttributesW(lpFileName: [*:0]const u16, dwFileAttributes: u32) callconv(.winapi) i32;
extern "kernel32" fn DeleteFileW(lpFileName: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
extern "kernel32" fn GetFileSizeEx(hFile: *anyopaque, lpFileSize: *i64) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) callconv(.winapi) i32;
extern "kernel32" fn GetProcessTimes(hProcess: *anyopaque, lpCreationTime: *u64, lpExitTime: *u64, lpKernelTime: *u64, lpUserTime: *u64) callconv(.winapi) i32;
extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.winapi) void;
extern "kernel32" fn QueryDosDeviceW(lpDeviceName: [*:0]const u16, lpTargetPath: [*]u16, ucchMax: u32) callconv(.winapi) u32;
extern "kernel32" fn DeleteVolumeMountPointW(lpszVolumeMountPoint: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn DefineDosDeviceW(dwFlags: u32, lpDeviceName: [*:0]const u16, lpTargetPath: ?[*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn GetDriveTypeW(lpRootPathName: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetVolumeNameForVolumeMountPointW(lpszVolumeMountPoint: [*:0]const u16, lpszVolumeName: [*]u16, cchBufferLength: u32) callconv(.winapi) i32;
extern "kernel32" fn SetVolumeMountPointW(lpszVolumeMountPoint: [*:0]const u16, lpszVolumeName: [*:0]const u16) callconv(.winapi) i32;

extern "shell32" fn IsUserAnAdmin() callconv(.winapi) i32;
extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    lpOperation: [*:0]const u16,
    lpFile: [*:0]const u16,
    lpParameters: ?[*:0]const u16,
    lpDirectory: ?[*:0]const u16,
    nShowCmd: i32,
) callconv(.winapi) isize;

var g_progress_mutex: std.Thread.Mutex = .{};
var g_progress_buf: [2048]u8 = undefined;
var g_progress_len: usize = 0;
var g_clone_running = std.atomic.Value(bool).init(false);
var g_bench_running = std.atomic.Value(bool).init(false);
// NVF-E045: closes the double-POST race in /api/start-clone: while true, the per-run flags
// (g_target_disk, g_expect_*, g_slowack_set) belong to the request being started. The worker
// lowers it with a defer when its thread ends (after capturing the flags at entry).
var g_starting = std.atomic.Value(bool).init(false);

// NVF-E033: the backend used to stay alive (PID in memory) after the window was closed.
// Every UI request refreshes g_last_ui_ms; the page reports its own closing via POST /api/ui-closed.
var g_last_ui_ms = std.atomic.Value(i64).init(0);
var g_ui_closed_ms = std.atomic.Value(i64).init(0);
const UI_CLOSED_EXIT_MS: i64 = 2_000; // window closed and no page came back (a reload comes back in < 1 s)
const UI_IDLE_EXIT_MS: i64 = 120_000; // safety net: no page at all for 2 min (hidden windows still poll once per minute)

/// Exits the process once no NVMeForge window is left — never while a clone or a benchmark is running.
fn idleExitWatchdog() void {
    while (true) {
        Sleep(2000);
        if (shouldExitForIdle(std.time.milliTimestamp(), g_last_ui_ms.load(.seq_cst), g_ui_closed_ms.load(.seq_cst), g_clone_running.load(.seq_cst), g_bench_running.load(.seq_cst))) {
            std.process.exit(0);
        }
    }
}

fn shouldExitForIdle(now: i64, last_ui: i64, closed_at: i64, clone_running: bool, bench_running: bool) bool {
    if (clone_running or bench_running) return false;
    const closed_and_quiet = closed_at != 0 and last_ui <= closed_at and now - closed_at > UI_CLOSED_EXIT_MS;
    return closed_and_quiet or now - last_ui > UI_IDLE_EXIT_MS;
}
var g_shutdown_requested = std.atomic.Value(bool).init(false);

fn initDefaultProgress() void {
    const def = "{\"stage\":\"Listo\",\"detail\":\"Conecta el disco destino al adaptador USB y revisa los datos antes de clonar.\",\"percent\":0.0,\"mb_s\":0.0,\"done\":false}";
    g_progress_mutex.lock();
    defer g_progress_mutex.unlock();
    @memcpy(g_progress_buf[0..def.len], def);
    g_progress_len = def.len;
}

/// JSON-escapes `s` into `out` (NVF-E012: raw "\EFI" in progress JSON broke JSON.parse in the UI).
/// Control chars become spaces; output is truncated safely if `out` is too small.
fn jsonEscapeInto(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |ch| {
        if (n + 2 >= out.len) break;
        switch (ch) {
            '"', '\\' => {
                out[n] = '\\';
                out[n + 1] = ch;
                n += 2;
            },
            0...0x1F => {
                out[n] = ' ';
                n += 1;
            },
            else => {
                out[n] = ch;
                n += 1;
            },
        }
    }
    return out[0..n];
}

fn ensureLogDir() void {
    var dir_buf: [512]u8 = undefined;
    const dir = getTempFilePath(&dir_buf, LOG_DIR_REL) orelse return;
    std.fs.cwd().makePath(dir) catch {};
}

fn getLogPath(buf: []u8, file_name: []const u8) ?[]const u8 {
    var rel_buf: [128]u8 = undefined;
    const rel = std.fmt.bufPrint(&rel_buf, LOG_DIR_REL ++ "\\{s}", .{file_name}) catch return null;
    return getTempFilePath(buf, rel);
}

/// Appends a timestamped line to %TEMP%\NVMeForge\logs\clone_run.log so every reported
/// error can be traced back to the exact stage/command that produced it.
var g_runlog_mutex: std.Thread.Mutex = .{};

fn appendRunLog(line: []const u8) void {
    // Review v2.9 #6: called from the read-ahead thread too; one line at a time.
    g_runlog_mutex.lock();
    defer g_runlog_mutex.unlock();
    // Unit tests must never write into the real %TEMP%\NVMeForge\logs\clone_run.log: their
    // intentional VERIFY_BAD_SEGMENT / diferencias lines were mixed with real runs (v2.2).
    if (@import("builtin").is_test) return;
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, "clone_run.log") orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};
    var st = SYSTEMTIME{};
    GetLocalTime(&st);
    var ts_buf: [40]u8 = undefined;
    const ts = std.fmt.bufPrint(&ts_buf, "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}] ", .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds }) catch "";
    f.writeAll(ts) catch {};
    f.writeAll(line) catch {};
    f.writeAll("\r\n") catch {};
}

fn updateProgress(stage: []const u8, detail: []const u8, percent: f64, mb_s: f64, done: bool) void {
    g_progress_mutex.lock();
    defer g_progress_mutex.unlock();
    var stage_esc_buf: [512]u8 = undefined;
    var detail_esc_buf: [1024]u8 = undefined;
    const stage_esc = jsonEscapeInto(&stage_esc_buf, stage);
    const detail_esc = jsonEscapeInto(&detail_esc_buf, detail);
    const ct = g_copy_total.load(.seq_cst);
    const cd = g_copy_done.load(.seq_cst);
    const vd = g_verify_done.load(.seq_cst);
    const eta = if (done) null else estimateEtaSec(ct, cd, vd, std.time.milliTimestamp() - g_work_start_ms.load(.seq_cst), g_tail_done.load(.seq_cst));
    var eta_buf: [24]u8 = undefined;
    const eta_s = if (eta) |e| (std.fmt.bufPrint(&eta_buf, "{d}", .{e}) catch "null") else "null";
    const slice = std.fmt.bufPrint(
        &g_progress_buf,
        "{{\"stage\":\"{s}\",\"detail\":\"{s}\",\"percent\":{d:.1},\"mb_s\":{d:.1},\"done\":{s},\"copy_total\":{d},\"copy_done\":{d},\"verify_done\":{d},\"eta_sec\":{s}}}",
        .{ stage_esc, detail_esc, percent, mb_s, if (done) "true" else "false", ct, cd, vd, eta_s },
    ) catch return;
    g_progress_len = slice.len;

    var log_line_buf: [1700]u8 = undefined;
    if (std.fmt.bufPrint(&log_line_buf, "{d:>5.1}% | {s} | {s}", .{ percent, stage, detail })) |log_line| {
        appendRunLog(log_line);
    } else |_| {}

    // Also persist to %TEMP%\NVMeForge\progress.json
    var tmp_buf: [512]u8 = undefined;
    if (getTempFilePath(&tmp_buf, "NVMeForge\\progress.json")) |path| {
        if (std.fs.cwd().createFile(path, .{ .truncate = true })) |f| {
            defer f.close();
            f.writeAll(slice) catch {};
        } else |_| {}
    }
}

fn getProgressJson(out_buf: []u8) []const u8 {
    g_progress_mutex.lock();
    defer g_progress_mutex.unlock();
    if (g_progress_len == 0 or g_progress_len > out_buf.len) {
        return "{\"stage\":\"Listo\",\"detail\":\"\",\"percent\":0.0,\"mb_s\":0.0,\"done\":false}";
    }
    @memcpy(out_buf[0..g_progress_len], g_progress_buf[0..g_progress_len]);
    return out_buf[0..g_progress_len];
}

fn getTempFilePath(buf: []u8, filename: []const u8) ?[]const u8 {
    var wbuf: [300]u16 = undefined;
    const wlen = GetTempPathW(280, &wbuf);
    if (wlen == 0 or wlen > 280) return null;
    var u8_dir: [380]u8 = undefined;
    const dlen = std.unicode.utf16LeToUtf8(&u8_dir, wbuf[0..wlen]) catch return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ u8_dir[0..dlen], filename }) catch null;
}

fn writeOut(msg: []const u8) void {
    const so = std.fs.File.stdout();
    so.writeAll(msg) catch {};
}

fn isAdmin() bool {
    return IsUserAnAdmin() != 0;
}

/// v2.5: real power state. pct = null when Windows does not know it (no battery, or BatteryLifePercent 255);
/// ac = null when the AC line status is unknown. Nothing is invented (v2.4 and earlier returned 95 % / AC).
const PowerInfo = struct { pct: ?u8, ac: ?bool, chg: bool, has_battery: bool };

fn getBatteryInfo() PowerInfo {
    var sps = SYSTEM_POWER_STATUS{};
    if (GetSystemPowerStatus(&sps) == 0) return .{ .pct = null, .ac = null, .chg = false, .has_battery = false };
    const has_battery = (sps.BatteryFlag & 128) == 0 and sps.BatteryFlag != 255;
    const pct: ?u8 = if (has_battery and sps.BatteryLifePercent <= 100) sps.BatteryLifePercent else null;
    const ac: ?bool = switch (sps.ACLineStatus) {
        0 => false,
        1 => true,
        else => if (!has_battery) true else null, // a machine without battery runs on mains
    };
    return .{ .pct = pct, .ac = ac, .chg = (sps.BatteryFlag & 8) != 0, .has_battery = has_battery };
}

fn jsonOptU8(v: ?u8, buf: []u8) []const u8 {
    return if (v) |x| (std.fmt.bufPrint(buf, "{d}", .{x}) catch "null") else "null";
}
fn jsonOptBool(v: ?bool) []const u8 {
    return if (v) |x| (if (x) "true" else "false") else "null";
}

/// NVF-E036: refuse to start a ~25 min clone that is likely to lose power. Unknown values never block.
fn powerAllowsClone(p: PowerInfo) bool {
    if (p.ac orelse true) return true;
    const pct = p.pct orelse return true;
    return pct >= 60;
}

/// NVF-E036: the VSS diff area lives on C:; with almost no free space the snapshot is deleted mid-copy.
const MIN_C_FREE_BYTES: u64 = 10 * 1000 * 1000 * 1000;

/// NVF-E001 (v2.7): the target no longer has to be 1.5 TB. It must hold exactly what the clone creates:
/// EFI (260 MiB, or the source EFI if bigger) + MSR 16 MiB + C: (+32 MiB) + WinRE (1000 MiB, or the source
/// one if bigger) + 64 MiB of GPT/alignment slack. A smaller disk is refused before anything is touched.
const MIB: u64 = 1024 * 1024;
const MIN_EFI_MB: u64 = 260;
const MIN_RECOVERY_MB: u64 = 1000;
const MAX_SYS_PART_MB: u64 = 4096; // sanity cap for a copied EFI/WinRE size
const GPT_SLACK_MB: u64 = 64;

const ClonePlan = struct {
    efi_mb: u64,
    windows_mb: u64,
    recovery_mb: u64,
    /// v2.8: every other partition of the source (OEM/HP, old recovery, data without letter), copied 1:1.
    extras_mb: u64 = 0,

    fn requiredBytes(self: ClonePlan) u64 {
        return (self.efi_mb + 16 + self.windows_mb + self.recovery_mb + self.extras_mb + GPT_SLACK_MB) * MIB;
    }
};

/// Room reserved per extra partition on top of its size (diskpart 1 MiB alignment + the 50 MiB shrink tolerance).
const EXTRA_MARGIN_MB: u64 = 64;

fn ceilMb(bytes: u64) u64 {
    return (bytes + MIB - 1) / MIB;
}

/// Pure: sizes of the partitions the clone creates on the target, from the source sizes (0 = none/unknown).
fn planClone(c_part_bytes: u64, src_efi_bytes: u64, src_recovery_bytes: u64) ClonePlan {
    return .{
        .efi_mb = std.math.clamp(ceilMb(src_efi_bytes), MIN_EFI_MB, MAX_SYS_PART_MB),
        .windows_mb = c_part_bytes / MIB + 32,
        .recovery_mb = std.math.clamp(ceilMb(src_recovery_bytes), MIN_RECOVERY_MB, MAX_SYS_PART_MB),
    };
}

/// Plan for THIS machine (C: size plus the EFI and WinRE partitions of the disk that holds C:). Read-only,
/// works without Admin. null when C: cannot be measured (the clone then aborts with NVF-E022).
fn currentClonePlan() ?ClonePlan {
    const c_part = getVolumePartitionBytes('C');
    if (c_part == 0) return null;
    const c_disk = getVolumeDiskNumber('C');
    const efi = if (c_disk) |d| findGptPartition(d, &GUID_EFI, MIB) else null;
    const re = if (c_disk) |d| findGptPartition(d, &GUID_WINRE, 300 * MIB) else null;
    var plan = planClone(c_part, if (efi) |p| p.bytes else 0, if (re) |p| p.bytes else 0);
    if (c_disk) |d| {
        var ex: [MAX_EXTRAS]ExtraPart = undefined;
        const n = sourceExtras(d, if (re) |p| p.number else null, &ex);
        plan.extras_mb = extrasMb(ex[0..n]);
    }
    return plan;
}

/// Pure (F4): letters for the 5 roles. Each preferred letter is kept when it is free; otherwise the next free
/// letter of FALLBACK_LETTERS. A, B and C are never used. null if there are not 5 free letters.
fn chooseCloneLetters(in_use_mask: u32, preferred: [5]u8) ?[5]u8 {
    var taken: u32 = in_use_mask | 0b111; // A, B, C
    var out: [5]u8 = undefined;
    for (preferred, 0..) |pl, k| {
        const bit = @as(u32, 1) << @intCast(pl - 'A');
        if (taken & bit == 0) {
            out[k] = pl;
            taken |= bit;
        } else out[k] = 0;
    }
    for (&out) |*o| {
        if (o.* != 0) continue;
        for (FALLBACK_LETTERS) |fl| {
            const bit = @as(u32, 1) << @intCast(fl - 'A');
            if (taken & bit == 0) {
                o.* = fl;
                taken |= bit;
                break;
            }
        } else return null;
    }
    return out;
}

/// Pure (F4): copies `template` replacing "@S", "@W", "@R", "@Z", "@Y" with the letters of the 5 roles.
fn substLetters(out: []u8, template: []const u8, letters: [5]u8) ?[]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < template.len) : (i += 1) {
        if (n >= out.len) return null;
        if (template[i] == '@' and i + 1 < template.len) {
            const role: ?usize = switch (template[i + 1]) {
                'S' => LETTER_EFI,
                'W' => LETTER_WIN,
                'R' => LETTER_REC,
                'Z' => LETTER_SRC_EFI,
                'Y' => LETTER_SRC_RE,
                else => null,
            };
            if (role) |r| {
                out[n] = letters[r];
                n += 1;
                i += 1;
                continue;
            }
        }
        out[n] = template[i];
        n += 1;
    }
    return out[0..n];
}

/// substLetters with the letters chosen for this clone. On overflow returns "" (the command then fails
/// instead of running with a wrong letter).
fn L(out: anytype, comptime template: []const u8) []const u8 {
    // Review v2.9 #2: substitution never makes a string longer, so a buffer at least as long as the template
    // can never overflow; checked at compile time (an empty path would hit a std assert at run time).
    if (@typeInfo(@TypeOf(out.*)).array.len < template.len) @compileError("buffer too small for " ++ template);
    return substLetters(out, template, g_letters).?;
}

fn letterOf(role: usize) u8 {
    return g_letters[role];
}

/// Review v2.9 #1: before every step that uses a letter, prove it still belongs to the expected disk (a USB
/// stick plugged in during the 20-min copy could have taken it, and a failed "assign" is not fatal in diskpart).
fn roleOnDisk(role: usize, disk: u32, step: []const u8) bool {
    const ok = isLetterOnDisk(g_letters[role], disk);
    if (!ok) {
        var l: [160]u8 = undefined;
        if (std.fmt.bufPrint(&l, "LETRA {c}: ya no esta en el disco {d}; se omite {s}", .{ g_letters[role], disk, step })) |x| appendRunLog(x) else |_| {}
    }
    return ok;
}

fn targetDisk() u32 {
    return g_target_disk.load(.seq_cst);
}

/// NVF-E038 (pure): a disk number can be the target only if it is a real disk index and is not the disk
/// that holds the running Windows. An unknown source disk never allows a target.
fn validTargetChoice(disk: u32, c_disk: ?u32) bool {
    const src = c_disk orelse return false;
    return disk != NO_DISK and disk < MAX_DISKS and disk != src;
}

/// NVF-E038 (pure): the target to pre-select in the UI. Only when exactly ONE disk other than the source is
/// connected; with several (e.g. many USB adapters) NVMeForge never guesses and the user must pick one.
fn soleCandidate(disks: []const u32, c_disk: ?u32) ?u32 {
    const src = c_disk orelse return null;
    var found: ?u32 = null;
    for (disks) |d| {
        if (d == src) continue;
        if (found != null) return null;
        found = d;
    }
    return found;
}

fn decGB(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1e9;
}

/// Pure: diskpart script that wipes `disk` and creates EFI (S:), MSR (implicit, NVF-E015) and Windows (W:).
/// NVF-E007: one "select disk", no "select volume" (it would abort the whole script on an empty disk).
fn buildInitScript(buf: []u8, disk: u32, plan: ClonePlan) ?[]const u8 {
    return std.fmt.bufPrint(buf, "select disk {d}\r\nonline disk noerr\r\nattributes disk clear readonly noerr\r\nclean\r\nconvert gpt\r\ncreate partition efi size={d}\r\nformat quick fs=fat32 label=\"SYSTEM\"\r\nassign letter={c}\r\ncreate partition primary size={d}\r\nformat quick fs=ntfs label=\"Windows\"\r\nassign letter={c}\r\nexit\r\n", .{ disk, plan.efi_mb, letterOf(LETTER_EFI), plan.windows_mb, letterOf(LETTER_WIN) }) catch null;
}

/// Pure: diskpart script that grows W: to the whole target and leaves at the end WinRE (R:) and, v2.8, one
/// empty partition per extra source partition, in the source order, with the same type and GPT attributes.
/// The extras get no letter ("remove all"); their content is copied sector by sector afterwards.
fn buildExpandScript(buf: []u8, plan: ClonePlan, extras: []const ExtraPart) ?[]const u8 {
    var w = std.io.fixedBufferStream(buf);
    const o = w.writer();
    const shrink = plan.recovery_mb + plan.extras_mb;
    o.print("select volume {c}\r\nextend\r\nshrink desired={d} minimum={d} noerr\r\n", .{ letterOf(LETTER_WIN), shrink, shrink - 50 }) catch return null;
    if (extras.len == 0) {
        o.writeAll("create partition primary id=de94bba4-06d1-4d40-a16a-bfd50179d6ac\r\n") catch return null;
    } else {
        o.print("create partition primary size={d} id=de94bba4-06d1-4d40-a16a-bfd50179d6ac\r\n", .{plan.recovery_mb}) catch return null;
    }
    o.print("format quick fs=ntfs label=\"Recovery\"\r\nassign letter={c}\r\ngpt attributes=0x8000000000000001\r\n", .{letterOf(LETTER_REC)}) catch return null;
    for (extras) |e| {
        var g: [36]u8 = undefined;
        // Review v2.8 #3/#6: no "remove all" here (diskpart volume focus may still be R:) and no GPT attributes
        // yet (a read-only bit would block the copy); both are applied per partition, by number, later.
        o.print("create partition primary size={d} id={s}\r\n", .{ ceilMb(e.entry.bytes), fmtGuid(&e.entry.type_guid, &g) }) catch return null;
    }
    o.writeAll("exit\r\n") catch return null;
    return w.getWritten();
}

// NVF-E035: identity of the target the user CONFIRMED in the UI (model + exact size). The clone aborts
// before touching anything if Disk 1 is not that disk any more (USB re-enumeration, another drive plugged in).
var g_expect_mutex: std.Thread.Mutex = .{};
var g_expect_set: bool = false;
var g_expect_bytes: u64 = 0;
var g_expect_model_buf: [96]u8 = undefined;
var g_expect_model_len: usize = 0;

// NVF-E045 (v3.1.1): NVF-E010 is confirmable. A PC without USB 3 whose adapter reads at ~60 MB/s
// can still clone after an explicit confirmation with the real estimated time. The ack is single-use
// (same pattern as g_expect_set): the second start-clone carries slow_ok=1 (or --slow-ok on the
// command line) and the worker consumes it when it reaches the slow-link check.
var g_slowack_mutex: std.Thread.Mutex = .{};
var g_slowack_set: bool = false;

fn takeSlowAck() bool {
    g_slowack_mutex.lock();
    defer g_slowack_mutex.unlock();
    const v = g_slowack_set;
    g_slowack_set = false;
    return v;
}

/// Pure: true when the measured link speed needs the slow-link confirmation (NVF-E010).
fn slowLinkNeedsConfirm(raw_mbs: f64) bool {
    return raw_mbs > 0.0 and raw_mbs < 60.0;
}

/// Pure: honest ETA for a slow link, in seconds: the bytes travel twice through that link (copy
/// write + full XxHash64 re-read, NVF-E026) plus the fixed final steps (same 210 s tail as
/// estimateEtaSec while the tail is not done). Null when there is no measured speed (NVF-E034:
/// without a measurement there is no estimate).
fn slowLinkEtaSec(need_bytes: u64, mbs: f64) ?u64 {
    if (need_bytes == 0 or mbs <= 0.0) return null;
    const secs = (@as(f64, @floatFromInt(need_bytes)) / (mbs * 1048576.0)) * 2.0 + 210.0;
    return @intFromFloat(@max(0.0, secs));
}

// Result of the last copy, for an honest final message.
var g_last_copied_bytes = std.atomic.Value(u64).init(0);

// v2.9 (F2): real progress of the whole clone. copy_total = bytes to copy (C: used + extras), each copied
// byte is later re-read once, so the byte work is 2 x copy_total. The ETA adds the fixed final steps.
var g_copy_total = std.atomic.Value(u64).init(0);
var g_copy_done = std.atomic.Value(u64).init(0);
var g_verify_done = std.atomic.Value(u64).init(0);
var g_work_start_ms = std.atomic.Value(i64).init(0);
var g_tail_done = std.atomic.Value(bool).init(false); // chkdsk + expand already done

/// Pure: seconds left for the whole clone (null until there is a measured rate).
fn estimateEtaSec(copy_total: u64, copy_done: u64, verify_done: u64, elapsed_ms: i64, tail_done: bool) ?u64 {
    const total = 2 * copy_total;
    const done = copy_done + verify_done;
    if (total == 0 or done == 0 or elapsed_ms < 3000) return null;
    const rate = @as(f64, @floatFromInt(done)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0);
    if (rate <= 0) return null;
    const left = @as(f64, @floatFromInt(total -| done)) / rate;
    const tail: f64 = if (tail_done) 90.0 else 210.0; // chkdsk /f + diskpart + TRIM (v3.0.1) + bcdboot/WinRE
    return @intFromFloat(@max(0.0, left + tail));
}

fn resetCloneProgress() void {
    g_copy_total.store(0, .seq_cst);
    g_copy_done.store(0, .seq_cst);
    g_verify_done.store(0, .seq_cst);
    g_work_start_ms.store(std.time.milliTimestamp(), .seq_cst);
    g_tail_done.store(false, .seq_cst);
}

/// Decodes %XX and '+' of a URL query value into `out` (invalid escapes are kept literally).
fn percentDecode(in: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < in.len and n < out.len) : (n += 1) {
        if (in[i] == '%' and i + 2 < in.len) {
            const v = std.fmt.parseInt(u8, in[i + 1 .. i + 3], 16) catch {
                out[n] = in[i];
                i += 1;
                continue;
            };
            out[n] = v;
            i += 3;
        } else {
            out[n] = if (in[i] == '+') ' ' else in[i];
            i += 1;
        }
    }
    return out[0..n];
}

/// Value of `name` in the query string of an HTTP request line ("POST /x?a=1&b=2 HTTP/1.1").
fn queryParam(first_line: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, first_line, '?') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, first_line, q, ' ') orelse first_line.len;
    var it = std.mem.splitScalar(u8, first_line[q + 1 .. end], '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return null;
}

/// NVF-E035: true when the disk now at the chosen target number is the one the user confirmed.
fn targetMatchesConfirmed(model_now: []const u8, bytes_now: u64, expect_model: []const u8, expect_bytes: u64) bool {
    return bytes_now == expect_bytes and std.mem.eql(u8, std.mem.trim(u8, model_now, " "), std.mem.trim(u8, expect_model, " "));
}

/// NVF-E037: "[2026-10-30 09:53:31.440] ===== ..." -> "2026-10-30_095331" (for the per-run log name).
fn runStampFromHeader(first_line: []const u8, out: []u8) ?[]const u8 {
    if (first_line.len < 20 or first_line[0] != '[') return null;
    const d = first_line[1..11];
    const t = first_line[12..20];
    for (d, 0..) |ch, k| if (!(std.ascii.isDigit(ch) or ((k == 4 or k == 7) and ch == '-'))) return null;
    for (t, 0..) |ch, k| if (!(std.ascii.isDigit(ch) or ((k == 2 or k == 5) and ch == ':'))) return null;
    return std.fmt.bufPrint(out, "{s}_{s}{s}{s}", .{ d, t[0..2], t[3..5], t[6..8] }) catch null;
}

/// NVF-E037: keep every run's log. The previous clone_run.log moves to logs\runs\clone_run_<inicio>.log
/// and only the newest 20 are kept. (Before v2.5 each run overwrote the previous one: the log of the
/// good clone of 2026-10-29 22:12 was lost that way.)
fn archivePreviousRunLog() void {
    var cur_buf: [512]u8 = undefined;
    const cur = getLogPath(&cur_buf, "clone_run.log") orelse return;
    var runs_buf: [512]u8 = undefined;
    const runs_dir = getLogPath(&runs_buf, "runs") orelse return;
    std.fs.cwd().makePath(runs_dir) catch return;
    var head: [64]u8 = undefined;
    const n = blk: {
        const f = std.fs.cwd().openFile(cur, .{}) catch return; // no previous log
        defer f.close();
        break :blk f.readAll(&head) catch 0;
    };
    var stamp_buf: [32]u8 = undefined;
    const stamp = runStampFromHeader(head[0..n], &stamp_buf) orelse "sin_fecha";
    var dst_buf: [640]u8 = undefined;
    var k: u32 = 0;
    while (k < 100) : (k += 1) {
        const dst = (if (k == 0)
            std.fmt.bufPrint(&dst_buf, "{s}\\clone_run_{s}.log", .{ runs_dir, stamp })
        else
            std.fmt.bufPrint(&dst_buf, "{s}\\clone_run_{s}_{d}.log", .{ runs_dir, stamp, k })) catch return;
        if (std.fs.cwd().access(dst, .{})) |_| continue else |_| {}
        std.fs.cwd().rename(cur, dst) catch return;
        break;
    }
    // Prune: keep the newest 20 (names sort chronologically).
    var dir = std.fs.cwd().openDir(runs_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var names: [256][64]u8 = undefined;
    var lens: [256]usize = undefined;
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, "clone_run_") or e.name.len > 64 or count == names.len) continue;
        @memcpy(names[count][0..e.name.len], e.name);
        lens[count] = e.name.len;
        count += 1;
    }
    if (count <= 20) return;
    // Selection of the (count - 20) smallest names.
    var removed: usize = 0;
    while (removed < count - 20) : (removed += 1) {
        var min_i: usize = 0;
        var found = false;
        for (0..count) |i| {
            if (lens[i] == 0) continue;
            if (!found or std.mem.order(u8, names[i][0..lens[i]], names[min_i][0..lens[min_i]]) == .lt) {
                min_i = i;
                found = true;
            }
        }
        if (!found) break;
        dir.deleteFile(names[min_i][0..lens[min_i]]) catch {};
        lens[min_i] = 0;
    }
}

fn getVolumeLengthBytes(dev_path_utf8: []const u8) u64 {
    var wbuf: [128:0]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, dev_path_utf8) catch return 0;
    wbuf[wlen] = 0;

    // 1. Try GENERIC_READ + IOCTL_DISK_GET_LENGTH_INFO (works when Admin)
    const h_read = CreateFileW(
        &wbuf,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        0,
        null,
    );
    if (h_read != INVALID_HANDLE_VALUE) {
        defer _ = CloseHandle(h_read);
        var length_bytes: u64 = 0;
        var bytes_ret: u32 = 0;
        if (DeviceIoControl(
            h_read,
            IOCTL_DISK_GET_LENGTH_INFO,
            null,
            0,
            &length_bytes,
            @sizeOf(u64),
            &bytes_ret,
            null,
        ) != 0 and length_bytes > 0) {
            return length_bytes;
        }
    }

    // 2. Fallback: FILE_ANY_ACCESS (0) + IOCTL_DISK_GET_DRIVE_GEOMETRY_EX (works without Admin)
    const h_any = CreateFileW(
        &wbuf,
        0,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        0,
        null,
    );
    if (h_any == INVALID_HANDLE_VALUE) return 0;
    defer _ = CloseHandle(h_any);

    var geom_buf: [256]u8 align(8) = undefined;
    var geom_ret: u32 = 0;
    if (DeviceIoControl(
        h_any,
        IOCTL_DISK_GET_DRIVE_GEOMETRY_EX,
        null,
        0,
        &geom_buf,
        geom_buf.len,
        &geom_ret,
        null,
    ) != 0 and geom_ret >= 32) {
        return std.mem.readInt(u64, geom_buf[24..32], .little);
    }
    return 0;
}

/// Returns the physical disk number that hosts drive `letter` (e.g. 'C' -> 0), or null if the
/// letter is not a local disk volume. Uses IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS (FILE_ANY_ACCESS).
/// VOLUME_DISK_EXTENTS layout: u32 NumberOfDiskExtents, u32 pad, DISK_EXTENT{ u32 DiskNumber, ... } at offset 8.
fn getVolumeDiskNumber(letter: u8) ?u32 {
    var path = [_:0]u16{ '\\', '\\', '.', '\\', letter, ':' };
    const h = CreateFileW(&path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var buf: [256]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, null, 0, &buf, buf.len, &ret, null) == 0 or ret < 16) return null;
    if (std.mem.readInt(u32, buf[0..4], .little) == 0) return null;
    return std.mem.readInt(u32, buf[8..12], .little);
}

/// NVF-E030: owner lookup that never opens the volume. The EFI System Partition left on S: by a failed
/// v2.2 run could not be queried through its volume handle, so its owner came back null and the next run
/// aborted with a false NVF-E009 ("S: ocupada por otro dispositivo"). Compares the NT target of "S:" with
/// the targets of the "Harddisk<d>Partition<n>" DOS links of the given disk.
fn isLetterOnDiskByDosDevice(letter: u8, disk: u32) bool {
    var name = [_:0]u16{ letter, ':' };
    var target: [512]u16 = undefined;
    const n = QueryDosDeviceW(&name, &target, target.len);
    if (n == 0) return false;
    const t = std.mem.sliceTo(target[0..n], 0);
    if (t.len == 0) return false;
    var part: u32 = 1;
    while (part <= 32) : (part += 1) {
        var nb: [48]u8 = undefined;
        const s8 = std.fmt.bufPrint(&nb, "Harddisk{d}Partition{d}", .{ disk, part }) catch return false;
        var w: [48:0]u16 = undefined;
        const wl = std.unicode.utf8ToUtf16Le(&w, s8) catch return false;
        w[wl] = 0;
        var pt: [512]u16 = undefined;
        const pn = QueryDosDeviceW(&w, &pt, pt.len);
        if (pn == 0) continue;
        if (std.mem.eql(u16, t, std.mem.sliceTo(pt[0..pn], 0))) return true;
    }
    return false;
}

/// True when drive `letter` is a volume of `disk` (volume extents first, DOS links as fallback).
fn isLetterOnDisk(letter: u8, disk: u32) bool {
    if (disk == NO_DISK) return false;
    if (getVolumeDiskNumber(letter)) |d| return d == disk;
    return isLetterOnDiskByDosDevice(letter, disk);
}

/// NVF-E030: releases the S: and R: letters that this flow assigned on the target disk, on ANY exit after
/// dp_init (success or failure). A letter that is not on the target disk is never touched.
fn releaseCloneLetters(alloc: std.mem.Allocator, disk: u32) void {
    releaseTargetDiskLetters(alloc, disk, false);
}

/// NVF-E030 (v2.3.1): removes S:, R: (and W: when asked) from EVERY partition of the target disk, selecting
/// by disk + partition and never by letter. It therefore can never touch another device and does not need
/// to identify the volume behind a letter (v2.3.0 could not identify the target EFI partition on S: by
/// extents nor by DOS links -> false NVF-E009). Same diskpart pattern as dp_z_unmount, which already works
/// on an EFI partition. A missing partition N only aborts that one-partition script (NVF-E007).
fn releaseTargetDiskLetters(alloc: std.mem.Allocator, disk: u32, include_w: bool) void {
    if (disk == NO_DISK) return;
    var part: u32 = 1;
    while (part <= 6) : (part += 1) {
        var body: [256]u8 = undefined;
        // F4: at the start (include_w) every letter of the target's partitions goes ("remove all": the disk is
        // wiped next anyway); at the end only the EFI and WinRE letters of this clone, Windows keeps its own.
        const script = (if (include_w)
            std.fmt.bufPrint(&body, "select disk {d}\r\nselect partition {d}\r\nremove all noerr\r\nexit\r\n", .{ disk, part })
        else
            std.fmt.bufPrint(&body, "select disk {d}\r\nselect partition {d}\r\nremove letter={c} noerr\r\nremove letter={c} noerr\r\nexit\r\n", .{ disk, part, letterOf(LETTER_EFI), letterOf(LETTER_REC) })) catch return;
        var name: [32]u8 = undefined;
        const script_name = std.fmt.bufPrint(&name, "dp_free_letters_p{d}", .{part}) catch return;
        _ = runDiskpartScript(alloc, script_name, script);
    }
}

const DDD_RAW_TARGET_PATH: u32 = 0x1;
const DDD_REMOVE_DEFINITION: u32 = 0x2;
const DDD_EXACT_MATCH_ON_REMOVE: u32 = 0x4;
const DRIVE_REMOTE: u32 = 4;

/// NVF-E039 (pure): evidence that a drive letter is an ORPHAN left by a device that no longer exists
/// (Explorer shows "Disco local (S:)" with a "?" and no size; 2026-10-30 21:54: error_consulta=2 and
/// diskpart "La letra de unidad especificada no es valida" on the target's EFI). Opening \\.\X: fails with
/// "not found" AND the NT device it points to (\Device\...) does not exist either. subst (\??\...), network
/// drives and real volumes that only refuse access (an EFI partition, an empty card reader) never qualify.
fn isOrphanLetterEvidence(open_err: u32, dos_target: []const u8, target_open_err: u32) bool {
    if (open_err != 2 and open_err != 3) return false;
    if (!std.mem.startsWith(u8, dos_target, "\\Device\\")) return false;
    return target_open_err == 2 or target_open_err == 3;
}

/// NT target (null-terminated in `out`) of `letter` when the letter is an orphan (NVF-E039); null otherwise.
/// Read-only, works without Admin.
fn orphanLetterTarget(letter: u8, out: *[512:0]u16) ?[]const u16 {
    if (!isDriveLetterInUse(letter)) return null;
    var root = [_:0]u16{ letter, ':', '\\' };
    if (GetDriveTypeW(&root) == DRIVE_REMOTE) return null;
    var path = [_:0]u16{ '\\', '\\', '.', '\\', letter, ':' };
    const h = CreateFileW(&path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h != INVALID_HANDLE_VALUE) {
        _ = CloseHandle(h);
        return null; // the device exists
    }
    const open_err = GetLastError();
    var name = [_:0]u16{ letter, ':' };
    const n = QueryDosDeviceW(&name, out, 500);
    if (n == 0) return null;
    const t = std.mem.sliceTo(out[0..n], 0);
    if (t.len == 0 or t.len > 480) return null;
    out[t.len] = 0;
    var t8: [1024]u8 = undefined;
    const t8len = std.unicode.utf16LeToUtf8(&t8, t) catch return null;
    // Does the NT device itself exist? \\?\GLOBALROOT\Device\HarddiskVolumeNN
    const prefix = [_]u16{ '\\', '\\', '?', '\\', 'G', 'L', 'O', 'B', 'A', 'L', 'R', 'O', 'O', 'T' };
    var gr: [520:0]u16 = undefined;
    @memcpy(gr[0..prefix.len], &prefix);
    @memcpy(gr[prefix.len .. prefix.len + t.len], t);
    gr[prefix.len + t.len] = 0;
    const h2 = CreateFileW(&gr, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    var t_err: u32 = 0;
    if (h2 != INVALID_HANDLE_VALUE) _ = CloseHandle(h2) else t_err = GetLastError();
    if (!isOrphanLetterEvidence(open_err, t8[0..t8len], t_err)) return null;
    return out[0..t.len];
}

/// NVF-E039: removes an orphan letter. Only its NAME is deleted (the device it pointed to no longer exists),
/// so no data can be touched. First through the mount manager (same as "mountvol X: /D"), then the DOS
/// device link itself. Returns true when the letter is free afterwards.
fn freeOrphanLetter(letter: u8) bool {
    var tbuf: [512:0]u16 = undefined;
    const t = orphanLetterTarget(letter, &tbuf) orelse return false;
    var t8: [1024]u8 = undefined;
    const t8len = std.unicode.utf16LeToUtf8(&t8, t) catch 0;
    var mp = [_:0]u16{ letter, ':', '\\' };
    const mm_err: u32 = if (DeleteVolumeMountPointW(&mp) != 0) 0 else GetLastError();
    Sleep(300);
    var dd_err: u32 = 0;
    if (isDriveLetterInUse(letter)) {
        var name = [_:0]u16{ letter, ':' };
        if (DefineDosDeviceW(DDD_RAW_TARGET_PATH | DDD_REMOVE_DEFINITION | DDD_EXACT_MATCH_ON_REMOVE, &name, &tbuf) == 0) dd_err = GetLastError();
        Sleep(200);
        if (isDriveLetterInUse(letter)) {
            var gname = [_:0]u16{ 'G', 'l', 'o', 'b', 'a', 'l', '\\', letter, ':' };
            if (DefineDosDeviceW(DDD_RAW_TARGET_PATH | DDD_REMOVE_DEFINITION | DDD_EXACT_MATCH_ON_REMOVE, &gname, &tbuf) == 0) dd_err = GetLastError();
            Sleep(200);
        }
    }
    const freed = !isDriveLetterInUse(letter);
    var l: [256]u8 = undefined;
    if (std.fmt.bufPrint(&l, "LETRA {c}: huerfana (apuntaba a {s}, que ya no existe) mountmgr_err={d} dosdevice_err={d} -> {s}", .{
        letter, t8[0..t8len], mm_err, dd_err, if (freed) "LIBERADA" else "SIGUE OCUPADA",
    })) |s2| appendRunLog(s2) else |_| {}
    return freed;
}

const LetterUse = enum { free, volume, orphan, unknown };

/// Read-only state of a reserved letter for /api/status and --preflight: free, a volume of disk N,
/// an orphan (NVF-E039) or something Windows does not identify.
fn reservedLetterUse(letter: u8, disk_out: *?u32) LetterUse {
    disk_out.* = null;
    if (!isDriveLetterInUse(letter)) return .free;
    if (getVolumeDiskNumber(letter)) |d| {
        disk_out.* = d;
        return .volume;
    }
    var d: u32 = 0;
    while (d < MAX_DISKS) : (d += 1) {
        if (isLetterOnDiskByDosDevice(letter, d)) {
            disk_out.* = d;
            return .volume;
        }
    }
    var tb: [512:0]u16 = undefined;
    if (orphanLetterTarget(letter, &tb) != null) return .orphan;
    return .unknown;
}

/// Win32 error of opening \\.\X: and querying its disk extents (0 = OK). Only for the log (NVF-E009/E030).
fn volumeQueryError(letter: u8) u32 {
    var path = [_:0]u16{ '\\', '\\', '.', '\\', letter, ':' };
    const h = CreateFileW(&path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return GetLastError();
    defer _ = CloseHandle(h);
    var buf: [256]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, null, 0, &buf, buf.len, &ret, null) == 0) return GetLastError();
    return 0;
}

/// Pure (F3): the BCD of the clone (bcdedit /store ... /enum {default}) boots the clone's own Windows: at least
/// "device" and "osdevice" are partition=<letter of the clone's Windows>, and the loader is winload.efi.
fn bcdPointsTo(text: []const u8, win_letter: u8) bool {
    var needle: [16]u8 = undefined;
    const nd = std.fmt.bufPrint(&needle, "partition={c}:", .{win_letter}) catch return false;
    var count: usize = 0;
    var i: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(text, i, nd)) |k| {
        count += 1;
        i = k + nd.len;
    }
    return count >= 2 and std.ascii.indexOfIgnoreCase(text, "winload.efi") != null;
}

fn readLogFile(name: []const u8, out: []u8) []const u8 {
    var pb: [512]u8 = undefined;
    var nb: [64]u8 = undefined;
    const fname = std.fmt.bufPrint(&nb, "{s}.log", .{name}) catch return out[0..0];
    const path = getLogPath(&pb, fname) orelse return out[0..0];
    const f = std.fs.cwd().openFile(path, .{}) catch return out[0..0];
    defer f.close();
    const n = f.readAll(out) catch 0;
    return out[0..n];
}

/// NVF-E031: written at the end of a clone whose bcdboot succeeded; protects a finished clone from being
/// wiped by an accidental re-run (2026-10-30 09:05 a re-run destroyed the good clone of 2026-10-29 22:12).
const CLONE_MARKER_NAME = "NVMeForge_CLON_OK.txt";

/// F4: the marker lives at the root of the clone's Windows partition, whatever its letter. Returns the letter
/// (and disk) of the first mounted volume, other than the source disk, that holds it; `only_disk` filters.
fn findCloneMarker(only_disk: ?u32, c_disk: ?u32) ?struct { letter: u8, disk: u32 } {
    const mask = GetLogicalDrives();
    var i: u5 = 3; // D..Z
    while (true) : (i += 1) {
        const letter: u8 = 'A' + @as(u8, i);
        var root = [_:0]u16{ letter, ':', '\\' };
        if ((mask & (@as(u32, 1) << i)) != 0 and GetDriveTypeW(&root) != DRIVE_REMOTE) {
            if (getVolumeDiskNumber(letter)) |d| {
                const other = c_disk == null or d != c_disk.?;
                if (other and (only_disk == null or d == only_disk.?)) {
                    var pb: [40]u8 = undefined;
                    if (std.fmt.bufPrint(&pb, "{c}:\\{s}", .{ letter, CLONE_MARKER_NAME })) |pth| {
                        if (fileExistsAbs(pth)) return .{ .letter = letter, .disk = d };
                    } else |_| {}
                }
            }
        }
        if (i == 25) break;
    }
    return null;
}

fn writeCloneMarker(status: []const u8) void {
    var pb: [64]u8 = undefined;
    const marker_path = L(&pb, "@W:\\NVMeForge_CLON_OK.txt");
    const f = std.fs.createFileAbsolute(marker_path, .{}) catch {
        appendRunLog("MARCA clon: no se pudo escribir NVMeForge_CLON_OK.txt");
        return;
    };
    defer f.close();
    var st = SYSTEMTIME{};
    GetLocalTime(&st);
    var buf: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "NVMeForge v{s}\r\nClon terminado: {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}\r\nEstado: {s}\r\n\r\nEste disco ya es un clon completo. NVMeForge se niega a volver a clonar encima (NVF-E031).\r\nSi de verdad quiere reclonar, borre este archivo y vuelva a intentarlo.\r\n", .{
        VERSION, st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, status,
    }) catch return;
    f.writeAll(body) catch return;
    var ml: [96]u8 = undefined;
    if (std.fmt.bufPrint(&ml, "MARCA clon: {s} escrita", .{marker_path})) |x| appendRunLog(x) else |_| {}
}

/// Partition length in bytes of drive `letter` from VOLUME_DISK_EXTENTS.Extents[0].ExtentLength (offset 24).
/// NVF-E013: IOCTL_DISK_GET_DRIVE_GEOMETRY_EX on "\\.\C:" returns the WHOLE physical disk (512 GB),
/// not the C: partition (443.77 GiB). Use this for any partition sizing; works without Admin.
fn getVolumePartitionBytes(letter: u8) u64 {
    var path = [_:0]u16{ '\\', '\\', '.', '\\', letter, ':' };
    const h = CreateFileW(&path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return 0;
    defer _ = CloseHandle(h);
    var buf: [256]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, null, 0, &buf, buf.len, &ret, null) == 0 or ret < 32) return 0;
    if (std.mem.readInt(u32, buf[0..4], .little) != 1) return 0; // spanned volumes not supported
    return std.mem.readInt(u64, buf[24..32], .little);
}

const IOCTL_STORAGE_QUERY_PROPERTY: u32 = 0x002D1400;

/// Physical identity of \\.\PhysicalDrive<n> from STORAGE_DEVICE_DESCRIPTOR (FILE_ANY_ACCESS, no Admin).
/// Offsets: ProductIdOffset @16, SerialNumberOffset @24, BusType @28.
const DiskIdentity = struct {
    product_buf: [64]u8 = undefined,
    product_len: usize = 0,
    serial_buf: [96]u8 = undefined,
    serial_len: usize = 0,
    bus: u32 = 0,

    fn product(self: *const DiskIdentity) []const u8 {
        return self.product_buf[0..self.product_len];
    }
    fn serial(self: *const DiskIdentity) []const u8 {
        return self.serial_buf[0..self.serial_len];
    }
};

fn copyDescriptorString(desc: []const u8, offset: u32, out: []u8) usize {
    if (offset == 0 or offset >= desc.len) return 0;
    const rest = desc[offset..];
    const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
    const s = std.mem.trim(u8, rest[0..end], " .");
    var n: usize = 0;
    for (s) |ch| {
        if (n >= out.len) break;
        out[n] = if (ch >= 0x20 and ch < 0x7F and ch != '"' and ch != '\\') ch else '_';
        n += 1;
    }
    return n;
}

fn getDiskIdentity(disk: u32) ?DiskIdentity {
    var path_buf: [64]u8 = undefined;
    const dev_utf8 = std.fmt.bufPrint(&path_buf, "\\\\.\\PhysicalDrive{d}", .{disk}) catch return null;
    var wbuf: [64:0]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, dev_utf8) catch return null;
    wbuf[wlen] = 0;
    const h = CreateFileW(&wbuf, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var query = [_]u8{0} ** 12; // StorageDeviceProperty (0), PropertyStandardQuery (0)
    var desc: [1024]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &query, query.len, &desc, desc.len, &ret, null) == 0 or ret < 32) return null;
    var id = DiskIdentity{};
    const d = desc[0..ret];
    id.product_len = copyDescriptorString(d, std.mem.readInt(u32, desc[16..20], .little), &id.product_buf);
    id.serial_len = copyDescriptorString(d, std.mem.readInt(u32, desc[24..28], .little), &id.serial_buf);
    id.bus = std.mem.readInt(u32, desc[28..32], .little);
    return id;
}

fn busTypeName(bus: u32) []const u8 {
    return switch (bus) {
        7 => "USB",
        17 => "NVMe",
        11 => "SATA",
        10 => "SAS",
        else => "otro",
    };
}

fn isDriveLetterInUse(letter: u8) bool {
    const mask = GetLogicalDrives();
    const bit: u5 = @intCast(letter - 'A');
    return (mask & (@as(u32, 1) << bit)) != 0;
}

const GptPart = struct { number: u32, bytes: u64 };

/// Pure: first partition of `type_guid` with at least `min_bytes` in a DRIVE_LAYOUT_INFORMATION_EX buffer
/// (GPT only). Layout: header 48 bytes; PARTITION_INFORMATION_EX entries of 144 bytes (PartitionLength @16,
/// PartitionNumber @24, GPT PartitionType GUID @32).
fn findGptPartitionInLayout(layout: []const u8, type_guid: *const [16]u8, min_bytes: u64) ?GptPart {
    if (layout.len < 48) return null;
    if (std.mem.readInt(u32, layout[0..4], .little) != 1) return null; // GPT only
    const count = std.mem.readInt(u32, layout[4..8], .little);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const off = 48 + i * 144;
        if (off + 144 > layout.len) break;
        const e = layout[off .. off + 144];
        const len = std.mem.readInt(u64, e[16..24], .little);
        if (std.mem.eql(u8, e[32..48], type_guid) and len >= min_bytes) {
            return .{ .number = std.mem.readInt(u32, e[24..28], .little), .bytes = len };
        }
    }
    return null;
}

/// Reads the partition table of \\.\PhysicalDrive<disk> (FILE_ANY_ACCESS, no Admin) and finds a GPT
/// partition by type. v2.7: used for the source EFI (NVF-E038, before v2.7 "disk 0 partition 1" was assumed)
/// and the source WinRE (NVF-E020).
fn findGptPartition(disk: u32, type_guid: *const [16]u8, min_bytes: u64) ?GptPart {
    var path_buf: [64]u8 = undefined;
    const dev_utf8 = std.fmt.bufPrint(&path_buf, "\\\\.\\PhysicalDrive{d}", .{disk}) catch return null;
    var wbuf: [64:0]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, dev_utf8) catch return null;
    wbuf[wlen] = 0;
    const h = CreateFileW(&wbuf, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var layout: [8192]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, null, 0, &layout, layout.len, &ret, null) == 0) return null;
    return findGptPartitionInLayout(layout[0..ret], type_guid, min_bytes);
}

// ---------------- v2.8: full-disk clone (every partition of the source) ----------------

const MAX_EXTRAS: usize = 16;

const GptEntry = struct {
    number: u32 = 0,
    offset: u64 = 0,
    bytes: u64 = 0,
    type_guid: [16]u8 = @splat(0),
    attributes: u64 = 0,
    name_w: [36]u16 = @splat(0),

    fn nameUtf8(self: *const GptEntry, out: []u8) []const u8 {
        const w = std.mem.sliceTo(&self.name_w, 0);
        const n = std.unicode.utf16LeToUtf8(out, w) catch return "";
        return out[0..n];
    }
};

/// Pure: every GPT partition of a DRIVE_LAYOUT_INFORMATION_EX buffer (empty slots skipped), sorted by offset.
/// PARTITION_INFORMATION_EX (144 bytes): StartingOffset @8, PartitionLength @16, PartitionNumber @24,
/// PartitionType @32, PartitionId @48, Attributes @64, Name (36 UTF-16) @72.
fn parseGptEntries(layout: []const u8, out: []GptEntry) usize {
    if (layout.len < 48) return 0;
    if (std.mem.readInt(u32, layout[0..4], .little) != 1) return 0; // GPT only
    const count = std.mem.readInt(u32, layout[4..8], .little);
    var n: usize = 0;
    var i: usize = 0;
    while (i < count and n < out.len) : (i += 1) {
        const off = 48 + i * 144;
        if (off + 144 > layout.len) break;
        const e = layout[off .. off + 144];
        const len = std.mem.readInt(u64, e[16..24], .little);
        const num = std.mem.readInt(u32, e[24..28], .little);
        if (len == 0 or num == 0) continue;
        var g = GptEntry{ .number = num, .offset = std.mem.readInt(u64, e[8..16], .little), .bytes = len, .attributes = std.mem.readInt(u64, e[64..72], .little) };
        @memcpy(&g.type_guid, e[32..48]);
        for (0..36) |k| g.name_w[k] = std.mem.readInt(u16, e[72 + 2 * k ..][0..2], .little);
        out[n] = g;
        n += 1;
    }
    std.mem.sort(GptEntry, out[0..n], {}, struct {
        fn lt(_: void, a: GptEntry, b: GptEntry) bool {
            return a.offset < b.offset;
        }
    }.lt);
    return n;
}

const ExtraCopy = enum { raw, skip_mounted, skip_unsupported };
const ExtraPart = struct { entry: GptEntry, copy: ExtraCopy, letter: u8 = 0 };

/// Pure: the source partitions that the C:-based flow does not recreate by itself. Everything except EFI, MSR,
/// the C: partition (by offset) and the WinRE partition that is recreated as R: (by number). A partition with
/// a drive letter is in use (it can change while copying) and is reported as skip_mounted, never copied raw.
fn selectExtraPartitions(entries: []const GptEntry, c_offset: u64, winre_number: ?u32, lettered: []const VolExtent, out: []ExtraPart) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (n >= out.len) break;
        if (std.mem.eql(u8, &e.type_guid, &GUID_EFI) or std.mem.eql(u8, &e.type_guid, &GUID_MSR)) continue;
        if (e.offset == c_offset) continue;
        if (winre_number != null and e.number == winre_number.?) continue;
        var letter: u8 = 0;
        for (lettered) |v| {
            if (v.offset == e.offset) letter = v.letter;
        }
        // Review v2.8 #5: only plain data and recovery partitions are copied raw. Storage Spaces, LDM and
        // unknown types could be taken as members of the SOURCE pool while both disks are attached.
        const supported = std.mem.eql(u8, &e.type_guid, &GUID_DATA) or std.mem.eql(u8, &e.type_guid, &GUID_WINRE);
        out[n] = .{ .entry = e, .copy = if (letter != 0) .skip_mounted else if (!supported) .skip_unsupported else .raw, .letter = letter };
        n += 1;
    }
    return n;
}

/// Pure: MiB to reserve at the end of the target for the extras that are copied.
fn extrasMb(extras: []const ExtraPart) u64 {
    var t: u64 = 0;
    for (extras) |e| {
        if (e.copy == .raw) t += ceilMb(e.entry.bytes) + EXTRA_MARGIN_MB;
    }
    return t;
}

/// Pure: GPT GUID bytes (mixed endian) -> "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" (diskpart id= format).
fn fmtGuid(g: *const [16]u8, out: *[36]u8) []const u8 {
    const d1 = std.mem.readInt(u32, g[0..4], .little);
    const d2 = std.mem.readInt(u16, g[4..6], .little);
    const d3 = std.mem.readInt(u16, g[6..8], .little);
    return std.fmt.bufPrint(out, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ d1, d2, d3, g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15] }) catch out[0..0];
}

/// Pure (review v2.8 #1, strict): the copied extras must be EXACTLY the partitions that follow R: on the target,
/// in order, same type and the exact size diskpart was asked for. Anything else -> false and nothing is written.
fn mapExtrasToTarget(target: []const GptEntry, r_offset: u64, extras: []const ExtraPart, out_numbers: []u32) bool {
    var after: usize = 0;
    for (target) |t| {
        if (t.offset > r_offset) after += 1;
    }
    var nraw: usize = 0;
    for (extras) |e| {
        if (e.copy == .raw) nraw += 1;
    }
    if (nraw == 0 or after != nraw or nraw > out_numbers.len) return false;
    var ti: usize = target.len - after;
    var k: usize = 0;
    for (extras) |e| {
        if (e.copy != .raw) continue;
        const t = target[ti];
        if (t.offset <= r_offset) return false;
        if (!std.mem.eql(u8, &t.type_guid, &e.entry.type_guid)) return false;
        const want = ceilMb(e.entry.bytes) * MIB;
        if (t.bytes < want or t.bytes > want + MIB) return false;
        out_numbers[k] = t.number;
        k += 1;
        ti += 1;
    }
    return true;
}

fn readLayoutEntries(disk: u32, out: []GptEntry) usize {
    const h = openPhysicalDrive(disk, 0, 0) orelse return 0;
    defer _ = CloseHandle(h);
    var layout: [8192]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, null, 0, &layout, layout.len, &ret, null) == 0) return 0;
    return parseGptEntries(layout[0..ret], out);
}

/// Extra partitions of the source disk (I/O). Read-only, works without Admin.
fn sourceExtras(src_disk: u32, winre_number: ?u32, out: []ExtraPart) usize {
    const c = volumeExtent('C') orelse return 0;
    var entries: [32]GptEntry = undefined;
    const n = readLayoutEntries(src_disk, &entries); // > 32 partitions (or > MAX_EXTRAS extras) are not supported
    var ext: [26]VolExtent = undefined;
    const ne = collectVolumeExtents(&ext);
    var mine: [26]VolExtent = undefined;
    var nm: usize = 0;
    for (ext[0..ne]) |v| {
        if (v.disk == src_disk) {
            mine[nm] = v;
            nm += 1;
        }
    }
    return selectExtraPartitions(entries[0..n], c.offset, winre_number, mine[0..nm], out);
}

/// Logical sector size of \\.\PhysicalDrive<disk> (DISK_GEOMETRY.BytesPerSector @20), null if unknown.
fn diskLogicalSectorBytes(disk: u32) ?u32 {
    const h = openPhysicalDrive(disk, 0, 0) orelse return null;
    defer _ = CloseHandle(h);
    var geom: [256]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, null, 0, &geom, geom.len, &ret, null) == 0 or ret < 24) return null;
    const v = std.mem.readInt(u32, geom[20..24], .little);
    return if (v == 0) null else v;
}

/// v2.8: copies one extra partition sector by sector (source disk range -> target partition, locked and
/// dismounted) and then re-reads 100 % of it from the target, comparing XxHash64 of every 8 MiB chunk with
/// what was written (same rule as NVF-E026). The source partition has no letter, so nothing writes to it.
/// Pure: overall bar for the extras, 88 % -> 94 % (copy then read-back of each partition in turn).
fn extraPct(idx: usize, count: usize, pos: u64, bytes: u64, verifying: bool) f64 {
    if (count == 0 or bytes == 0) return 88.0;
    const per = 6.0 / @as(f64, @floatFromInt(count));
    const f = @as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(bytes));
    return 88.0 + per * (@as(f64, @floatFromInt(idx)) + (if (verifying) 0.5 + f * 0.5 else f * 0.5));
}

fn copyExtraPartition(alloc: std.mem.Allocator, src_disk: u32, src: GptEntry, dst_disk: u32, dst_number: u32, idx: usize, count: usize, bench_mbs: f64) !void {
    const chunk: u64 = 8 * MIB;
    const h_src = openPhysicalDrive(src_disk, GENERIC_READ, FILE_FLAG_NO_BUFFERING) orelse return error.CannotOpenSource;
    defer _ = CloseHandle(h_src);
    // Review v2.8 #4: the source partition has no letter, but it is still mounted; lock its volume (read-only
    // handle, nothing is written) so nothing can change it while it is copied. No lock -> not copied.
    var sp8: [96]u8 = undefined;
    const sp = std.fmt.bufPrint(&sp8, "\\\\?\\GLOBALROOT\\Device\\Harddisk{d}\\Partition{d}", .{ src_disk, src.number }) catch return error.PathTooLong;
    var spw: [96:0]u16 = undefined;
    const spl = std.unicode.utf8ToUtf16Le(&spw, sp) catch return error.PathTooLong;
    spw[spl] = 0;
    const h_src_vol = CreateFileW(&spw, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h_src_vol == INVALID_HANDLE_VALUE) return error.CannotOpenSourcePartition;
    defer _ = CloseHandle(h_src_vol);
    var brs: u32 = 0;
    if (DeviceIoControl(h_src_vol, FSCTL_LOCK_VOLUME, null, 0, null, 0, &brs, null) == 0) {
        var l: [128]u8 = undefined;
        if (std.fmt.bufPrint(&l, "EXTRA origen particion {d}: no se pudo bloquear (GetLastError={d}); no se copia para no clonar algo que cambia", .{ src.number, GetLastError() })) |x| appendRunLog(x) else |_| {}
        return error.SourceInUse;
    }
    defer _ = DeviceIoControl(h_src_vol, FSCTL_UNLOCK_VOLUME, null, 0, null, 0, &brs, null);
    var p8: [96]u8 = undefined;
    const p = std.fmt.bufPrint(&p8, "\\\\?\\GLOBALROOT\\Device\\Harddisk{d}\\Partition{d}", .{ dst_disk, dst_number }) catch return error.PathTooLong;
    var pw: [96:0]u16 = undefined;
    const pl = std.unicode.utf8ToUtf16Le(&pw, p) catch return error.PathTooLong;
    pw[pl] = 0;
    const h_dst = CreateFileW(&pw, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, FILE_FLAG_NO_BUFFERING, null);
    if (h_dst == INVALID_HANDLE_VALUE) return error.CannotOpenTarget;
    defer _ = CloseHandle(h_dst);
    var br: u32 = 0;
    var locked = DeviceIoControl(h_dst, FSCTL_LOCK_VOLUME, null, 0, null, 0, &br, null) != 0;
    var tries: u32 = 1;
    while (!locked and tries < 6) : (tries += 1) {
        _ = DeviceIoControl(h_dst, FSCTL_DISMOUNT_VOLUME, null, 0, null, 0, &br, null);
        Sleep(500);
        locked = DeviceIoControl(h_dst, FSCTL_LOCK_VOLUME, null, 0, null, 0, &br, null) != 0;
    }
    {
        var l: [160]u8 = undefined;
        if (std.fmt.bufPrint(&l, "EXTRA {d}/{d}: origen Disco {d} particion {d} offset={d} bytes={d} -> destino Disco {d} particion {d} bloqueada={s}", .{ idx + 1, count, src_disk, src.number, src.offset, src.bytes, dst_disk, dst_number, if (locked) "si" else "NO" })) |s| appendRunLog(s) else |_| {}
    }
    if (!locked) return error.TargetLockFailed; // NVF-E027: never write raw sectors without the exclusive lock
    _ = DeviceIoControl(h_dst, FSCTL_DISMOUNT_VOLUME, null, 0, null, 0, &br, null);

    const nchunks: usize = @intCast((src.bytes + chunk - 1) / chunk);
    const digests = try alloc.alloc(u64, nchunks);
    defer alloc.free(digests);
    const buf = VirtualAlloc(null, @intCast(chunk), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return error.OutOfMemory;
    defer _ = VirtualFree(buf, 0, MEM_RELEASE);

    var title_buf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Etapa 6/7: Copiando la partición {d} de {d} del disco de origen", .{ idx + 1, count }) catch "Etapa 6/7: Copiando particiones";
    var pos: u64 = 0;
    var ci: usize = 0;
    var last_report: u64 = 0;
    while (pos < src.bytes) : ({
        pos += chunk;
        ci += 1;
    }) {
        const n: u32 = @intCast(@min(chunk, src.bytes - pos));
        const got = positionedIo(false, h_src, @intCast(src.offset + pos), buf, n, "extra_lectura") orelse return error.ReadFailed;
        if (got != n) return error.ReadFailed;
        digests[ci] = std.hash.XxHash64.hash(VERIFY_DIGEST_SEED, buf[0..n]);
        const put = positionedIo(true, h_dst, @intCast(pos), buf, n, "extra_escritura") orelse return error.WriteFailed;
        if (put != n) return error.WriteFailed;
        _ = g_copy_done.fetchAdd(n, .seq_cst);
        if (pos - last_report >= 512 * MIB or pos == 0) {
            last_report = pos;
            var d: [160]u8 = undefined;
            const ds = std.fmt.bufPrint(&d, "Copiando {d:.2} de {d:.2} GB, sector por sector...", .{ decGB(pos), decGB(src.bytes) }) catch "Copiando...";
            updateProgress(title, ds, extraPct(idx, count, pos, src.bytes, false), bench_mbs, false);
        }
    }
    _ = FlushFileBuffers(h_dst);
    // 100 % read-back of what was written.
    pos = 0;
    ci = 0;
    var bad: usize = 0;
    while (pos < src.bytes) : ({
        pos += chunk;
        ci += 1;
    }) {
        const n: u32 = @intCast(@min(chunk, src.bytes - pos));
        const got = positionedIo(false, h_dst, @intCast(pos), buf, n, "extra_verificacion") orelse return error.VerifyReadFailed;
        if (got != n) return error.VerifyReadFailed;
        if (std.hash.XxHash64.hash(VERIFY_DIGEST_SEED, buf[0..n]) != digests[ci]) bad += 1;
        _ = g_verify_done.fetchAdd(n, .seq_cst);
        if (pos % (1024 * MIB) == 0) {
            var d: [160]u8 = undefined;
            const ds = std.fmt.bufPrint(&d, "Releyendo {d:.2} de {d:.2} GB para comprobar la copia...", .{ decGB(pos), decGB(src.bytes) }) catch "Releyendo...";
            updateProgress(title, ds, extraPct(idx, count, pos, src.bytes, true), bench_mbs, false);
        }
    }
    {
        var l: [128]u8 = undefined;
        if (std.fmt.bufPrint(&l, "EXTRA {d}/{d}: {d} bloques releidos, {d} diferencias", .{ idx + 1, count, nchunks, bad })) |s| appendRunLog(s) else |_| {}
    }
    if (bad > 0) return error.VerifyMismatch;
}

/// NVF-E020: WinRE partition (GPT type DE94BBA4-06D1-4D40-A16A-BFD50179D6AC, >= 300 MiB) of `disk`.
fn findRecoveryPartitionNumber(disk: u32) ?u32 {
    return if (findGptPartition(disk, &GUID_WINRE, 300 * MIB)) |p| p.number else null;
}

fn fileExistsAbs(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn getDiskPartitionStyle(disk_num: u32) []const u8 {
    var path_buf: [64]u8 = undefined;
    const dev_utf8 = std.fmt.bufPrint(&path_buf, "\\\\.\\PhysicalDrive{d}", .{disk_num}) catch return "GPT";
    var wbuf: [64:0]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, dev_utf8) catch return "GPT";
    wbuf[wlen] = 0;

    const h = CreateFileW(&wbuf, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return "desconocido";
    defer _ = CloseHandle(h);

    var layout_buf: [4096]u8 align(8) = undefined;
    var bytes_ret: u32 = 0;
    const ok = DeviceIoControl(
        h,
        IOCTL_DISK_GET_DRIVE_LAYOUT_EX,
        null,
        0,
        &layout_buf,
        layout_buf.len,
        &bytes_ret,
        null,
    );
    if (ok == 0 or bytes_ret < 8) return "desconocido";
    const style = std.mem.readInt(u32, layout_buf[0..4], .little);
    const count = std.mem.readInt(u32, layout_buf[4..8], .little);
    if (count == 0 or style == 2) return "RAW";
    if (style == 1) return "GPT";
    return "MBR";
}

fn getCDriveUsedGib() f64 {
    const c_w = [_:0]u16{ 'C', ':', '\\' };
    var free_avail: u64 = 0;
    var total_bytes: u64 = 0;
    var total_free: u64 = 0;
    if (GetDiskFreeSpaceExW(&c_w, &free_avail, &total_bytes, &total_free) != 0 and total_bytes > total_free) {
        const used = total_bytes - total_free;
        return @as(f64, @floatFromInt(used)) / (1024.0 * 1024.0 * 1024.0);
    }
    return -1.0; // v2.4: unknown, never an invented size
}

fn benchmarkPhysicalDriveDma(disk_index: u32) f64 {
    var path_buf: [64]u8 = undefined;
    const dev_utf8 = std.fmt.bufPrint(&path_buf, "\\\\.\\PhysicalDrive{d}", .{disk_index}) catch return -1.0;
    var wbuf: [64:0]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, dev_utf8) catch return -1.0;
    wbuf[wlen] = 0;

    const h = CreateFileW(
        &wbuf,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN,
        null,
    );
    if (h == INVALID_HANDLE_VALUE) return -1.0;
    defer _ = CloseHandle(h);

    const chunk_size: u32 = 8 * 1024 * 1024;
    const total_test: usize = 256 * 1024 * 1024;
    const buf = VirtualAlloc(null, chunk_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return -1.0;
    defer _ = VirtualFree(buf, 0, MEM_RELEASE);

    var timer = std.time.Timer.start() catch return -1.0;
    var read_total: usize = 0;
    while (read_total < total_test) {
        var nr: u32 = 0;
        if (ReadFile(h, buf, chunk_size, &nr, null) == 0 or nr == 0) break;
        read_total += nr;
    }
    const elapsed_ns = timer.read();
    if (read_total == 0 or elapsed_ns == 0) return -1.0;
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
    const mib = @as(f64, @floatFromInt(read_total)) / (1024.0 * 1024.0);
    return mib / secs;
}

fn spawnCommand(alloc: std.mem.Allocator, cmd_utf8: []const u8, flags: u32) bool {
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd_utf8) catch return false;
    defer alloc.free(cmd_w);

    var si = STARTUPINFOW{ .cb = @sizeOf(STARTUPINFOW) };
    if ((flags & CREATE_NO_WINDOW) != 0) {
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = 0;
    }
    var pi = PROCESS_INFORMATION{};

    const ok = CreateProcessW(
        null,
        cmd_w.ptr,
        null,
        null,
        0,
        flags,
        null,
        null,
        &si,
        &pi,
    );
    if (ok == 0) return false;
    if (pi.hThread) |h| _ = CloseHandle(h);
    if (pi.hProcess) |h| _ = CloseHandle(h);
    return true;
}

fn runHiddenCommandWait(alloc: std.mem.Allocator, cmd_utf8: []const u8) u32 {
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd_utf8) catch return 1;
    defer alloc.free(cmd_w);

    var si = STARTUPINFOW{
        .cb = @sizeOf(STARTUPINFOW),
        .dwFlags = STARTF_USESHOWWINDOW,
        .wShowWindow = 0,
    };
    var pi = PROCESS_INFORMATION{};

    const ok = CreateProcessW(
        null,
        cmd_w.ptr,
        null,
        null,
        0,
        CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    );
    if (ok == 0) return 1;
    var exit_code: u32 = 0;
    if (pi.hProcess) |hp| {
        _ = WaitForSingleObject(hp, 0xFFFFFFFF);
        _ = GetExitCodeProcess(hp, &exit_code);
        _ = CloseHandle(hp);
    }
    if (pi.hThread) |ht| _ = CloseHandle(ht);
    return exit_code;
}

const WATCHDOG_IDLE_RC: u32 = 0xDEAD0001;
const WATCHDOG_TIMEOUT_RC: u32 = 0xDEAD0002;

var g_cmd_mutex: std.Thread.Mutex = .{};
var g_cmd_name_buf: [64]u8 = undefined;
var g_cmd_name_len: usize = 0;
var g_cmd_elapsed_s: u32 = 0;
var g_cmd_idle_s: u32 = 0;

fn setCurrentCommand(name: []const u8, elapsed_s: u32, idle_s: u32) void {
    g_cmd_mutex.lock();
    defer g_cmd_mutex.unlock();
    const n = @min(name.len, g_cmd_name_buf.len);
    @memcpy(g_cmd_name_buf[0..n], name[0..n]);
    g_cmd_name_len = n;
    g_cmd_elapsed_s = elapsed_s;
    g_cmd_idle_s = idle_s;
}

/// Runs `cmd_utf8` hidden, redirecting stdout+stderr to %TEMP%\NVMeForge\logs\<log_name>.log,
/// and records "CMD <log_name> rc=<code>" in clone_run.log. Returns the process exit code.
/// idle_limit_s / hard_limit_s = 0 disables that watchdog limit.
fn runLoggedCommandEx(alloc: std.mem.Allocator, log_name: []const u8, cmd_utf8: []const u8, idle_limit_s: u32, hard_limit_s: u32) u32 {
    var log_file_buf: [96]u8 = undefined;
    const log_file = std.fmt.bufPrint(&log_file_buf, "{s}.log", .{log_name}) catch return runHiddenCommandWait(alloc, cmd_utf8);
    var log_path_buf: [512]u8 = undefined;
    const log_path = getLogPath(&log_path_buf, log_file) orelse return runHiddenCommandWait(alloc, cmd_utf8);

    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, cmd_utf8) catch return 1;
    defer alloc.free(cmd_w);
    const log_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, log_path) catch return runHiddenCommandWait(alloc, cmd_utf8);
    defer alloc.free(log_w);

    var sa = SECURITY_ATTRIBUTES{ .nLength = @sizeOf(SECURITY_ATTRIBUTES) };
    const h_log = CreateFileW(log_w.ptr, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, @ptrCast(&sa), CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
    if (h_log == INVALID_HANDLE_VALUE) return runHiddenCommandWait(alloc, cmd_utf8);
    defer _ = CloseHandle(h_log);

    // NVF-E016: stdin = NUL so any interactive prompt ("¿Desea forzar el desmontaje? (S/N)") gets EOF
    // instead of blocking forever on the invisible console created by CREATE_NO_WINDOW.
    const nul_w = [_:0]u16{ 'N', 'U', 'L' };
    const h_nul_raw = CreateFileW(&nul_w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, @ptrCast(&sa), OPEN_EXISTING, 0, null);
    const h_nul: ?*anyopaque = if (h_nul_raw == INVALID_HANDLE_VALUE) null else h_nul_raw;
    defer if (h_nul) |h| {
        _ = CloseHandle(h);
    };

    var si = STARTUPINFOW{
        .cb = @sizeOf(STARTUPINFOW),
        .dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES,
        .wShowWindow = 0,
        .hStdInput = h_nul,
        .hStdOutput = h_log,
        .hStdError = h_log,
    };
    var pi = PROCESS_INFORMATION{};
    var exit_code: u32 = 0xFFFF_FFFF;
    var watchdog_note: []const u8 = "";
    if (CreateProcessW(null, cmd_w.ptr, null, null, 1, CREATE_NO_WINDOW, null, null, &si, &pi) != 0) {
        if (pi.hProcess) |hp| {
            // NVF-E016 watchdog: poll every second; kill if the child shows zero CPU AND zero log growth
            // for `idle_limit_s` (blocked on input / deadlock), or exceeds `hard_limit_s`.
            setCurrentCommand(log_name, 0, 0);
            var elapsed_s: u32 = 0;
            var idle_s: u32 = 0;
            var last_cpu: u64 = 0;
            var last_size: i64 = 0;
            while (WaitForSingleObject(hp, 1000) != 0) {
                elapsed_s += 1;
                var t_create: u64 = 0;
                var t_exit: u64 = 0;
                var t_kernel: u64 = 0;
                var t_user: u64 = 0;
                _ = GetProcessTimes(hp, &t_create, &t_exit, &t_kernel, &t_user);
                const cpu = t_kernel + t_user;
                var size: i64 = 0;
                _ = GetFileSizeEx(h_log, &size);
                if (cpu == last_cpu and size == last_size) idle_s += 1 else idle_s = 0;
                last_cpu = cpu;
                last_size = size;
                setCurrentCommand(log_name, elapsed_s, idle_s);
                if (idle_limit_s > 0 and idle_s >= idle_limit_s) {
                    _ = TerminateProcess(hp, WATCHDOG_IDLE_RC);
                    watchdog_note = " [WATCHDOG: sin CPU ni salida -> terminado]";
                    _ = WaitForSingleObject(hp, 5000);
                    break;
                }
                if (hard_limit_s > 0 and elapsed_s >= hard_limit_s) {
                    _ = TerminateProcess(hp, WATCHDOG_TIMEOUT_RC);
                    watchdog_note = " [WATCHDOG: tiempo maximo excedido -> terminado]";
                    _ = WaitForSingleObject(hp, 5000);
                    break;
                }
            }
            _ = GetExitCodeProcess(hp, &exit_code);
            _ = CloseHandle(hp);
            setCurrentCommand("", 0, 0);
        }
        if (pi.hThread) |ht| _ = CloseHandle(ht);
    }

    var line_buf: [960]u8 = undefined;
    if (std.fmt.bufPrint(&line_buf, "CMD {s} rc={d}{s} :: {s}", .{ log_name, exit_code, watchdog_note, cmd_utf8 })) |line| {
        appendRunLog(line);
    } else |_| {}
    return exit_code;
}

/// Default policy: kill after 180 s with no CPU and no output, or after 30 min total.
fn runLoggedCommand(alloc: std.mem.Allocator, log_name: []const u8, cmd_utf8: []const u8) u32 {
    return runLoggedCommandEx(alloc, log_name, cmd_utf8, 180, 1800);
}

/// Writes the diskpart script to %TEMP%\NVMeForge\logs\<script_name>.txt (kept for forensics),
/// runs `diskpart /s` with output captured in <script_name>.log, and returns the diskpart exit code
/// (0 = OK). NVF-E007: diskpart /s ABORTS the whole script at the first failing command that has no `noerr`.
fn runDiskpartScript(alloc: std.mem.Allocator, script_name: []const u8, script_body: []const u8) u32 {
    ensureLogDir();
    var file_buf: [96]u8 = undefined;
    const file_name = std.fmt.bufPrint(&file_buf, "{s}.txt", .{script_name}) catch return 0xFFFF_FFFF;
    var path_buf: [512]u8 = undefined;
    const script_path = getLogPath(&path_buf, file_name) orelse return 0xFFFF_FFFF;
    {
        const f = std.fs.cwd().createFile(script_path, .{ .truncate = true }) catch return 0xFFFF_FFFF;
        defer f.close();
        f.writeAll(script_body) catch return 0xFFFF_FFFF;
    }
    var cmd_buf: [768]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "\"C:\\Windows\\System32\\diskpart.exe\" /s \"{s}\"", .{script_path}) catch return 0xFFFF_FFFF;
    return runLoggedCommand(alloc, script_name, cmd);
}

/// Maps the OEM code page 850 bytes diskpart writes (es-MX) to plain ASCII.
fn oem850ToAscii(ch: u8) u8 {
    return switch (ch) {
        0xA0, 0xB5 => 'a',
        0x82, 0x90 => 'e',
        0xA1, 0xD6 => 'i',
        0xA2, 0xE0 => 'o',
        0xA3, 0xE9, 0x81 => 'u',
        0xA4, 0xA5 => 'n',
        0x20...0x7E => ch,
        else => ' ',
    };
}

/// Returns the last `max_lines` non-empty lines of logs\<log_name>.log, ASCII-sanitized and joined by " | ".
fn readLogTail(log_name: []const u8, max_lines: usize, out: []u8) []const u8 {
    var file_buf: [96]u8 = undefined;
    const file_name = std.fmt.bufPrint(&file_buf, "{s}.log", .{log_name}) catch return "";
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, file_name) orelse return "";
    const f = std.fs.cwd().openFile(path, .{}) catch return "(sin log)";
    defer f.close();
    var raw: [16384]u8 = undefined;
    const end = f.getEndPos() catch 0;
    if (end > raw.len) f.seekTo(end - raw.len) catch {};
    const n = f.readAll(&raw) catch return "(log ilegible)";
    const data = raw[0..n];

    // Walk backwards collecting up to max_lines non-empty lines.
    var starts: [8]usize = undefined;
    var ends: [8]usize = undefined;
    var found: usize = 0;
    var i: usize = data.len;
    var line_end: usize = data.len;
    while (i > 0 and found < @min(max_lines, starts.len)) {
        i -= 1;
        if (data[i] == '\n' or i == 0) {
            const s = if (data[i] == '\n') i + 1 else i;
            const trimmed = std.mem.trim(u8, data[s..line_end], " \r\n\t");
            if (trimmed.len > 0) {
                starts[found] = s;
                ends[found] = line_end;
                found += 1;
            }
            line_end = i;
        }
    }
    var w: usize = 0;
    var k: usize = found;
    while (k > 0) {
        k -= 1;
        const line = std.mem.trim(u8, data[starts[k]..ends[k]], " \r\n\t");
        if (w > 0 and w + 3 < out.len) {
            @memcpy(out[w .. w + 3], " | ");
            w += 3;
        }
        for (line) |ch| {
            if (w >= out.len) break;
            out[w] = oem850ToAscii(ch);
            w += 1;
        }
    }
    return out[0..w];
}

/// Returns true when the file is gone afterwards (deleted now or it did not exist).
fn deleteSystemTempFileW(path_utf8: []const u8) bool {
    var wbuf: [128:0]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, path_utf8) catch return false;
    wbuf[wlen] = 0;
    _ = SetFileAttributesW(&wbuf, FILE_ATTRIBUTE_NORMAL);
    if (DeleteFileW(&wbuf) == 0) {
        const e = GetLastError();
        if (e == 2 or e == 3) return true; // not there
        var l: [160]u8 = undefined;
        if (std.fmt.bufPrint(&l, "BORRAR {s}: GetLastError={d}", .{ path_utf8, e })) |x| appendRunLog(x) else |_| {}
        return false;
    }
    return true;
}

var g_vss_id_buf: [64]u8 = undefined;
var g_vss_id_len: usize = 0;

/// NVF-E017: Context='ClientAccessible' snapshots are PERSISTENT; every run left one behind
/// (the 2026-10-28 23:18 run already got HarddiskVolumeShadowCopy13). Deleted when the clone ends.
fn deleteVssSnapshot(alloc: std.mem.Allocator) void {
    if (g_vss_id_len == 0) return;
    var cmd_buf: [256]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "\"C:\\Windows\\System32\\vssadmin.exe\" delete shadows /shadow={s} /quiet", .{g_vss_id_buf[0..g_vss_id_len]}) catch return;
    _ = runLoggedCommand(alloc, "vss_delete", cmd);
    g_vss_id_len = 0;
}

fn createVssSnapshotInvisible(alloc: std.mem.Allocator, out_buf: []u8) ?[]const u8 {
    g_vss_id_len = 0;
    var vss_file_buf: [512]u8 = undefined;
    const vss_file = getTempFilePath(&vss_file_buf, "gaco_vss_shadow.txt") orelse return null;
    std.fs.cwd().deleteFile(vss_file) catch {};

    var cmd_buf: [1024]u8 = undefined;
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "\"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command \"$s = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create -Arguments @{{Volume='C:\\';Context='ClientAccessible'}}; $o = Get-CimInstance Win32_ShadowCopy | Where-Object {{ $_.ID -eq $s.ShadowID }}; [IO.File]::WriteAllText('{s}', $s.ShadowID + '|' + $o.DeviceObject)\"",
        .{vss_file},
    ) catch return null;

    _ = runLoggedCommand(alloc, "vss_create", cmd);
    const f = std.fs.cwd().openFile(vss_file, .{}) catch return null;
    defer f.close();
    const n = f.readAll(out_buf) catch return null;
    const trimmed = std.mem.trim(u8, out_buf[0..n], " \r\n\t");
    // File format: "<ShadowID>|<DeviceObject>"
    const sep = std.mem.indexOfScalar(u8, trimmed, '|') orelse return null;
    const id = std.mem.trim(u8, trimmed[0..sep], " ");
    const dev = std.mem.trim(u8, trimmed[sep + 1 ..], " ");
    if (id.len > 0 and id.len <= g_vss_id_buf.len) {
        @memcpy(g_vss_id_buf[0..id.len], id);
        g_vss_id_len = id.len;
    }
    if (dev.len < 10) return null;
    return dev;
}

const FSCTL_GET_RETRIEVAL_POINTERS: u32 = 0x00090073;
const SYSFILE_KEEP_CLUSTERS: u64 = 256; // first 1 MiB of each skipped file is still copied

/// Pure: clears from `bitmap` the clusters [lcn, lcn+count) of a file extent that starts at file cluster `vcn`,
/// except the first SYSFILE_KEEP_CLUSTERS of the file and the forced `edge` zones at both ends of the volume.
/// Returns how many bits were cleared.
fn clearFileExtentBits(bitmap: []u8, total_clusters: u64, edge: u64, vcn: u64, lcn: u64, count: u64) u64 {
    var cleared: u64 = 0;
    var k: u64 = 0;
    while (k < count) : (k += 1) {
        if (vcn + k < SYSFILE_KEEP_CLUSTERS) continue;
        const c = lcn + k;
        if (c >= total_clusters) break;
        if (c < edge or c >= total_clusters -| edge) continue;
        const idx: usize = @intCast(c / 8);
        const bit: u8 = @as(u8, 1) << @intCast(c % 8);
        if (bitmap[idx] & bit != 0) {
            bitmap[idx] &= ~bit;
            cleared += 1;
        }
    }
    return cleared;
}

/// Clusters of `<volume>\<name>` (FSCTL_GET_RETRIEVAL_POINTERS) removed from the copy bitmap. 0 if the file
/// does not exist or cannot be mapped (then it is simply copied, as before v2.9).
fn excludeFileClusters(volume_utf8: []const u8, name: []const u8, bitmap: []u8, total_clusters: u64, edge: u64) u64 {
    var p8: [320]u8 = undefined;
    const p = std.fmt.bufPrint(&p8, "{s}\\{s}", .{ volume_utf8, name }) catch return 0;
    var pw: [320:0]u16 = undefined;
    const pl = std.unicode.utf8ToUtf16Le(&pw, p) catch return 0;
    pw[pl] = 0;
    const FILE_READ_ATTRIBUTES: u32 = 0x80;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
    const h = CreateFileW(&pw, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | 0x4, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == INVALID_HANDLE_VALUE) return 0;
    defer _ = CloseHandle(h);
    var cleared: u64 = 0;
    var start_vcn: i64 = 0;
    var out: [64 * 1024]u8 align(8) = undefined;
    var rounds: u32 = 0;
    while (rounds < 10_000) : (rounds += 1) {
        var ret: u32 = 0;
        const ok = DeviceIoControl(h, FSCTL_GET_RETRIEVAL_POINTERS, &start_vcn, @sizeOf(i64), &out, out.len, &ret, null) != 0;
        const err = if (ok) 0 else GetLastError();
        if (!ok and err != ERROR_MORE_DATA) break;
        if (ret < 16) break;
        const n = std.mem.readInt(u32, out[0..4], .little);
        var vcn: u64 = @bitCast(std.mem.readInt(i64, out[8..16], .little));
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const off = 16 + i * 16;
            if (off + 16 > ret) break;
            const next_vcn: u64 = @bitCast(std.mem.readInt(i64, out[off..][0..8], .little));
            const lcn_i = std.mem.readInt(i64, out[off + 8 ..][0..8], .little);
            if (lcn_i >= 0 and next_vcn > vcn) {
                cleared += clearFileExtentBits(bitmap, total_clusters, edge, vcn, @intCast(lcn_i), next_vcn - vcn);
            }
            vcn = next_vcn;
        }
        if (ok) break;
        start_vcn = @intCast(vcn);
    }
    return cleared;
}

fn executeDmaVolumeClone(shadow_or_vol_utf8: []const u8, target_vol_utf8: []const u8) !void {
    var src_w: [256:0]u16 = undefined;
    const src_len = try std.unicode.utf8ToUtf16Le(&src_w, shadow_or_vol_utf8);
    src_w[src_len] = 0;

    var dst_w: [128:0]u16 = undefined;
    const dst_len = try std.unicode.utf8ToUtf16Le(&dst_w, target_vol_utf8);
    dst_w[dst_len] = 0;

    // 1. Read NTFS Volume Bitmap (Candado #1 & #2)
    const h_bmp = CreateFileW(&src_w, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h_bmp == INVALID_HANDLE_VALUE) return error.CannotOpenSourceBitmap;

    const bmp_alloc_size: u32 = 32 * 1024 * 1024;
    const bmp_raw = VirtualAlloc(null, bmp_alloc_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse {
        _ = CloseHandle(h_bmp);
        return error.OutOfMemory;
    };
    defer _ = VirtualFree(bmp_raw, 0, MEM_RELEASE);

    var starting_lcn: i64 = 0;
    var bytes_ret: u32 = 0;
    const ok_bmp = DeviceIoControl(
        h_bmp,
        FSCTL_GET_VOLUME_BITMAP,
        &starting_lcn,
        @sizeOf(i64),
        bmp_raw,
        bmp_alloc_size,
        &bytes_ret,
        null,
    );
    const bmp_err = GetLastError();

    // NVF-E026: every offset in this engine (copy, bitmap, verification) assumes 4 KiB NTFS clusters.
    // Read the real cluster size of the snapshot and refuse anything else instead of silently mis-copying.
    var ntfs_data: [128]u8 align(8) = @splat(0);
    var ntfs_ret: u32 = 0;
    const ok_ntfs = DeviceIoControl(h_bmp, FSCTL_GET_NTFS_VOLUME_DATA, null, 0, &ntfs_data, ntfs_data.len, &ntfs_ret, null);
    _ = CloseHandle(h_bmp);
    if (ok_bmp == 0 and bmp_err != ERROR_MORE_DATA) {
        return error.VolumeBitmapFailed;
    }
    if (ok_ntfs == 0 or ntfs_ret < 48) return error.NtfsVolumeDataFailed;
    const bytes_per_cluster = std.mem.readInt(u32, ntfs_data[44..48], .little);
    {
        var l: [96]u8 = undefined;
        if (std.fmt.bufPrint(&l, "NTFS origen bytes_por_cluster={d}", .{bytes_per_cluster})) |s| appendRunLog(s) else |_| {}
    }
    if (bytes_per_cluster != 4096) return error.UnsupportedClusterSize;

    const total_clusters = std.mem.readInt(u64, bmp_raw[8..16], .little);
    const bmp_bytes: usize = @intCast((total_clusters + 7) / 8);
    if (16 + bmp_bytes > bmp_alloc_size) return error.BitmapTooLarge;
    var bitmap = bmp_raw[16 .. 16 + bmp_bytes];

    // Force first and last 4096 clusters (16 MiB edges: $Boot, $MFT, backup boot sector)
    const edge: u64 = @min(@as(u64, 4096), total_clusters);
    var c: u64 = 0;
    while (c < edge) : (c += 1) {
        bitmap[@intCast(c / 8)] |= @as(u8, 1) << @intCast(c % 8);
    }
    var c_end: u64 = total_clusters -| edge;
    while (c_end < total_clusters) : (c_end += 1) {
        bitmap[@intCast(c_end / 8)] |= @as(u8, 1) << @intCast(c_end % 8);
    }

    // v2.9 (F1): pagefile.sys, hiberfil.sys and swapfile.sys are deleted from the clone right after the copy
    // and Windows recreates them; their clusters (except the first 1 MiB, so a stale hibernation header can
    // never be left behind) are not copied. Several GB less to copy and to re-read.
    {
        var skipped: u64 = 0;
        for ([_][]const u8{ "pagefile.sys", "hiberfil.sys", "swapfile.sys" }) |name| {
            skipped += excludeFileClusters(shadow_or_vol_utf8, name, bitmap, total_clusters, edge);
        }
        var l: [128]u8 = undefined;
        if (std.fmt.bufPrint(&l, "OMITIDOS pagefile/hiberfil/swapfile: {d} clusteres ({d:.2} GiB)", .{ skipped, @as(f64, @floatFromInt(skipped * 4096)) / 1073741824.0 })) |x| appendRunLog(x) else |_| {}
    }

    var allocated_clusters: u64 = 0;
    for (bitmap) |b| {
        allocated_clusters += @popCount(b);
    }
    const allocated_bytes: u64 = allocated_clusters * 4096;
    _ = g_copy_total.fetchAdd(allocated_bytes, .seq_cst);

    // 2. Open h_src and h_dst with FILE_FLAG_NO_BUFFERING for 8 MiB DMA transfer
    const h_src = CreateFileW(
        &src_w,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN,
        null,
    );
    if (h_src == INVALID_HANDLE_VALUE) return error.CannotOpenSourceDma;
    defer _ = CloseHandle(h_src);

    const h_dst = CreateFileW(
        &dst_w,
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN,
        null,
    );
    if (h_dst == INVALID_HANDLE_VALUE) return error.CannotOpenTargetDma;
    defer _ = CloseHandle(h_dst);

    var br: u32 = 0;
    _ = DeviceIoControl(h_src, FSCTL_ALLOW_EXTENDED_DASD_IO, null, 0, null, 0, &br, null);
    // NVF-E027: W: must be EXCLUSIVELY locked before the first raw write. The old code ignored the result
    // of the second LOCK and wrote anyway: if Explorer / AutoPlay / Defender / the indexer reopened the new
    // W: right after "format", NTFS could remount it and write metadata over the clone while it was copied.
    // Dismount invalidates every other handle; retry a few times, then abort BEFORE writing anything.
    var locked = DeviceIoControl(h_dst, FSCTL_LOCK_VOLUME, null, 0, null, 0, &br, null) != 0;
    var lock_attempts: u32 = 1;
    while (!locked and lock_attempts < 6) : (lock_attempts += 1) {
        _ = DeviceIoControl(h_dst, FSCTL_DISMOUNT_VOLUME, null, 0, null, 0, &br, null);
        Sleep(500);
        locked = DeviceIoControl(h_dst, FSCTL_LOCK_VOLUME, null, 0, null, 0, &br, null) != 0;
    }
    {
        var ll: [96]u8 = undefined;
        if (std.fmt.bufPrint(&ll, "LOCK destino W: bloqueado={s} intentos={d} GetLastError={d}", .{ if (locked) "si" else "NO", lock_attempts, if (locked) @as(u32, 0) else GetLastError() })) |s| appendRunLog(s) else |_| {}
    }
    if (!locked) return error.TargetLockFailed;
    // Locked + dismounted: from here only this handle can touch W:, as raw sectors.
    _ = DeviceIoControl(h_dst, FSCTL_DISMOUNT_VOLUME, null, 0, null, 0, &br, null);
    _ = DeviceIoControl(h_dst, FSCTL_ALLOW_EXTENDED_DASD_IO, null, 0, null, 0, &br, null);

    const max_run: u64 = 2048; // 8 MiB per DMA operation
    const dma_buf = VirtualAlloc(null, @intCast(max_run * 4096), MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return error.OutOfMemory;
    defer _ = VirtualFree(dma_buf, 0, MEM_RELEASE);

    // NVF-E026: digest (XxHash64) of exactly the bytes handed to WriteFile, one digest per ~segment.
    // After the copy the WHOLE target is re-read and compared against these digests. The VSS source is
    // NOT re-read for this: pagefile.sys / hiberfil.sys / swapfile.sys and the VSS diff area are not
    // Copy-on-Write protected, so two reads of the same snapshot cluster can legitimately differ
    // (that is what produced the 37 false "diferencias" of the first NVF-E025 run).
    const seg_target = digestSegmentTargetBytes(allocated_bytes);
    const digests = try std.heap.page_allocator.alloc(SegmentDigest, VERIFY_MAX_SEGMENTS);
    defer std.heap.page_allocator.free(digests);
    var seg_hasher = SegmentHasher{ .seg_target_bytes = seg_target };
    var seg_count: usize = 0;

    // NVF-E029: exact copy of the first 256 clusters as WRITTEN, so the boot region can be judged against
    // what really went to the target instead of against a second (possibly different) read of the snapshot.
    const boot_written = try std.heap.page_allocator.alloc(u8, @intCast(BOOT_CHECK_CLUSTERS * 4096));
    defer std.heap.page_allocator.free(boot_written);
    var boot_captured: u64 = 0;

    var timer_total = try std.time.Timer.start();
    var timer_report = try std.time.Timer.start();
    var copied_bytes: u64 = 0;

    var pf_bufs: [PREFETCH_SLOTS][*]u8 = undefined;
    const pf_base = allocPrefetchBuffers(@intCast(max_run * 4096), &pf_bufs) orelse return error.OutOfMemory;
    defer _ = VirtualFree(pf_base, 0, MEM_RELEASE);
    var pf = RunPrefetcher{
        .h = h_src,
        .runs = ClusterRunIter{ .bitmap = bitmap, .total_clusters = total_clusters, .max_run = max_run },
        .bufs = pf_bufs,
        .label = "lectura_origen",
    };
    const pf_thread = try std.Thread.spawn(.{}, RunPrefetcher.producer, .{&pf});
    var copy_err: ?anyerror = null;

    while (true) {
        const item = (pf.next() catch {
            copy_err = error.ReadSourceFailed;
            break;
        }) orelse break;
        const run_start = item.start;
        const run_len = item.len;
        const base_offset: i64 = @intCast(run_start * 4096);
        const byte_len: u32 = @intCast(run_len * 4096);
        var done: u32 = 0;
        while (done < byte_len) {
            const cur_off: i64 = base_offset + @as(i64, @intCast(done));
            const n_written = positionedIo(true, h_dst, cur_off, item.buf + done, byte_len - done, "escritura_destino") orelse {
                copy_err = error.WriteTargetFailed;
                break;
            };
            done += n_written;
        }
        if (copy_err != null) break;

        if (run_start < BOOT_CHECK_CLUSTERS) {
            const cap_end = @min(run_start + run_len, BOOT_CHECK_CLUSTERS);
            const cap_bytes: usize = @intCast((cap_end - run_start) * 4096);
            @memcpy(boot_written[@intCast(run_start * 4096)..][0..cap_bytes], item.buf[0..cap_bytes]);
            boot_captured += cap_end - run_start;
        }

        if (seg_hasher.feed(run_start, item.buf[0..byte_len])) |seg| {
            if (seg_count >= digests.len) {
                copy_err = error.VerifyDigestOverflow;
                break;
            }
            digests[seg_count] = seg;
            seg_count += 1;
        }
        pf.release();

        copied_bytes += done;
        _ = g_copy_done.fetchAdd(done, .seq_cst);
        if (timer_report.read() >= 400_000_000 or copied_bytes >= allocated_bytes) {
            const el_sec = @max(0.001, @as(f64, @floatFromInt(timer_total.read())) / 1_000_000_000.0);
            const mbs = (@as(f64, @floatFromInt(copied_bytes)) / (1024.0 * 1024.0)) / el_sec;
            const pct = @min(100.0, (@as(f64, @floatFromInt(copied_bytes)) * 100.0) / @as(f64, @floatFromInt(@max(@as(u64, 1), allocated_bytes))));
            const rem_mb = @as(f64, @floatFromInt(allocated_bytes -| copied_bytes)) / (1024.0 * 1024.0);
            const eta_sec = rem_mb / @max(1.0, mbs);
            const c_gib = @as(f64, @floatFromInt(copied_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const t_gib = @as(f64, @floatFromInt(allocated_bytes)) / (1024.0 * 1024.0 * 1024.0);
            const bar_pct = 20.0 + (pct * 0.32); // v2.9: copy 20 % -> 52 %, read-back 52 % -> 86 %

            var stage_buf: [128]u8 = undefined;
            var detail_buf: [256]u8 = undefined;
            const stage_s = std.fmt.bufPrint(&stage_buf, "Etapa 5/7: Clonación DMA Nativa ({d:.1}%)", .{pct}) catch "Etapa 5/7: Clonación DMA";
            const detail_s = std.fmt.bufPrint(
                &detail_buf,
                "Copiados {d:.2} / {d:.2} GiB | Velocidad DMA: {d:.1} MB/s | ETA: {d}m {d:0>2}s",
                .{ c_gib, t_gib, mbs, @as(u32, @intFromFloat(@floor(eta_sec / 60.0))), @as(u32, @intFromFloat(@mod(eta_sec, 60.0))) },
            ) catch "";
            updateProgress(stage_s, detail_s, bar_pct, mbs, false);
            timer_report.reset();
        }
    }
    pf.abort();
    pf_thread.join();
    if (copy_err) |e| return e;

    if (seg_hasher.close()) |seg| {
        if (seg_count >= digests.len) return error.VerifyDigestOverflow;
        digests[seg_count] = seg;
        seg_count += 1;
    }

    // Flush through the USB bridge. Logged (not fatal) because its behaviour on a locked + dismounted
    // volume handle is not yet proven on this hardware; the full read-back below plus chkdsk /x cover it.
    if (FlushFileBuffers(h_dst) == 0) {
        var fl: [96]u8 = undefined;
        if (std.fmt.bufPrint(&fl, "FLUSH_WARN destino FlushFileBuffers=0 GetLastError={d}", .{GetLastError()})) |s| appendRunLog(s) else |_| {}
    } else appendRunLog("FLUSH destino OK");

    g_last_copied_bytes.store(copied_bytes, .seq_cst);

    // Candado #5a (NVF-E026): re-read 100 % of the copied clusters from the target and compare them with
    // the digests of what was written. Any difference -> fatal, the disk must not be used.
    // Runs FIRST (NVF-E029) so a boot-region finding never hides the result of the full verification.
    try verifyTargetAgainstDigests(h_dst, bitmap, total_clusters, max_run, dma_buf, digests[0..seg_count], seg_target, copied_bytes, true);

    // Candado #5b (NVF-E025/E029): first 256 clusters, target AND snapshot against the exact bytes written.
    try verifyBootRegion(h_src, h_dst, bitmap, total_clusters, dma_buf, boot_written, boot_captured);

    _ = DeviceIoControl(h_dst, FSCTL_DISMOUNT_VOLUME, null, 0, null, 0, &br, null);
    _ = DeviceIoControl(h_dst, FSCTL_UNLOCK_VOLUME, null, 0, null, 0, &br, null);
}

fn isClusterAllocated(bitmap: []const u8, c: u64) bool {
    const idx: usize = @intCast(c / 8);
    if (idx >= bitmap.len) return false;
    return (bitmap[idx] & (@as(u8, 1) << @intCast(c % 8))) != 0;
}

const IO_ATTEMPTS: u32 = 4;

/// NVF-E028: positioned read/write with retries for transient USB/UASP errors (RTL9210 bridge).
/// Re-issuing the same positioned transfer is idempotent, and the full read-back (NVF-E026) checks the
/// final content anyway. Every failed attempt is logged with offset, attempt and GetLastError, so an
/// abort is always diagnosable. Reads accept a partial transfer (caller loops); writes must be complete.
fn positionedIo(comptime is_write: bool, h: HANDLE, offset: i64, buf: [*]u8, len: u32, label: []const u8) ?u32 {
    var attempt: u32 = 1;
    while (attempt <= IO_ATTEMPTS) : (attempt += 1) {
        if (attempt > 1) Sleep(250 * (attempt - 1));
        var err: u32 = 0;
        if (SetFilePointerEx(h, offset, null, 0) == 0) {
            err = GetLastError();
        } else {
            var n: u32 = 0;
            const ok = if (is_write) WriteFile(h, buf, len, &n, null) else ReadFile(h, buf, len, &n, null);
            const complete = if (is_write) n == len else n > 0;
            if (ok != 0 and complete) {
                if (attempt > 1) {
                    var rl: [128]u8 = undefined;
                    if (std.fmt.bufPrint(&rl, "IO_RETRY_OK {s} offset={d} intento={d}", .{ label, offset, attempt })) |s| appendRunLog(s) else |_| {}
                }
                return n;
            }
            err = if (ok == 0) GetLastError() else 0;
        }
        var el: [160]u8 = undefined;
        if (std.fmt.bufPrint(&el, "IO_ERROR {s} offset={d} bytes={d} intento={d}/{d} GetLastError={d}", .{ label, offset, len, attempt, IO_ATTEMPTS, err })) |s| appendRunLog(s) else |_| {}
    }
    return null;
}

fn readClusterAt(h: HANDLE, cluster: u64, buf: [*]u8) bool {
    const n = positionedIo(false, h, @intCast(cluster * 4096), buf, 4096, "lectura_verificacion") orelse return false;
    return n == 4096;
}

/// Iterates the allocated-cluster runs of an NTFS bitmap in a fixed, deterministic order
/// (at most `max_run` clusters per run, never past `total_clusters`). The copy (Etapa 5) and the
/// full read-back (NVF-E026) both use this iterator, so they visit exactly the same runs in the
/// same order and their digests are comparable.
const ClusterRunIter = struct {
    bitmap: []const u8,
    total_clusters: u64,
    max_run: u64,
    cur: u64 = 0,

    const Run = struct { start: u64, len: u64 };

    fn bitSet(self: *const ClusterRunIter, c: u64) bool {
        const idx: usize = @intCast(c / 8);
        if (idx >= self.bitmap.len) return false;
        return (self.bitmap[idx] & (@as(u8, 1) << @intCast(c % 8))) != 0;
    }

    fn next(self: *ClusterRunIter) ?Run {
        // Skip free clusters (whole zero bytes at once).
        while (self.cur < self.total_clusters) {
            const bi: usize = @intCast(self.cur / 8);
            if (bi >= self.bitmap.len) return null;
            if (self.cur % 8 == 0 and self.bitmap[bi] == 0) {
                self.cur += 8;
                continue;
            }
            if (!self.bitSet(self.cur)) {
                self.cur += 1;
                continue;
            }
            break;
        }
        if (self.cur >= self.total_clusters) return null;

        const run_start = self.cur;
        var run_len: u64 = 0;
        while (self.cur < self.total_clusters and run_len < self.max_run) {
            const idx: usize = @intCast(self.cur / 8);
            if (idx >= self.bitmap.len) break;
            if (self.cur % 8 == 0 and self.bitmap[idx] == 0xFF and (run_len + 8) <= self.max_run and self.cur + 8 <= self.total_clusters) {
                self.cur += 8;
                run_len += 8;
                continue;
            }
            if (self.bitSet(self.cur)) {
                self.cur += 1;
                run_len += 1;
            } else break;
        }
        return .{ .start = run_start, .len = run_len };
    }
};

// v2.9 (F1): read-ahead. A producer thread reads the next runs into PREFETCH_SLOTS buffers while the
// consumer writes (copy) or hashes (verification) the current one, so reading and writing overlap instead
// of alternating (v2.8 copied at 615 MB/s although the source reads at ~5 GB/s and the target at ~900 MB/s).
// Order is preserved (FIFO), so the digests are computed over exactly the same sequence as before.
const PREFETCH_SLOTS: usize = 4;

const PrefetchItem = struct { start: u64, len: u64, buf: [*]u8 };

const RunPrefetcher = struct {
    h: HANDLE,
    runs: ClusterRunIter,
    bufs: [PREFETCH_SLOTS][*]u8,
    label: []const u8,
    starts: [PREFETCH_SLOTS]u64 = @splat(0),
    lens: [PREFETCH_SLOTS]u64 = @splat(0),
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    finished: bool = false,
    failed: bool = false,
    stop: bool = false,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    fn producer(self: *RunPrefetcher) void {
        while (true) {
            self.mutex.lock();
            while (self.count == PREFETCH_SLOTS and !self.stop) self.cond.wait(&self.mutex);
            if (self.stop) {
                self.mutex.unlock();
                return;
            }
            const slot = self.tail;
            self.mutex.unlock();

            const run = self.runs.next() orelse {
                self.mutex.lock();
                self.finished = true;
                self.cond.broadcast();
                self.mutex.unlock();
                return;
            };
            const ok = readRunLabeled(self.h, run.start, @intCast(run.len * 4096), self.bufs[slot], self.label);
            self.mutex.lock();
            if (!ok) {
                self.failed = true;
                self.finished = true;
            } else {
                self.starts[slot] = run.start;
                self.lens[slot] = run.len;
                self.tail = (self.tail + 1) % PREFETCH_SLOTS;
                self.count += 1;
            }
            self.cond.broadcast();
            self.mutex.unlock();
            if (!ok) return;
        }
    }

    /// Next run in order (its data already read), null at the end, error if a read failed.
    fn next(self: *RunPrefetcher) !?PrefetchItem {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count == 0 and !self.finished) self.cond.wait(&self.mutex);
        if (self.count == 0) {
            if (self.failed) return error.PrefetchReadFailed;
            return null;
        }
        return .{ .start = self.starts[self.head], .len = self.lens[self.head], .buf = self.bufs[self.head] };
    }

    /// The consumer is done with the item returned by next(): its buffer can be refilled.
    fn release(self: *RunPrefetcher) void {
        self.mutex.lock();
        self.head = (self.head + 1) % PREFETCH_SLOTS;
        self.count -= 1;
        self.cond.broadcast();
        self.mutex.unlock();
    }

    fn abort(self: *RunPrefetcher) void {
        self.mutex.lock();
        self.stop = true;
        self.cond.broadcast();
        self.mutex.unlock();
    }
};

/// Reads `byte_len` bytes at cluster `lcn` (handles partial reads), with the I/O label for the log.
fn readRunLabeled(h: HANDLE, lcn: u64, byte_len: u32, buf: [*]u8, label: []const u8) bool {
    const base: i64 = @intCast(lcn * 4096);
    var done: u32 = 0;
    while (done < byte_len) {
        const n = positionedIo(false, h, base + @as(i64, @intCast(done)), buf + done, byte_len - done, label) orelse return false;
        if (n == 0) return false;
        done += n;
    }
    return true;
}

/// PREFETCH_SLOTS page-aligned buffers of `slot_bytes` (one VirtualAlloc). Free with VirtualFree(base).
fn allocPrefetchBuffers(slot_bytes: usize, out: *[PREFETCH_SLOTS][*]u8) ?[*]u8 {
    const base = VirtualAlloc(null, slot_bytes * PREFETCH_SLOTS, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return null;
    for (0..PREFETCH_SLOTS) |k| out[k] = base + k * slot_bytes;
    return base;
}

// NVF-E026: full read-back verification by segment digests.
const VERIFY_MAX_SEGMENTS: usize = 4096;
const VERIFY_MIN_SEGMENT_BYTES: u64 = 256 * 1024 * 1024;
const VERIFY_DIGEST_SEED: u64 = 0x4E56_4645_3032_3600; // "NVFE026"

const SegmentDigest = struct {
    first_lcn: u64,
    end_lcn: u64, // exclusive
    bytes: u64,
    hash: u64,
};

/// Segment size so that the number of segments always fits in VERIFY_MAX_SEGMENTS
/// (every closed segment holds >= target bytes, so count <= total/target + 1).
fn digestSegmentTargetBytes(total_bytes: u64) u64 {
    const per_seg = total_bytes / (VERIFY_MAX_SEGMENTS - 64) + 1;
    return @max(VERIFY_MIN_SEGMENT_BYTES, per_seg);
}

/// Streams runs (LCN + data) into XxHash64 and closes a segment every `seg_target_bytes`.
/// The LCN is part of the digest, so data written at the wrong offset is also detected.
const SegmentHasher = struct {
    seg_target_bytes: u64,
    hasher: std.hash.XxHash64 = std.hash.XxHash64.init(VERIFY_DIGEST_SEED),
    first_lcn: u64 = 0,
    end_lcn: u64 = 0,
    bytes: u64 = 0,

    fn feed(self: *SegmentHasher, lcn: u64, data: []const u8) ?SegmentDigest {
        if (self.bytes == 0) self.first_lcn = lcn;
        var lcn_le: [8]u8 = undefined;
        std.mem.writeInt(u64, &lcn_le, lcn, .little);
        self.hasher.update(lcn_le[0..]);
        self.hasher.update(data);
        self.bytes += data.len;
        self.end_lcn = lcn + data.len / 4096;
        if (self.bytes >= self.seg_target_bytes) return self.close();
        return null;
    }

    fn close(self: *SegmentHasher) ?SegmentDigest {
        if (self.bytes == 0) return null;
        const d = SegmentDigest{ .first_lcn = self.first_lcn, .end_lcn = self.end_lcn, .bytes = self.bytes, .hash = self.hasher.final() };
        self.hasher = std.hash.XxHash64.init(VERIFY_DIGEST_SEED);
        self.bytes = 0;
        return d;
    }
};

/// Reads `byte_len` bytes starting at cluster `lcn` (handles partial reads).
fn readRunAt(h: HANDLE, lcn: u64, byte_len: u32, buf: [*]u8) bool {
    const base: i64 = @intCast(lcn * 4096);
    var done: u32 = 0;
    while (done < byte_len) {
        const n = positionedIo(false, h, base + @as(i64, @intCast(done)), buf + done, byte_len - done, "lectura_verificacion") orelse return false;
        done += n;
    }
    return true;
}

const BOOT_CHECK_CLUSTERS: u64 = 256;

/// Sector 0 bytes that define the NTFS volume and must be identical: jump + OEM id + BPB + extended BPB
/// (0x00..0x53) and the 0x55AA signature (0x1FE..0x1FF).
fn ntfsBpbEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a[0..0x54], b[0..0x54]) and std.mem.eql(u8, a[0x1FE..0x200], b[0x1FE..0x200]);
}

fn logBootDiff(tag: []const u8, lcn: u64, expected: []const u8, got: []const u8) void {
    var off: usize = 0;
    while (off < expected.len and expected[off] == got[off]) : (off += 1) {}
    var ndiff: usize = 0;
    for (expected, got) |x, y| {
        if (x != y) ndiff += 1;
    }
    const hex = "0123456789abcdef";
    var he: [16]u8 = undefined;
    var hg: [16]u8 = undefined;
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        const ex: u8 = if (off + k < expected.len) expected[off + k] else 0;
        const gx: u8 = if (off + k < got.len) got[off + k] else 0;
        he[k * 2] = hex[ex >> 4];
        he[k * 2 + 1] = hex[ex & 15];
        hg[k * 2] = hex[gx >> 4];
        hg[k * 2 + 1] = hex[gx & 15];
    }
    var line: [220]u8 = undefined;
    if (std.fmt.bufPrint(&line, "{s} lcn={d} bytes_distintos={d} primer_offset=0x{x} escrito={s} leido={s}", .{ tag, lcn, ndiff, off, he[0..], hg[0..] })) |l| appendRunLog(l) else |_| {}
}

/// Candado #5b (NVF-E025 / NVF-E029): first 256 clusters, judged against the exact bytes WRITTEN.
///  - Target != written            -> fatal (the target does not hold what was sent).
///  - Snapshot != written, clusters 2..255 -> fatal (the VSS source was not stable where it must be).
///  - Snapshot != written, $Boot clusters 0..1 with the NTFS BPB of sector 0 identical -> logged, not fatal.
///    On a BitLocker volume those 8 KiB are "virtualized sectors" served by fvevol below volsnap, so a
///    second read of the snapshot can legitimately differ (2026-10-30 09:05: 1 difference at LCN 1 while
///    the 2026-10-29 22:12 run had 0). UEFI never executes that boot code, and the clone keeps exactly
///    what was read at copy time (proven by the target == written check and by NVF-E026).
fn verifyBootRegion(h_src: HANDLE, h_dst: HANDLE, bitmap: []const u8, total_clusters: u64, work: [*]u8, written: []const u8, captured: u64) !void {
    const src_buf = work; // 2 x 4 KiB inside the 8 MiB DMA buffer (page-aligned -> valid for NO_BUFFERING)
    const dst_buf = work + 4096;
    var compared: u32 = 0;
    var dst_bad: u32 = 0;
    var src_bad: u32 = 0;
    var src_tolerated: u32 = 0;
    var first_bad: u64 = 0;

    const boot_end: u64 = @min(BOOT_CHECK_CLUSTERS, total_clusters);
    var expected_allocated: u64 = 0;
    var c: u64 = 0;
    while (c < boot_end) : (c += 1) {
        if (!isClusterAllocated(bitmap, c)) continue;
        expected_allocated += 1;
        const w = written[@intCast(c * 4096)..][0..4096];
        if (!readClusterAt(h_dst, c, dst_buf) or !readClusterAt(h_src, c, src_buf)) return error.VerifyReadFailed;
        compared += 1;
        if (!std.mem.eql(u8, dst_buf[0..4096], w)) {
            if (dst_bad == 0 and src_bad == 0) first_bad = c;
            dst_bad += 1;
            logBootDiff("VERIFY_BOOT_DESTINO_DISTINTO", c, w, dst_buf[0..4096]);
        }
        if (!std.mem.eql(u8, src_buf[0..4096], w)) {
            const tolerable = c == 1 or (c == 0 and ntfsBpbEqual(src_buf[0..512], w[0..512]));
            if (tolerable) {
                src_tolerated += 1;
                logBootDiff("VERIFY_BOOT_ORIGEN_VIRTUALIZADO", c, w, src_buf[0..4096]);
            } else {
                if (dst_bad == 0 and src_bad == 0) first_bad = c;
                src_bad += 1;
                logBootDiff("VERIFY_BOOT_ORIGEN_CAMBIO", c, w, src_buf[0..4096]);
            }
        }
    }

    var line: [220]u8 = undefined;
    if (std.fmt.bufPrint(&line, "VERIFY_BOOT clusters_comparados={d} destino_distinto={d} origen_distinto={d} boot_virtualizado_tolerado={d} primer_error_lcn={d}", .{ compared, dst_bad, src_bad, src_tolerated, first_bad })) |l| appendRunLog(l) else |_| {}
    if (compared == 0 or captured < expected_allocated) return error.VerifyTooFewSamples;
    if (dst_bad > 0 or src_bad > 0) return error.VerifyMismatch;
}

/// Candado #5b (NVF-E026): re-reads 100 % of the copied runs from the target, in the same order as the copy,
/// and compares each segment digest with the digest of what was written. Any difference (data, offset,
/// number of segments or bytes) -> error.VerifyMismatch.
fn verifyTargetAgainstDigests(
    h_dst: HANDLE,
    bitmap: []const u8,
    total_clusters: u64,
    max_run: u64,
    buf: [*]u8,
    expected: []const SegmentDigest,
    seg_target_bytes: u64,
    expected_bytes: u64,
    show_progress: bool,
) !void {
    _ = buf; // v2.9: the read-ahead uses its own buffers
    var hasher = SegmentHasher{ .seg_target_bytes = seg_target_bytes };
    var pf_bufs: [PREFETCH_SLOTS][*]u8 = undefined;
    const pf_base = allocPrefetchBuffers(@intCast(max_run * 4096), &pf_bufs) orelse return error.OutOfMemory;
    defer _ = VirtualFree(pf_base, 0, MEM_RELEASE);
    var pf = RunPrefetcher{
        .h = h_dst,
        .runs = ClusterRunIter{ .bitmap = bitmap, .total_clusters = total_clusters, .max_run = max_run },
        .bufs = pf_bufs,
        .label = "lectura_verificacion",
    };
    const pf_thread = try std.Thread.spawn(.{}, RunPrefetcher.producer, .{&pf});
    defer {
        pf.abort();
        pf_thread.join();
    }
    var seg_idx: usize = 0;
    var bad_segments: usize = 0;
    var first_bad_lcn: u64 = 0;
    var first_bad_end: u64 = 0;
    var read_bytes: u64 = 0;

    var timer_total = try std.time.Timer.start();
    var timer_report = try std.time.Timer.start();

    while (true) {
        const maybe_run = pf.next() catch return error.VerifyReadFailed;
        var closed: ?SegmentDigest = null;
        if (maybe_run) |run| {
            const byte_len: u32 = @intCast(run.len * 4096);
            read_bytes += byte_len;
            if (show_progress) _ = g_verify_done.fetchAdd(byte_len, .seq_cst);
            closed = hasher.feed(run.start, run.buf[0..byte_len]);
            pf.release();
        } else {
            closed = hasher.close();
        }

        if (closed) |seg| {
            const ok = seg_idx < expected.len and
                expected[seg_idx].hash == seg.hash and
                expected[seg_idx].bytes == seg.bytes and
                expected[seg_idx].first_lcn == seg.first_lcn and
                expected[seg_idx].end_lcn == seg.end_lcn;
            if (!ok) {
                if (bad_segments == 0) {
                    first_bad_lcn = seg.first_lcn;
                    first_bad_end = seg.end_lcn;
                }
                if (bad_segments < 8) {
                    var bl: [200]u8 = undefined;
                    if (std.fmt.bufPrint(&bl, "VERIFY_BAD_SEGMENT n={d} lcn={d}..{d} ({d:.2} GiB desde el inicio)", .{
                        seg_idx,
                        seg.first_lcn,
                        seg.end_lcn,
                        @as(f64, @floatFromInt(seg.first_lcn * 4096)) / (1024.0 * 1024.0 * 1024.0),
                    })) |s| appendRunLog(s) else |_| {}
                }
                bad_segments += 1;
            }
            seg_idx += 1;
        }

        if (show_progress and (timer_report.read() >= 400_000_000 or maybe_run == null)) {
            const el_sec = @max(0.001, @as(f64, @floatFromInt(timer_total.read())) / 1_000_000_000.0);
            const mbs = (@as(f64, @floatFromInt(read_bytes)) / (1024.0 * 1024.0)) / el_sec;
            const pct = @min(100.0, (@as(f64, @floatFromInt(read_bytes)) * 100.0) / @as(f64, @floatFromInt(@max(@as(u64, 1), expected_bytes))));
            const eta_sec = (@as(f64, @floatFromInt(expected_bytes -| read_bytes)) / (1024.0 * 1024.0)) / @max(1.0, mbs);
            var stage_buf: [128]u8 = undefined;
            var detail_buf: [256]u8 = undefined;
            const stage_s = std.fmt.bufPrint(&stage_buf, "Etapa 5/7: Verificación completa de la copia ({d:.1}%)", .{pct}) catch "Etapa 5/7: Verificación completa de la copia";
            const detail_s = std.fmt.bufPrint(&detail_buf, "Releídos {d:.2} / {d:.2} GiB del destino | {d:.1} MB/s | ETA: {d}m {d:0>2}s | Segmentos con diferencias: {d}", .{
                @as(f64, @floatFromInt(read_bytes)) / (1024.0 * 1024.0 * 1024.0),
                @as(f64, @floatFromInt(expected_bytes)) / (1024.0 * 1024.0 * 1024.0),
                mbs,
                @as(u32, @intFromFloat(@floor(eta_sec / 60.0))),
                @as(u32, @intFromFloat(@mod(eta_sec, 60.0))),
                bad_segments,
            }) catch "";
            updateProgress(stage_s, detail_s, 52.0 + pct * 0.34, mbs, false);
            timer_report.reset();
        }

        if (maybe_run == null) break;
    }

    if (seg_idx != expected.len or read_bytes != expected_bytes) {
        if (bad_segments == 0) {
            first_bad_lcn = 0;
            first_bad_end = 0;
        }
        bad_segments += 1;
    }

    var line: [240]u8 = undefined;
    if (std.fmt.bufPrint(&line, "VERIFY_FULL segmentos={d}/{d} bytes={d}/{d} segmentos_con_diferencias={d} primer_error_lcn={d}..{d}", .{
        seg_idx, expected.len, read_bytes, expected_bytes, bad_segments, first_bad_lcn, first_bad_end,
    })) |l| appendRunLog(l) else |_| {}
    if (bad_segments > 0) return error.VerifyMismatch;
}

fn cloneWorkerThread() void {
    if (g_clone_running.swap(true, .seq_cst)) return;
    defer g_clone_running.store(false, .seq_cst);
    // NVF-E045: single-use confirmations belong to THIS run: capture the slow-link ack first, so
    // every exit below (even the early ones) consumes it. The g_starting defer runs before the
    // clone_running reset above (LIFO): a POST landing in between is still rejected.
    const slow_ok_run = takeSlowAck();
    defer g_starting.store(false, .seq_cst);
    // v3.0: set our flag first, then look at the benchmark's (startSuite does the mirror image), so the two
    // can never run together even if both requests arrive at the same moment.
    if (g_bench_running.load(.seq_cst)) {
        updateProgress("❌ No se empezó: hay una prueba de rendimiento en curso", "Espera a que termine o cancélala en Rendimiento y vuelve a confirmar la clonación. No se tocó ningún disco.", 0.0, 0.0, true);
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    const run_t0 = std.time.milliTimestamp(); // v3.0.1: real duration in clones.tsv (time estimate)

    // NVF-E037: archive the previous run's log (logs\runs) and start a fresh one.
    ensureLogDir();
    archivePreviousRunLog();
    g_last_copied_bytes.store(0, .seq_cst);
    resetCloneProgress();
    {
        var hdr_buf: [160]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "===== NVMeForge v{s} clone run | admin={s} =====", .{ VERSION, if (isAdmin()) "si" else "no" }) catch "===== NVMeForge clone run =====";
        appendRunLog(hdr);
    }

    // Candado #6: Prevent Sleep / USB Selective Suspend
    _ = SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED | ES_AWAYMODE_REQUIRED);
    defer _ = SetThreadExecutionState(ES_CONTINUOUS);

    _ = runLoggedCommand(alloc, "powercfg_usb", "\"C:\\Windows\\System32\\powercfg.exe\" /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0");
    _ = runLoggedCommand(alloc, "powercfg_active", "\"C:\\Windows\\System32\\powercfg.exe\" /setactive SCHEME_CURRENT");

    // NVF-E036: power and free space on C: (VSS diff area) before touching anything.
    {
        const pw = getBatteryInfo();
        var pl: [160]u8 = undefined;
        var pct_buf: [8]u8 = undefined;
        if (std.fmt.bufPrint(&pl, "ENERGIA ac={s} bateria={s} tiene_bateria={s}", .{ jsonOptBool(pw.ac), jsonOptU8(pw.pct, &pct_buf), if (pw.has_battery) "si" else "no" })) |l| appendRunLog(l) else |_| {}
        if (!powerAllowsClone(pw)) {
            updateProgress("❌ [NVF-E036] Batería baja para clonar", "El equipo está en batería y por debajo del 60 %. Una clonación dura unos 25 minutos: conecta el cargador y reintenta. No se tocó ningún disco.", 0.0, 0.0, true);
            return;
        }
        const c_w = [_:0]u16{ 'C', ':', '\\' };
        var avail: u64 = 0;
        var total: u64 = 0;
        var free: u64 = 0;
        if (GetDiskFreeSpaceExW(&c_w, &avail, &total, &free) != 0) {
            if (std.fmt.bufPrint(&pl, "ESPACIO C: libre_bytes={d} minimo={d}", .{ free, MIN_C_FREE_BYTES })) |l| appendRunLog(l) else |_| {}
            if (free < MIN_C_FREE_BYTES) {
                updateProgress("❌ [NVF-E036] Poco espacio libre en C:", "La instantánea de C: necesita al menos 10 GB libres en C: mientras dura la copia. Libera espacio y reintenta. No se tocó ningún disco.", 0.0, 0.0, true);
                return;
            }
        }
    }

    // NVF-E038 (v2.7): source = the disk that holds C:, target = the disk the user picked and confirmed.
    // Neither is assumed any more (before v2.7: source Disk 0, target Disk 1, EFI "disk 0 partition 1").
    const tdisk = targetDisk();
    const src_disk = getVolumeDiskNumber('C') orelse {
        updateProgress("❌ [NVF-E038] No se pudo saber en qué disco está C:", "Windows no informó el disco de C: (IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS). Sin conocer el disco de origen no se toca ningún disco.", 0.0, 0.0, true);
        return;
    };
    if (!validTargetChoice(tdisk, src_disk)) {
        var dt_buf: [320]u8 = undefined;
        const dt_s = if (tdisk == NO_DISK)
            "No se eligió el disco destino. Elígelo en NVMeForge (o usa --target=N) y vuelve a confirmar. No se tocó ningún disco."
        else
            (std.fmt.bufPrint(&dt_buf, "El disco {d} no puede ser el destino: es el disco de Windows (disco {d}) o no existe. No se tocó ningún disco.", .{ tdisk, src_disk }) catch "Destino no válido. No se tocó ningún disco.");
        updateProgress("❌ [NVF-E038] Disco destino no válido", dt_s, 0.0, 0.0, true);
        return;
    }
    {
        var l: [96]u8 = undefined;
        if (std.fmt.bufPrint(&l, "DISCOS origen={d} (C:) destino={d}", .{ src_disk, tdisk })) |s| appendRunLog(s) else |_| {}
    }

    const c_part_bytes = getVolumePartitionBytes('C');
    // NVF-E022: never guess the size of the Windows partition (old fallback was a hard-coded 455000 MiB).
    if (c_part_bytes == 0) {
        updateProgress("❌ [NVF-E022] No se pudo medir la partición C:", "IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS falló. Se abortó antes de tocar el disco destino.", 0.0, 0.0, true);
        return;
    }
    // v2.7: EFI and WinRE of the SOURCE disk, found by GPT partition type.
    const src_efi = findGptPartition(src_disk, &GUID_EFI, MIB);
    const src_re = findGptPartition(src_disk, &GUID_WINRE, 300 * MIB);
    var plan = planClone(c_part_bytes, if (src_efi) |p| p.bytes else 0, if (src_re) |p| p.bytes else 0);
    // v2.8: every other partition of the source (OEM/HP tools, factory recovery, data without letter).
    var extras: [MAX_EXTRAS]ExtraPart = undefined;
    const n_extras = sourceExtras(src_disk, if (src_re) |p| p.number else null, &extras);
    plan.extras_mb = extrasMb(extras[0..n_extras]);
    var n_raw: usize = 0;
    for (extras[0..n_extras]) |e| {
        if (e.copy == .raw) {
            n_raw += 1;
            _ = g_copy_total.fetchAdd(e.entry.bytes, .seq_cst);
        }
        var l: [200]u8 = undefined;
        var nb: [128]u8 = undefined;
        if (std.fmt.bufPrint(&l, "PARTICION EXTRA origen {d}: offset={d} bytes={d} tipo={s} nombre=\"{s}\" atributos=0x{x:0>16} -> {s}", .{
            e.entry.number, e.entry.offset, e.entry.bytes, gptKind(&e.entry.type_guid), e.entry.nameUtf8(&nb), e.entry.attributes, if (e.copy == .raw) "se copia sector por sector" else "NO se copia (tiene letra, en uso)",
        })) |x| appendRunLog(x) else |_| {}
    }
    const need_bytes = plan.requiredBytes();
    {
        const efi_n: ?u32 = if (src_efi) |p| p.number else null;
        const re_n: ?u32 = if (src_re) |p| p.number else null;
        var l: [256]u8 = undefined;
        if (std.fmt.bufPrint(&l, "PLAN destino: EFI {d} MiB + MSR 16 MiB + Windows {d} MiB + WinRE {d} MiB = necesita {d} bytes | origen EFI=particion {?d} WinRE=particion {?d}", .{
            plan.efi_mb, plan.windows_mb, plan.recovery_mb, need_bytes, efi_n, re_n,
        })) |s| appendRunLog(s) else |_| {}
    }

    // Etapa 1/7: target size + real read speed through its bus
    updateProgress("Etapa 1/7: Verificando el disco destino", "Midiendo la velocidad real de lectura del disco destino...", 8.0, 0.0, false);
    var dst_path_buf: [64]u8 = undefined;
    const dst_path = std.fmt.bufPrint(&dst_path_buf, "\\\\.\\PhysicalDrive{d}", .{tdisk}) catch return;
    const dst_bytes = getVolumeLengthBytes(dst_path);
    if (dst_bytes < need_bytes) {
        var st_buf: [160]u8 = undefined;
        var dt_buf: [400]u8 = undefined;
        const st_s = std.fmt.bufPrint(&st_buf, "❌ [NVF-E001] El disco {d} no sirve como destino", .{tdisk}) catch "❌ [NVF-E001] El disco destino no sirve";
        const dt_s = if (dst_bytes == 0)
            (std.fmt.bufPrint(&dt_buf, "No se pudo leer el tamaño del disco {d}. Revisa que siga conectado y vuelve a intentarlo. No se tocó ningún disco.", .{tdisk}) catch "")
        else
            (std.fmt.bufPrint(&dt_buf, "Mide {d:.1} GB y el clon necesita {d:.1} GB (C: mide {d:.1} GB, más arranque y recuperación). Usa un disco más grande. No se tocó ningún disco.", .{ decGB(dst_bytes), decGB(need_bytes), decGB(c_part_bytes) }) catch "");
        updateProgress(st_s, dt_s, 0.0, 0.0, true);
        return;
    }

    // NVF-E040: a raw copy keeps the file systems' sector size; both disks must use the same logical sector.
    {
        const ss_src = diskLogicalSectorBytes(src_disk);
        const ss_dst = diskLogicalSectorBytes(tdisk);
        var l: [96]u8 = undefined;
        if (std.fmt.bufPrint(&l, "SECTOR origen={?d} destino={?d} bytes", .{ ss_src, ss_dst })) |x| appendRunLog(x) else |_| {}
        if (ss_src != null and ss_dst != null and ss_src.? != ss_dst.?) {
            var dt: [256]u8 = undefined;
            const dts = std.fmt.bufPrint(&dt, "El disco de origen usa sectores de {d} bytes y el destino de {d}: Windows no podría abrir C: en el disco nuevo. Usa otro disco. No se tocó ningún disco.", .{ ss_src.?, ss_dst.? }) catch "Tamaño de sector distinto. No se tocó ningún disco.";
            updateProgress("❌ [NVF-E040] Los discos usan distinto tamaño de sector", dts, 0.0, 0.0, true);
            return;
        }
    }

    const raw_mbs = benchmarkPhysicalDriveDma(tdisk);
    const bench_mbs: f64 = if (raw_mbs > 0.0) raw_mbs else 0.0; // v2.4: never an invented speed
    // NVF-E045 (v3.1.1): a slow link is confirmable, not fatal. The first attempt stops with the
    // measured speed and the real ETA; the second attempt (slow_ok=1 / --slow-ok, single-use)
    // logs the explicit confirmation and follows the normal flow (100 % XxHash64 check unchanged).
    if (slowLinkNeedsConfirm(raw_mbs)) {
        if (slow_ok_run) {
            var l: [256]u8 = undefined;
            if (std.fmt.bufPrint(&l, "LENTO enlace {d:.1} MB/s confirmado por el usuario (una sola vez) -> CONTINUA con tiempo estimado largo", .{raw_mbs})) |s| appendRunLog(s) else |_| {}
        } else {
            var dt_buf: [512]u8 = undefined;
            var dt_s: []const u8 = "";
            if (slowLinkEtaSec(need_bytes, raw_mbs)) |eta| {
                const m: u64 = eta / 60;
                const s: u64 = eta % 60;
                dt_s = std.fmt.bufPrint(&dt_buf, "Se midió {d:.1} MB/s en el disco destino (enlace lento, ritmo de USB 2.0). Con ese ritmo, copiar {d:.1} GB y releer el 100 % tardaría alrededor de ETA: {d}m {d:0>2}s (pasos finales incluidos). Si tu equipo no tiene USB 3, puedes continuar: vuelve a confirmar marcando la casilla de enlace lento (cargador conectado, sin suspender ni hibernar, sin uso intensivo por la instantánea VSS larga). No se tocó ningún disco.", .{ raw_mbs, decGB(need_bytes), m, s }) catch "Enlace lento: menos de 60 MB/s. No se tocó ningún disco.";
            } else {
                dt_s = "Se midió un enlace lento (menos de 60 MB/s). No se tocó ningún disco.";
            }
            updateProgress("❌ [NVF-E010] Enlace lento: el destino va a velocidad de USB 2.0", dt_s, 0.0, raw_mbs, true);
            return;
        }
    }

    // NVF-E023: physical identity of target vs source. Disk numbers can change after a USB re-plug, so
    // the target must be a different physical device than the one hosting C:, and is logged/shown by serial.
    const id_dst = getDiskIdentity(tdisk) orelse {
        updateProgress("❌ [NVF-E023] No se pudo identificar el disco destino", "IOCTL_STORAGE_QUERY_PROPERTY falló. Se abortó antes de borrar nada.", 0.0, bench_mbs, true);
        return;
    };
    const id_src = getDiskIdentity(src_disk);
    {
        var l: [320]u8 = undefined;
        if (std.fmt.bufPrint(&l, "IDENTIDAD destino Disco {d}: modelo=\"{s}\" serie=\"{s}\" bus={s} | origen Disco {d}: modelo=\"{s}\" serie=\"{s}\"", .{
            tdisk,                                     id_dst.product(),                          id_dst.serial(), busTypeName(id_dst.bus), src_disk,
            if (id_src) |s| s.product() else "?", if (id_src) |s| s.serial() else "?",
        })) |s| appendRunLog(s) else |_| {}
    }
    if (id_dst.product_len == 0 or (id_src != null and id_dst.serial_len > 0 and std.mem.eql(u8, id_dst.serial(), id_src.?.serial()))) {
        updateProgress("❌ [NVF-E023] El disco destino no es un dispositivo distinto del origen", "Identidad física ambigua (modelo vacío o misma serie que el disco de C:). Se abortó antes de borrar nada.", 0.0, bench_mbs, true);
        return;
    }

    // NVF-E035: the disk at the chosen number must be exactly the one the user confirmed (model + size).
    {
        g_expect_mutex.lock();
        const has = g_expect_set;
        const eb = g_expect_bytes;
        var em_buf: [96]u8 = undefined;
        const em_len = g_expect_model_len;
        @memcpy(em_buf[0..em_len], g_expect_model_buf[0..em_len]);
        g_expect_set = false; // one confirmation = one run
        g_expect_mutex.unlock();
        var l: [320]u8 = undefined;
        if (has) {
            const ok = targetMatchesConfirmed(id_dst.product(), dst_bytes, em_buf[0..em_len], eb);
            if (std.fmt.bufPrint(&l, "CONFIRMADO por el usuario: modelo=\"{s}\" bytes={d} | ahora en Disco {d}: modelo=\"{s}\" bytes={d} -> {s}", .{ em_buf[0..em_len], eb, tdisk, id_dst.product(), dst_bytes, if (ok) "COINCIDE" else "NO COINCIDE" })) |s2| appendRunLog(s2) else |_| {}
            if (!ok) {
                var dt_buf: [320]u8 = undefined;
                const dt_s = std.fmt.bufPrint(&dt_buf, "El disco {d} cambió entre la confirmación y el inicio (otro disco conectado o el adaptador se reconectó). Revisa los discos y vuelve a confirmar. No se tocó ningún disco.", .{tdisk}) catch "El disco destino cambió. No se tocó ningún disco.";
                updateProgress("❌ [NVF-E035] El disco conectado no es el que confirmaste", dt_s, 0.0, bench_mbs, true);
                return;
            }
        } else {
            appendRunLog("CONFIRMADO: sin confirmación de identidad desde la interfaz (modo --clone --target=N por línea de comandos)");
        }
    }

    // NVF-E031: never wipe a finished clone by accident.
    if (findCloneMarker(tdisk, src_disk)) |mk| {
        var ml: [128]u8 = undefined;
        if (std.fmt.bufPrint(&ml, "ABORTADO NVF-E031: {c}: del disco destino ya contiene NVMeForge_CLON_OK.txt", .{mk.letter})) |x| appendRunLog(x) else |_| {}
        var dt: [320]u8 = undefined;
        const dts = std.fmt.bufPrint(&dt, "Se encontró {c}:\\NVMeForge_CLON_OK.txt: ese disco ya está listo para instalar y NO se tocó. Si de verdad quieres volver a clonar, borra ese archivo y reintenta.", .{mk.letter}) catch "Ese disco ya tiene la marca de clon terminado y NO se tocó.";
        updateProgress("❌ [NVF-E031] Ese disco ya tiene un clon terminado", dts, 0.0, bench_mbs, true);
        return;
    }

    // Etapa 2/7: Live VSS Snapshot of C:\
    updateProgress("Etapa 2/7: Instantánea VSS en Caliente", "Congelando estado atómico de C:\\ mediante Volume Shadow Copy...", 12.0, bench_mbs, false);
    var vss_buf: [256]u8 = undefined;
    // NVF-E022: NO fallback to the live \\.\C: — copying a mounted, changing NTFS volume produces an
    // inconsistent (corrupt) clone. Without a frozen snapshot the clone is aborted.
    const vss_dev = createVssSnapshotInvisible(alloc, &vss_buf) orelse {
        updateProgress("❌ [NVF-E022] No se pudo crear la instantánea VSS de C:", "Sin instantánea congelada la copia sería inconsistente. Revise el servicio 'Instantáneas de volumen' (VSS) y el espacio libre en C:. Log: %TEMP%\\NVMeForge\\logs\\vss_create.log", 0.0, bench_mbs, true);
        return;
    };
    defer deleteVssSnapshot(alloc); // NVF-E017: never leave persistent snapshots behind
    {
        var vline: [320]u8 = undefined;
        if (std.fmt.bufPrint(&vline, "VSS origen = {s}", .{vss_dev})) |l| appendRunLog(l) else |_| {}
    }
    // v2.6: NTFS journal position of C: right after the snapshot, to count later what changed since this clone.
    {
        var u: ?UsnState = null;
        if (openVolumeForJournal('C')) |hv| {
            u = queryUsnJournal(hv);
            _ = CloseHandle(hv);
        }
        g_clone_usn_mutex.lock();
        g_clone_usn = u;
        g_clone_usn_mutex.unlock();
        var ul: [128]u8 = undefined;
        if (u) |x| {
            if (std.fmt.bufPrint(&ul, "USN C: diario={d} posicion={d}", .{ x.journal_id, x.next_usn })) |l| appendRunLog(l) else |_| {}
        } else appendRunLog("USN C: no disponible (no se podrán contar los cambios posteriores a este clon)");
    }

    // Etapa 3/7: Preflight de seguridad (NVF-E008 / NVF-E009) antes de tocar el disco destino
    updateProgress("Etapa 3/7: Verificación de seguridad del disco destino", "Confirmando que C: no vive en el disco destino y eligiendo letras libres...", 15.0, bench_mbs, false);
    if (getVolumeDiskNumber('C')) |c_disk| {
        if (c_disk == tdisk or c_disk != src_disk) {
            updateProgress("❌ [NVF-E008] Bloqueo de seguridad: C: está en el disco destino", "El disco destino contiene el Windows en ejecución (o los números de disco cambiaron durante la preparación). Se abortó antes de borrar nada.", 0.0, bench_mbs, true);
            return;
        }
    }
    // NVF-E030: free every letter left on the target by an earlier run (that disk is wiped right after).
    // v3.0.1 (NVF-E044): remember them first, so a run that stops before the disk is wiped gives them back.
    var saved_letters = SavedLetters{};
    saved_letters.capture(tdisk);
    releaseTargetDiskLetters(alloc, tdisk, true);
    Sleep(1000);
    // NVF-E039: orphan letters (their device no longer exists) among the preferred ones are freed first, so
    // the usual S, W, R, Z, Y are kept whenever possible.
    for (RESERVED_LETTERS) |letter| {
        if (!isDriveLetterInUse(letter)) continue;
        var tb: [512:0]u16 = undefined;
        if (orphanLetterTarget(letter, &tb) != null) _ = freeOrphanLetter(letter);
    }
    // F4: choose free letters for the 5 roles; a letter used by another device is simply not chosen.
    {
        const chosen = chooseCloneLetters(GetLogicalDrives(), RESERVED_LETTERS) orelse {
            saved_letters.restore();
            updateProgress("❌ [NVF-E009] No hay letras de unidad libres", "NVMeForge necesita 5 letras libres para trabajar y casi todas están ocupadas. Expulsa algunas unidades USB o de red y reintenta. No se tocó ningún disco.", 0.0, bench_mbs, true);
            return;
        };
        g_letters = chosen;
        var ll: [160]u8 = undefined;
        if (std.fmt.bufPrint(&ll, "LETRAS elegidas: EFI={c}: Windows={c}: WinRE={c}: EFI_origen={c}: WinRE_origen={c}:", .{ chosen[0], chosen[1], chosen[2], chosen[3], chosen[4] })) |x| appendRunLog(x) else |_| {}
    }

    // Etapa 4/7: Initialize 4K-Aligned GPT Table on the target via native System32 diskpart.exe
    // NVF-E007: NO "select volume X" here — on a RAW/empty disk that command fails and diskpart /s
    // aborts the entire script (select has no noerr). "clean" already frees any letter on the target.
    // NVF-E015: "convert gpt" already creates the 16 MiB MSR (partition 1) on this Windows build;
    // an explicit "create partition msr" produced a duplicate MSR (layout MSR, EFI, MSR, Windows).
    {
        var d4: [160]u8 = undefined;
        const d4s = std.fmt.bufPrint(&d4, "Creando particiones EFI ({d} MiB), MSR (16 MiB) y Windows W: en el disco {d}...", .{ plan.efi_mb, tdisk }) catch "Creando particiones EFI, MSR y Windows W:...";
        updateProgress("Etapa 4/7: Inicializando tabla GPT en el disco destino", d4s, 18.0, bench_mbs, false);
    }
    var dp_init_buf: [1024]u8 = undefined;
    const dp_init = buildInitScript(&dp_init_buf, tdisk, plan) orelse {
        saved_letters.restore();
        updateProgress("❌ [NVF-E007] No se pudo preparar el guion de diskpart", "Error interno al armar el guion de particiones. No se tocó ningún disco.", 0.0, bench_mbs, true);
        return;
    };

    const dp_rc = runDiskpartScript(alloc, "dp_init", dp_init);
    // NVF-E030: from here on S: (and later R:) belong to the target disk; release them on ANY exit.
    var letters_released = false;
    defer if (!letters_released) releaseCloneLetters(alloc, tdisk);
    if (dp_rc != 0) {
        // If diskpart stopped before "clean", the old volumes still exist: give their letters back. The clone's
        // own S:/R: are released first (review 3.0.1 #1), so the deferred release cannot undo the restore.
        releaseCloneLetters(alloc, tdisk);
        letters_released = true;
        saved_letters.restore();
        var tail_buf: [320]u8 = undefined;
        const tail = readLogTail("dp_init", 2, &tail_buf);
        var st_buf: [160]u8 = undefined;
        var dt_buf: [640]u8 = undefined;
        const st_s = std.fmt.bufPrint(&st_buf, "❌ [NVF-E007] Error inicializando la tabla GPT del disco {d} (diskpart código {d})", .{ tdisk, dp_rc }) catch "❌ [NVF-E007] Error inicializando la tabla GPT del disco destino";
        const dt_s = std.fmt.bufPrint(&dt_buf, "diskpart: {s} — Log: %TEMP%\\NVMeForge\\logs\\dp_init.log", .{tail}) catch "Ver %TEMP%\\NVMeForge\\logs\\dp_init.log";
        updateProgress(st_s, dt_s, 0.0, bench_mbs, true);
        return;
    }
    Sleep(2000);

    // NVF-E024: before writing raw sectors, prove that W: really is the new partition on the target
    // disk and that it is large enough for the source volume.
    {
        const w_disk = getVolumeDiskNumber(letterOf(LETTER_WIN));
        const w_bytes = getVolumePartitionBytes(letterOf(LETTER_WIN));
        var l: [160]u8 = undefined;
        if (std.fmt.bufPrint(&l, "VERIFY W: disco={?d} bytes={d} (origen C: bytes={d})", .{ w_disk, w_bytes, c_part_bytes })) |s| appendRunLog(s) else |_| {}
        if (w_disk == null or w_disk.? != tdisk or w_bytes < c_part_bytes) {
            updateProgress("❌ [NVF-E024] W: no es la partición nueva del disco destino", "La letra W: no apunta al disco destino o es más pequeña que C:. Se abortó antes de escribir datos.", 0.0, bench_mbs, true);
            return;
        }
    }

    // Etapa 5/7: 8 MiB DMA Volume Clone (Candados #1 & #2) + verificación por lectura (Candado #5)
    var wdev_buf: [16]u8 = undefined;
    executeDmaVolumeClone(vss_dev, L(&wdev_buf, "\\\\.\\@W:")) catch |err| {
        var dt_buf: [320]u8 = undefined;
        const is_verify = err == error.VerifyMismatch or err == error.VerifyReadFailed or err == error.VerifyTooFewSamples or err == error.VerifyDigestOverflow;
        const is_cluster = err == error.UnsupportedClusterSize or err == error.NtfsVolumeDataFailed;
        const is_lock = err == error.TargetLockFailed;
        const hint: []const u8 = if (is_verify)
            "La copia NO coincide con lo escrito: NO use este disco."
        else if (is_cluster)
            "El volumen de origen no usa clústeres NTFS de 4 KiB (o no se pudo leer): no se escribió nada del sistema."
        else if (is_lock)
            "Otro programa tiene abierto W: (Explorador, AutoPlay, antivirus). Cierre esas ventanas y reintente; no se escribió nada del clon."
        else
            "Verifique la conexión del disco destino: adaptador, cable y puerto USB (líneas IO_ERROR en el log).";
        const dt_s = std.fmt.bufPrint(&dt_buf, "Causa: {s}. {s} Log: %TEMP%\\NVMeForge\\logs\\clone_run.log", .{ @errorName(err), hint }) catch "Ver %TEMP%\\NVMeForge\\logs\\clone_run.log";
        const title: []const u8 = if (is_verify)
            "❌ [NVF-E026] Verificación completa de la copia FALLÓ"
        else if (is_cluster)
            "❌ [NVF-E026] Tamaño de clúster NTFS no soportado"
        else if (is_lock)
            "❌ [NVF-E027] No se pudo bloquear W: en exclusiva"
        else
            "❌ [NVF-E011] Error en Transferencia DMA de Bloques NTFS";
        updateProgress(title, dt_s, 0.0, bench_mbs, true);
        return;
    };
    appendRunLog("STEP dma_copy_verify -> OK");

    // Etapa 6/7: ChkDsk + extend to the whole target + Candado #3 (MountedDevices & Cold Boot)
    var warn = StepWarnings{};
    updateProgress("Etapa 6/7: ChkDsk /f /x del volumen clonado W:", "Verificando y reparando NTFS en W: (desmontaje forzado, sin preguntas)...", 86.0, bench_mbs, false);
    // NVF-E016: /x forces the dismount up-front, so chkdsk never asks "(S/N)" and never hangs.
    // chkdsk: 0 = sin errores, 1 = errores corregidos; >= 2 o watchdog = advertencia.
    var cb1: [128]u8 = undefined;
    warn.check("chkdsk_fix", runLoggedCommandEx(alloc, "chkdsk_fix", L(&cb1, "\"C:\\Windows\\System32\\chkdsk.exe\" @W: /f /x"), 300, 2700) <= 1);

    {
        var d6: [160]u8 = undefined;
        const d6s = std.fmt.bufPrint(&d6, "diskpart: extend W:, reservar {d} MiB al final y crear Recovery R:...", .{plan.recovery_mb}) catch "diskpart: extend W: y crear Recovery R:...";
        updateProgress("Etapa 6/7: Ampliando Windows a todo el disco + partición de recuperación", d6s, 88.0, bench_mbs, false);
    }
    var dp_expand_buf: [4096]u8 = undefined;
    var raw_extras: [MAX_EXTRAS]ExtraPart = undefined;
    var nre: usize = 0;
    for (extras[0..n_extras]) |e| {
        if (e.copy == .raw) {
            raw_extras[nre] = e;
            nre += 1;
        }
    }
    // v3.0.1 (review #2): bytes this run had to copy, measured like the UI does (used space of C: plus the
    // extra partitions copied raw), so the next time estimate compares like with like.
    var basis_bytes: u64 = 0;
    {
        const c_w = [_:0]u16{ 'C', ':', '\\' };
        var total: u64 = 0;
        var free: u64 = 0;
        if (GetDiskFreeSpaceExW(&c_w, null, &total, &free) != 0 and total >= free) basis_bytes = total - free;
        for (raw_extras[0..nre]) |e| basis_bytes += e.entry.bytes;
    }
    var dp_ok = false;
    if (buildExpandScript(&dp_expand_buf, plan, raw_extras[0..nre])) |dp_expand| {
        dp_ok = runDiskpartScript(alloc, "dp_expand", dp_expand) == 0;
    }
    warn.check("dp_expand", dp_ok);
    g_tail_done.store(true, .seq_cst);

    // v2.8: copy every extra partition sector by sector into the partition created for it, then re-read 100 %.
    // Review v2.8 #2/#1/#9: only after a complete dp_expand, with R: found, a strict mapping and known sector sizes.
    if (nre > 0) blk: {
        if (!dp_ok) {
            appendRunLog("NVF-E041: dp_expand no termino bien; no se escribe nada en particiones extra");
            warn.check("particiones_extra", false);
            break :blk;
        }
        if (diskLogicalSectorBytes(src_disk) == null or diskLogicalSectorBytes(tdisk) == null) {
            appendRunLog("NVF-E041: tamano de sector desconocido; no se copian particiones extra");
            warn.check("particiones_extra", false);
            break :blk;
        }
        Sleep(1500);
        var tgt: [32]GptEntry = undefined;
        const nt = readLayoutEntries(tdisk, &tgt);
        const r_ext = volumeExtent(letterOf(LETTER_REC));
        var nums: [MAX_EXTRAS]u32 = undefined;
        if (r_ext == null or r_ext.?.disk != tdisk or !mapExtrasToTarget(tgt[0..nt], r_ext.?.offset, raw_extras[0..nre], nums[0..nre])) {
            appendRunLog("ABORTADO NVF-E041: las particiones despues de R: en el destino no coinciden exactamente con las extras; no se escribio nada en ellas");
            warn.check("particiones_extra", false);
            break :blk;
        }
        // No letter on the new extras (by disk + partition number, never by volume focus).
        for (nums[0..nre], 0..) |num, k| {
            var sb: [128]u8 = undefined;
            if (std.fmt.bufPrint(&sb, "select disk {d}\r\nselect partition {d}\r\nremove all noerr\r\nexit\r\n", .{ tdisk, num })) |sc| {
                var nm: [40]u8 = undefined;
                _ = runDiskpartScript(alloc, std.fmt.bufPrint(&nm, "dp_extra_noletter_{d}", .{k + 1}) catch "dp_extra_noletter", sc);
            } else |_| {}
        }
        if (!isLetterOnDisk(letterOf(LETTER_WIN), tdisk) or !isLetterOnDisk(letterOf(LETTER_REC), tdisk)) {
            appendRunLog("NVF-E041: W: o R: dejaron de estar en el disco destino; no se copian particiones extra");
            warn.check("particiones_extra", false);
            break :blk;
        }
        for (raw_extras[0..nre], 0..) |e, k| {
            var nm: [48]u8 = undefined;
            const step = std.fmt.bufPrint(&nm, "particion_extra_{d}", .{e.entry.number}) catch "particion_extra";
            if (copyExtraPartition(alloc, src_disk, e.entry, tdisk, nums[k], k, nre, bench_mbs)) |_| {
                // GPT attributes only after the copy (a read-only bit would have blocked it).
                var sb: [160]u8 = undefined;
                var ok_attr = true;
                if (std.fmt.bufPrint(&sb, "select disk {d}\r\nselect partition {d}\r\ngpt attributes=0x{x:0>16}\r\nexit\r\n", .{ tdisk, nums[k], e.entry.attributes })) |sc| {
                    var an: [40]u8 = undefined;
                    ok_attr = runDiskpartScript(alloc, std.fmt.bufPrint(&an, "dp_extra_attr_{d}", .{k + 1}) catch "dp_extra_attr", sc) == 0;
                } else |_| {
                    ok_attr = false;
                }
                warn.check(step, ok_attr);
            } else |err| {
                var l: [128]u8 = undefined;
                if (std.fmt.bufPrint(&l, "NVF-E041 particion extra {d}: {s}", .{ e.entry.number, @errorName(err) })) |x| appendRunLog(x) else |_| {}
                warn.check(step, false);
            }
        }
    }

    {
        // v2.9: their bodies were not copied (F1), so they must be gone from the clone.
        var fb: [64]u8 = undefined;
        if (!roleOnDisk(LETTER_WIN, tdisk, "borrar pagefile")) {
            updateProgress("❌ [NVF-E024] La partición de Windows del destino perdió su letra", "Otra unidad tomó la letra durante la copia. La copia de Windows ya está verificada, pero no se terminó el arranque. Desconecta otras unidades USB y vuelve a clonar.", 0.0, bench_mbs, true);
            return;
        }
        var gone = deleteSystemTempFileW(L(&fb, "@W:\\pagefile.sys"));
        gone = deleteSystemTempFileW(L(&fb, "@W:\\hiberfil.sys")) and gone;
        gone = deleteSystemTempFileW(L(&fb, "@W:\\swapfile.sys")) and gone;
        warn.check("borrar_pagefile_hiberfil", gone);
    }

    // v3.0.1: TRIM of the whole new Windows volume (defrag /L = "Optimizar" in Windows). The disk may hold
    // blocks of an earlier clone that the controller still thinks are in use; this frees them so the new
    // disk starts at full write speed. Optional: a USB bridge that does not pass TRIM only gets a log line.
    if (roleOnDisk(LETTER_WIN, tdisk, "trim")) {
        updateProgress("Etapa 6/7: Optimizando el disco nuevo (TRIM)", "Avisando al disco qué bloques quedaron libres, como \"Optimizar unidades\" de Windows...", 94.5, bench_mbs, false);
        var cbt: [96]u8 = undefined;
        const trc = runLoggedCommandEx(alloc, "trim_clon", L(&cbt, "\"C:\\Windows\\System32\\defrag.exe\" @W: /L"), 600, 900);
        var lt: [220]u8 = undefined;
        if (std.fmt.bufPrint(&lt, "TRIM del clon (defrag {c}: /L) rc={d} {s}", .{ letterOf(LETTER_WIN), trc, if (trc == 0) "-> OK" else "-> no disponible por este adaptador o falló (no afecta al clon; Windows lo hará en su optimización semanal)" })) |x| appendRunLog(x) else |_| {}
    }

    updateProgress("Etapa 6/7: Candado #3 — Registro offline (MountedDevices + Cold Boot)", "reg load W:\\Windows\\System32\\config\\SYSTEM...", 95.0, bench_mbs, false);
    var cb2: [256]u8 = undefined;
    const reg_ok = runLoggedCommandEx(alloc, "reg_load", L(&cb2, "\"C:\\Windows\\System32\\reg.exe\" load HKLM\\CloneSys @W:\\Windows\\System32\\config\\SYSTEM"), 60, 120) == 0;
    warn.check("reg_load", reg_ok);
    if (reg_ok) {
        // reg delete returns 1 when the value does not exist: not an error.
        _ = runLoggedCommandEx(alloc, "reg_del_c", "\"C:\\Windows\\System32\\reg.exe\" delete \"HKLM\\CloneSys\\MountedDevices\" /v \"\\DosDevices\\C:\" /f", 60, 120);
        var cb3: [256]u8 = undefined;
        _ = runLoggedCommandEx(alloc, "reg_del_w", L(&cb3, "\"C:\\Windows\\System32\\reg.exe\" delete \"HKLM\\CloneSys\\MountedDevices\" /v \"\\DosDevices\\@W:\" /f"), 60, 120);
        warn.check("reg_hiberboot", runLoggedCommandEx(alloc, "reg_hiberboot", "\"C:\\Windows\\System32\\reg.exe\" add \"HKLM\\CloneSys\\ControlSet001\\Control\\Session Manager\\Power\" /v HiberbootEnabled /t REG_DWORD /d 0 /f", 60, 120) == 0);
        warn.check("reg_unload", runLoggedCommandEx(alloc, "reg_unload", "\"C:\\Windows\\System32\\reg.exe\" unload HKLM\\CloneSys", 60, 120) == 0);
    }

    // Etapa 7/7: Candados #4 y #5 — UEFI BCD + carpetas del fabricante en la EFI + WinRE + Checksum
    updateProgress("Etapa 7/7: Candados #4 y #5 — Arranque UEFI + EFI del fabricante + WinRE", "Instalando el arranque UEFI (bcdboot), conservando las carpetas del fabricante de la EFI de origen y WinRE...", 97.0, bench_mbs, false);

    // v2.7: the source EFI is found by GPT type on the disk of C: (before: "disk 0 partition 1" and only \EFI\HP).
    // Every vendor folder (HP, Dell, Lenovo, ...) is kept; \EFI\Microsoft and \EFI\Boot are written by bcdboot.
    if (src_efi) |efi| {
        var dpz_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&dpz_buf, "select disk {d}\r\nselect partition {d}\r\nassign letter={c} noerr\r\nexit\r\n", .{ src_disk, efi.number, letterOf(LETTER_SRC_EFI) })) |dpz| {
            _ = runDiskpartScript(alloc, "dp_z_mount", dpz);
        } else |_| {}
        // robocopy: 0..7 = éxito, >= 8 = fallo.
        var cb4: [256]u8 = undefined;
        if (!roleOnDisk(LETTER_SRC_EFI, src_disk, "copia EFI del fabricante") or !roleOnDisk(LETTER_EFI, tdisk, "copia EFI del fabricante")) {
            warn.check("robocopy_efi_vendor", false);
        } else warn.check("robocopy_efi_vendor", runLoggedCommand(alloc, "robocopy_efi_vendor", L(&cb4, "\"C:\\Windows\\System32\\Robocopy.exe\" @Z:\\EFI @S:\\EFI /E /XD @Z:\\EFI\\Microsoft @Z:\\EFI\\Boot /R:1 /W:1 /NFL /NDL /NJH /NJS")) < 8);
        var dpzu_buf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&dpzu_buf, "select disk {d}\r\nselect partition {d}\r\nremove letter={c} noerr\r\nexit\r\n", .{ src_disk, efi.number, letterOf(LETTER_SRC_EFI) })) |dpzu| {
            _ = runDiskpartScript(alloc, "dp_z_unmount", dpzu);
        } else |_| {}
    } else {
        appendRunLog("EFI origen: el disco de C: no tiene partición EFI (arranque BIOS/MBR o EFI en otro disco); solo se instala el arranque UEFI nuevo");
    }

    // NVF-E018: bcdboot is the ONLY thing that makes the clone bootable -> hard failure.
    var cb5: [160]u8 = undefined;
    if (!roleOnDisk(LETTER_EFI, tdisk, "bcdboot") or !roleOnDisk(LETTER_WIN, tdisk, "bcdboot")) {
        updateProgress("❌ [NVF-E018] El arranque no se instaló: una letra del destino cambió", "Otra unidad tomó una letra del disco nuevo durante la copia. No se escribió nada en ella. Desconecta otras unidades USB y vuelve a clonar.", 97.0, bench_mbs, true);
        return;
    }
    const bcd_rc = runLoggedCommandEx(alloc, "bcdboot", L(&cb5, "\"C:\\Windows\\System32\\bcdboot.exe\" @W:\\Windows /s @S: /f UEFI"), 120, 300);
    if (bcd_rc != 0) {
        var tail_buf: [320]u8 = undefined;
        const tail = readLogTail("bcdboot", 2, &tail_buf);
        var dt_buf: [640]u8 = undefined;
        const dt_s = std.fmt.bufPrint(&dt_buf, "bcdboot código {d}: {s} — El disco nuevo NO arrancará todavía. Log: %TEMP%\\NVMeForge\\logs\\bcdboot.log", .{ bcd_rc, tail }) catch "Ver %TEMP%\\NVMeForge\\logs\\bcdboot.log";
        updateProgress("❌ [NVF-E018] bcdboot falló: arranque UEFI no instalado en S:", dt_s, 97.0, bench_mbs, true);
        return;
    }
    // NVF-E020: Winre.wim lives in the WinRE partition of the source disk while WinRE is enabled (not in
    // C:\Windows\System32\Recovery). Copy it from there (fallback: System32\Recovery) and register it
    // in the clone's offline image with reagentc /target.
    updateProgress("Etapa 7/7: Candado #4 — WinRE (Winre.wim + reagentc)", "Copiando Winre.wim desde la partición de recuperación del disco de origen a R: del disco nuevo...", 98.0, bench_mbs, false);
    {
        if (src_re) |re| {
            const rp = re.number;
            var l: [64]u8 = undefined;
            if (std.fmt.bufPrint(&l, "WinRE origen = Disco {d} particion {d}", .{ src_disk, rp })) |s| appendRunLog(s) else |_| {}
            var dp_y_buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&dp_y_buf, "select disk {d}\r\nselect partition {d}\r\nassign letter={c} noerr\r\nexit\r\n", .{ src_disk, rp, letterOf(LETTER_SRC_RE) })) |dp_y| {
                _ = runDiskpartScript(alloc, "dp_y_mount", dp_y);
                var cb6: [256]u8 = undefined;
                if (roleOnDisk(LETTER_SRC_RE, src_disk, "copia WinRE") and roleOnDisk(LETTER_REC, tdisk, "copia WinRE")) _ = runLoggedCommand(alloc, "robocopy_winre_src", L(&cb6, "\"C:\\Windows\\System32\\Robocopy.exe\" @Y:\\Recovery\\WindowsRE @R:\\Recovery\\WindowsRE Winre.wim /B /R:1 /W:1 /NFL /NDL /NJH /NJS"));
            } else |_| {}
            var dp_yu_buf: [128]u8 = undefined;
            if (std.fmt.bufPrint(&dp_yu_buf, "select disk {d}\r\nselect partition {d}\r\nremove letter={c} noerr\r\nexit\r\n", .{ src_disk, rp, letterOf(LETTER_SRC_RE) })) |dp_yu| {
                _ = runDiskpartScript(alloc, "dp_y_unmount", dp_yu);
            } else |_| {}
        } else {
            appendRunLog("WinRE origen: no se encontro particion de recuperacion en el disco de C:");
        }
        var wpb: [64]u8 = undefined;
        const winre_path = L(&wpb, "@R:\\Recovery\\WindowsRE\\Winre.wim");
        const rec_ok = roleOnDisk(LETTER_REC, tdisk, "WinRE");
        if (rec_ok and !fileExistsAbs(winre_path)) {
            var cb7: [256]u8 = undefined;
            _ = runLoggedCommand(alloc, "robocopy_winre_sys32", L(&cb7, "\"C:\\Windows\\System32\\Robocopy.exe\" @W:\\Windows\\System32\\Recovery @R:\\Recovery\\WindowsRE Winre.wim /B /R:1 /W:1 /NFL /NDL /NJH /NJS"));
        }
        const winre_ok = rec_ok and fileExistsAbs(winre_path);
        warn.check("winre_copy", winre_ok);
        if (winre_ok) {
            var cb8: [256]u8 = undefined;
            warn.check("reagentc_setreimage", runLoggedCommandEx(alloc, "reagentc_setreimage", L(&cb8, "\"C:\\Windows\\System32\\reagentc.exe\" /setreimage /path @R:\\Recovery\\WindowsRE /target @W:\\Windows"), 120, 300) == 0);
        }
    }
    // v2.9 (F1): no final "chkdsk /scan" (1 min 41 s on 2026-10-30): chkdsk /f already ran on W: right
    // after the verified copy, and nothing but the boot files was written to W: since then.

    // v2.9 (F3): check, without swapping disks, that the new disk boots its OWN Windows.
    updateProgress("Etapa 7/7: Revisando el arranque del clon", "Comprobando que el arranque del disco nuevo apunta a su propio Windows...", 99.0, bench_mbs, false);
    {
        var files_ok = true;
        inline for ([_][]const u8{
            "@S:\\EFI\\Microsoft\\Boot\\bootmgfw.efi",
            "@S:\\EFI\\Microsoft\\Boot\\BCD",
            "@S:\\EFI\\Boot\\bootx64.efi",
            "@W:\\Windows\\System32\\winload.efi",
        }) |tpl| {
            var fb: [96]u8 = undefined;
            const pth = L(&fb, tpl);
            if (!fileExistsAbs(pth)) {
                files_ok = false;
                var l: [140]u8 = undefined;
                if (std.fmt.bufPrint(&l, "ARRANQUE falta {s}", .{pth})) |x| appendRunLog(x) else |_| {}
            }
        }
        var cb: [200]u8 = undefined;
        const bcd_cmd = L(&cb, "\"C:\\Windows\\System32\\bcdedit.exe\" /store @S:\\EFI\\Microsoft\\Boot\\BCD /enum {default}");
        const rc = runLoggedCommandEx(alloc, "bcd_check", bcd_cmd, 60, 120);
        var tb: [16384]u8 = undefined;
        const txt = readLogFile("bcd_check", &tb);
        const bcd_ok = rc == 0 and bcdPointsTo(txt, letterOf(LETTER_WIN));
        var l: [160]u8 = undefined;
        if (std.fmt.bufPrint(&l, "ARRANQUE archivos={s} bcd_apunta_al_clon={s} (bcdedit rc={d})", .{ if (files_ok) "OK" else "FALTAN", if (bcd_ok) "si" else "NO", rc })) |x| appendRunLog(x) else |_| {}
        warn.check("arranque_revisado", files_ok and bcd_ok);
    }

    // NVF-E031: bcdboot succeeded -> this disk is a finished clone; protect it from accidental re-runs.
    writeCloneMarker(if (warn.count == 0) "OK, verificado al 100 %" else warn.names());
    {
        g_clone_usn_mutex.lock();
        const u = g_clone_usn;
        g_clone_usn_mutex.unlock();
        var stat_buf: [96]u8 = undefined;
        const stat = if (warn.count == 0) "OK" else (std.fmt.bufPrint(&stat_buf, "ADVERTENCIAS: {s}", .{warn.names()}) catch "ADVERTENCIAS");
        const secs: u64 = @intCast(@max(0, @divTrunc(std.time.milliTimestamp() - run_t0, 1000)));
        appendCloneHistory(id_dst.product(), dst_bytes, g_last_copied_bytes.load(.seq_cst), stat, u, secs, basis_bytes);
    }

    releaseCloneLetters(alloc, tdisk);
    letters_released = true;

    // v3.0.1: the new disk keeps the record of how it was made (2026-10-31: the 2.9.2 log stayed on the old
    // disk, so the real time of that clone is unknown). Done BEFORE the final "ya puede apagar" message and
    // flushed to the disk (review 3.0.1 #3); the copy only lacks that final line.
    if (roleOnDisk(LETTER_WIN, tdisk, "registro al clon")) {
        updateProgress("Etapa 7/7: Guardando el registro en el disco nuevo", "Copiando el registro de esta clonación al Windows del disco nuevo...", 99.5, bench_mbs, false);
        copyLogsToClone(letterOf(LETTER_WIN));
        flushVolume(letterOf(LETTER_WIN));
    }

    if (warn.count == 0) {
        const copied = g_last_copied_bytes.load(.seq_cst);
        const w_bytes = getVolumePartitionBytes(letterOf(LETTER_WIN));
        var fin: [400]u8 = undefined;
        const fin_s = std.fmt.bufPrint(&fin, "{s}: {d:.1} GiB copiados y releídos sin diferencias; Windows ocupa {d:.1} GiB en el disco nuevo. Arranque UEFI y WinRE instalados. Ya puede apagar el equipo e instalar el disco.", .{
            id_dst.product(),
            @as(f64, @floatFromInt(copied)) / 1073741824.0,
            @as(f64, @floatFromInt(w_bytes)) / 1073741824.0,
        }) catch "Copia releída sin diferencias. Arranque UEFI y WinRE instalados.";
        updateProgress("✔ Clon terminado y verificado", fin_s, 100.0, bench_mbs, true);
    } else {
        var st_buf: [160]u8 = undefined;
        var dt_buf: [512]u8 = undefined;
        const st_s = std.fmt.bufPrint(&st_buf, "⚠ [NVF-E019] Clonación terminada con {d} advertencia(s) — arranque UEFI instalado", .{warn.count}) catch "⚠ [NVF-E019] Clonación terminada con advertencias";
        const dt_s = std.fmt.bufPrint(&dt_buf, "Pasos con advertencia: {s}. Revise el Registro en vivo / %TEMP%\\NVMeForge\\logs\\clone_run.log antes de instalar el NVMe.", .{warn.names()}) catch "";
        updateProgress(st_s, dt_s, 100.0, bench_mbs, true);
    }
}

/// Writes every cached change of volume X: to the disk (FlushFileBuffers on the volume handle; Admin).
fn flushVolume(letter: u8) void {
    var path = [_:0]u16{ '\\', '\\', '.', '\\', letter, ':' };
    const h = CreateFileW(&path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(h);
    const ok = FlushFileBuffers(h) != 0;
    var l: [64]u8 = undefined;
    if (std.fmt.bufPrint(&l, "FLUSH {c}: (registro en el clon) -> {s}", .{ letter, if (ok) "OK" else "no" })) |x| appendRunLog(x) else |_| {}
}

/// Copies %TEMP%\NVMeForge\logs (and logs\runs) to the same path inside the clone's Windows, so NVMeForge
/// started from the new disk shows this run in Registro and its clone history. Best effort, never fatal.
fn copyLogsToClone(win_letter: u8) void {
    var src_buf: [512]u8 = undefined;
    const src = getTempFilePath(&src_buf, LOG_DIR_REL) orelse return;
    var dst_buf: [512]u8 = undefined;
    const dst = clonePathFor(&dst_buf, src, win_letter) orelse {
        appendRunLog("REGISTRO no se copió al clon: la carpeta temporal no está en C:");
        return;
    };
    var copied: u32 = 0;
    var failed: u32 = 0;
    copyDirFiles(src, dst, &copied, &failed);
    var rs: [520]u8 = undefined;
    var rd: [520]u8 = undefined;
    if (std.fmt.bufPrint(&rs, "{s}\\runs", .{src})) |rsrc| {
        if (std.fmt.bufPrint(&rd, "{s}\\runs", .{dst})) |rdst| copyDirFiles(rsrc, rdst, &copied, &failed) else |_| {}
    } else |_| {}
    var l: [700]u8 = undefined;
    if (std.fmt.bufPrint(&l, "REGISTRO copiado al disco nuevo: {s} ({d} archivos, {d} fallaron)", .{ dst, copied, failed })) |x| appendRunLog(x) else |_| {}
}

/// Pure: "C:\Users\x\AppData\Local\Temp\NVMeForge\logs" -> same path on the clone's letter; null when the
/// path is not on C: (then it would not exist inside the clone's Windows).
fn clonePathFor(out: []u8, src: []const u8, win_letter: u8) ?[]const u8 {
    if (src.len < 3 or std.ascii.toUpper(src[0]) != 'C' or src[1] != ':' or src[2] != '\\') return null;
    if (src.len > out.len) return null;
    @memcpy(out[0..src.len], src);
    out[0] = win_letter;
    return out[0..src.len];
}

fn copyDirFiles(src: []const u8, dst: []const u8, copied: *u32, failed: *u32) void {
    var sd = std.fs.cwd().openDir(src, .{ .iterate = true }) catch return;
    defer sd.close();
    std.fs.cwd().makePath(dst) catch {
        failed.* += 1;
        return;
    };
    var dd = std.fs.cwd().openDir(dst, .{}) catch {
        failed.* += 1;
        return;
    };
    defer dd.close();
    var it = sd.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .file) continue;
        sd.copyFile(e.name, dd, e.name, .{}) catch {
            failed.* += 1;
            continue;
        };
        copied.* += 1;
    }
}

/// v3.0.1 (NVF-E044): letters the target disk had before the run, with the volume each one named, so a run
/// that stops before "clean" (no free letters, diskpart failed early) can give them back. After "clean"
/// those volumes no longer exist and restore() simply finds nothing to do.
const SavedLetters = struct {
    n: usize = 0,
    letters: [26]u8 = undefined,
    vols: [26][64:0]u16 = undefined,

    fn capture(self: *SavedLetters, disk: u32) void {
        var ext: [26]VolExtent = undefined;
        const n = collectVolumeExtents(&ext);
        for (ext[0..n]) |e| {
            if (e.disk != disk or self.n == self.letters.len) continue;
            const root = [_:0]u16{ e.letter, ':', '\\' };
            var vol: [64:0]u16 = @splat(0);
            if (GetVolumeNameForVolumeMountPointW(&root, &vol, 64) == 0) continue;
            self.letters[self.n] = e.letter;
            self.vols[self.n] = vol;
            self.n += 1;
            var l: [80]u8 = undefined;
            if (std.fmt.bufPrint(&l, "LETRA {c}: del disco destino guardada para devolverla si la corrida se detiene", .{e.letter})) |x| appendRunLog(x) else |_| {}
        }
    }

    fn restore(self: *const SavedLetters) void {
        for (0..self.n) |i| {
            const letter = self.letters[i];
            if (isDriveLetterInUse(letter)) continue; // taken again (or never removed): leave it alone
            const root = [_:0]u16{ letter, ':', '\\' };
            const ok = SetVolumeMountPointW(&root, &self.vols[i]) != 0;
            var l: [96]u8 = undefined;
            if (std.fmt.bufPrint(&l, "LETRA {c}: devuelta a su volumen del disco destino -> {s}", .{ letter, if (ok) "OK" else "no (el volumen ya no existe)" })) |x| appendRunLog(x) else |_| {}
        }
    }
};

/// Collects non-fatal step failures so the final message never claims "100% verificado" when a step failed.
const StepWarnings = struct {
    count: u32 = 0,
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn check(self: *StepWarnings, name: []const u8, ok: bool) void {
        var line: [96]u8 = undefined;
        if (std.fmt.bufPrint(&line, "STEP {s} -> {s}", .{ name, if (ok) "OK" else "ADVERTENCIA" })) |l| appendRunLog(l) else |_| {}
        if (ok) return;
        self.count += 1;
        if (self.len > 0 and self.len + 2 < self.buf.len) {
            @memcpy(self.buf[self.len .. self.len + 2], ", ");
            self.len += 2;
        }
        const n = @min(name.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len .. self.len + n], name[0..n]);
        self.len += n;
    }

    fn names(self: *const StepWarnings) []const u8 {
        return self.buf[0..self.len];
    }
};

fn elevateSelf(alloc: std.mem.Allocator, extra_args: []const u8) bool {
    var exe_buf: [1024]u16 = undefined;
    const len = GetModuleFileNameW(null, &exe_buf, 1020);
    if (len == 0) return false;
    exe_buf[len] = 0;

    const verb_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, "runas") catch return false;
    defer alloc.free(verb_w);
    const args_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, extra_args) catch return false;
    defer alloc.free(args_w);

    const r = ShellExecuteW(
        null,
        verb_w.ptr,
        @ptrCast(&exe_buf[0]),
        args_w.ptr,
        null,
        1,
    );
    return r > 32;
}

fn isBackendListening() bool {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8999);
    const stream = std.net.tcpConnectToAddress(addr) catch return false;
    stream.close();
    return true;
}

fn requestExistingBackendShutdown() void {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8999);
    var stream = std.net.tcpConnectToAddress(addr) catch return;
    defer stream.close();
    stream.writeAll("POST /api/shutdown HTTP/1.1\r\nHost: 127.0.0.1:8999\r\nX-NVMeForge: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch {};
}

fn openDesktopWindow(alloc: std.mem.Allocator) bool {
    var prof_buf: [512]u8 = undefined;
    // v2.7: the window profile lives with the logs in %TEMP%\NVMeForge (one folder to delete to uninstall).
    const prof_dir = getTempFilePath(&prof_buf, "NVMeForge\\ventana") orelse "C:\\Windows\\Temp\\NVMeForge\\ventana";

    const browsers = [_][]const u8{
        "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
        "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
        "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
        "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    };

    for (browsers) |b_path| {
        if (std.fs.cwd().access(b_path, .{})) |_| {
            var cmd_buf: [1024]u8 = undefined;
            const cmd = std.fmt.bufPrint(
                &cmd_buf,
                "\"{s}\" --app=http://127.0.0.1:8999 \"--user-data-dir={s}\" --window-size=1460,920 --no-first-run --no-default-browser-check",
                .{ b_path, prof_dir },
            ) catch continue;
            if (spawnCommand(alloc, cmd, 0)) return true;
        } else |_| {}
    }
    return false;
}

fn buildPowerJson(buf: []u8) []const u8 {
    const b = getBatteryInfo();
    var pct_buf: [8]u8 = undefined;
    return std.fmt.bufPrint(
        buf,
        "{{\"battery_pct\":{s},\"ac_online\":{s},\"battery_charging\":{s},\"has_battery\":{s},\"is_admin\":{s}}}",
        .{
            jsonOptU8(b.pct, &pct_buf),
            jsonOptBool(b.ac),
            if (b.chg) "true" else "false",
            if (b.has_battery) "true" else "false",
            if (isAdmin()) "true" else "false",
        },
    ) catch "{\"battery_pct\":null,\"ac_online\":null,\"battery_charging\":false,\"has_battery\":false,\"is_admin\":false}";
}

// ============================================================================================
// v2.4.0 — Telemetría REAL para la interfaz (solo lectura). Nada de valores por defecto
// inventados: si Windows no lo puede medir, el JSON lleva null y la interfaz dice "No disponible".
// ============================================================================================

extern "kernel32" fn GetSystemFirmwareTable(sig: u32, id: u32, buf: ?*anyopaque, size: u32) callconv(.winapi) u32;
extern "kernel32" fn GlobalMemoryStatusEx(lpBuffer: *MEMORYSTATUSEX) callconv(.winapi) i32;
extern "kernel32" fn GetVolumeInformationW(
    root: [*:0]const u16,
    name_buf: ?[*]u16,
    name_size: u32,
    serial: ?*u32,
    max_comp: ?*u32,
    flags: ?*u32,
    fs_buf: ?[*]u16,
    fs_size: u32,
) callconv(.winapi) i32;

const MEMORYSTATUSEX = extern struct {
    dwLength: u32 = @sizeOf(MEMORYSTATUSEX),
    dwMemoryLoad: u32 = 0,
    ullTotalPhys: u64 = 0,
    ullAvailPhys: u64 = 0,
    ullTotalPageFile: u64 = 0,
    ullAvailPageFile: u64 = 0,
    ullTotalVirtual: u64 = 0,
    ullAvailVirtual: u64 = 0,
    ullAvailExtendedVirtual: u64 = 0,
};

/// Minimal JSON writer over an ArrayList (Zig 0.15 unmanaged). Strings are escaped; control chars dropped.
const Json = struct {
    list: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn raw(self: *Json, s: []const u8) void {
        self.list.appendSlice(self.gpa, s) catch {};
    }
    fn str(self: *Json, s: []const u8) void {
        self.raw("\"");
        for (s) |ch| {
            switch (ch) {
                '"' => self.raw("\\\""),
                '\\' => self.raw("\\\\"),
                '\n' => self.raw("\\n"),
                '\r' => self.raw("\\r"),
                '\t' => self.raw("\\t"),
                0...8, 11, 12, 14...0x1F, 0x7F => {},
                else => self.list.append(self.gpa, ch) catch {},
            }
        }
        self.raw("\"");
    }
    fn key(self: *Json, k: []const u8) void {
        self.str(k);
        self.raw(":");
    }
    fn print(self: *Json, comptime fmt: []const u8, args: anytype) void {
        self.list.print(self.gpa, fmt, args) catch {};
    }
    fn strOrNull(self: *Json, s: []const u8) void {
        const t = std.mem.trim(u8, s, " \t\r\n");
        if (t.len == 0) self.raw("null") else self.str(t);
    }
    fn deinit(self: *Json) void {
        self.list.deinit(self.gpa);
    }
};

fn utf16ToUtf8Buf(src: []const u16, out: []u8) []const u8 {
    const end = std.mem.indexOfScalar(u16, src, 0) orelse src.len;
    var n: usize = 0;
    var it = std.unicode.Utf16LeIterator.init(src[0..end]);
    while (it.nextCodepoint() catch null) |cp| {
        var tmp: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(cp, &tmp) catch break;
        if (n + l > out.len) break;
        @memcpy(out[n .. n + l], tmp[0..l]);
        n += l;
    }
    return out[0..n];
}

fn openPhysicalDrive(disk: u32, access: u32, flags: u32) ?HANDLE {
    var path_buf: [64]u8 = undefined;
    const dev_utf8 = std.fmt.bufPrint(&path_buf, "\\\\.\\PhysicalDrive{d}", .{disk}) catch return null;
    var wbuf: [64:0]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, dev_utf8) catch return null;
    wbuf[wlen] = 0;
    const h = CreateFileW(&wbuf, access, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, flags, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    return h;
}

// ---------------- Identidad completa del disco (STORAGE_DEVICE_DESCRIPTOR) ----------------
const DiskDescriptor = struct {
    vendor: [64]u8 = undefined,
    vendor_len: usize = 0,
    product: [64]u8 = undefined,
    product_len: usize = 0,
    revision: [32]u8 = undefined,
    revision_len: usize = 0,
    serial: [96]u8 = undefined,
    serial_len: usize = 0,
    bus: u32 = 0,
    removable: bool = false,
};

fn readDiskDescriptor(h: HANDLE) ?DiskDescriptor {
    var query = [_]u8{0} ** 12; // StorageDeviceProperty (0), PropertyStandardQuery (0)
    var desc: [1024]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &query, query.len, &desc, desc.len, &ret, null) == 0 or ret < 32) return null;
    const d = desc[0..ret];
    var r = DiskDescriptor{};
    r.removable = desc[10] != 0;
    r.vendor_len = copyDescriptorString(d, std.mem.readInt(u32, desc[12..16], .little), &r.vendor);
    r.product_len = copyDescriptorString(d, std.mem.readInt(u32, desc[16..20], .little), &r.product);
    r.revision_len = copyDescriptorString(d, std.mem.readInt(u32, desc[20..24], .little), &r.revision);
    r.serial_len = copyDescriptorString(d, std.mem.readInt(u32, desc[24..28], .little), &r.serial);
    r.bus = std.mem.readInt(u32, desc[28..32], .little);
    return r;
}

// ---------------- Salud NVMe real (log de salud 0x02 vía StorageDeviceProtocolSpecificProperty) ----------------
const NvmeHealth = struct {
    critical_warning: u8 = 0,
    temp_c: i32 = 0,
    spare_pct: u8 = 0,
    spare_threshold_pct: u8 = 0,
    used_pct: u8 = 0,
    data_read_bytes: u64 = 0,
    data_written_bytes: u64 = 0,
    power_on_hours: u64 = 0,
    power_cycles: u64 = 0,
    unsafe_shutdowns: u64 = 0,
    media_errors: u64 = 0,
    error_log_entries: u64 = 0,
    thermal: diskcheck.Thermal = .{},
};

/// Only works for disks behind the Windows NVMe driver (stornvme). USB bridges such as the RTL9210 usually
/// do not pass this query -> null (the UI then says "No disponible a través del adaptador USB").
fn queryNvmeHealth(h: HANDLE) ?NvmeHealth {
    var buf: [8 + 40 + 512]u8 align(8) = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 50, .little); // PropertyId = StorageDeviceProtocolSpecificProperty
    std.mem.writeInt(u32, buf[4..8], 0, .little); // QueryType  = PropertyStandardQuery
    std.mem.writeInt(u32, buf[8..12], 3, .little); // ProtocolType = ProtocolTypeNvme
    std.mem.writeInt(u32, buf[12..16], 2, .little); // DataType = NVMeDataTypeLogPage
    std.mem.writeInt(u32, buf[16..20], 2, .little); // RequestValue = NVME_LOG_PAGE_HEALTH_INFO
    std.mem.writeInt(u32, buf[20..24], 0, .little); // RequestSubValue
    std.mem.writeInt(u32, buf[24..28], 40, .little); // ProtocolDataOffset = sizeof(STORAGE_PROTOCOL_SPECIFIC_DATA)
    std.mem.writeInt(u32, buf[28..32], 512, .little); // ProtocolDataLength
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &buf, buf.len, &buf, buf.len, &ret, null) == 0) return null;
    // STORAGE_PROTOCOL_DATA_DESCRIPTOR: Version, Size (both 48), then STORAGE_PROTOCOL_SPECIFIC_DATA.
    if (std.mem.readInt(u32, buf[0..4], .little) != 48 or std.mem.readInt(u32, buf[4..8], .little) != 48) return null;
    const data_off = std.mem.readInt(u32, buf[8 + 16 ..][0..4], .little);
    const data_len = std.mem.readInt(u32, buf[8 + 20 ..][0..4], .little);
    if (data_off < 40 or data_len < 512 or 8 + data_off + 512 > buf.len) return null;
    const log = buf[8 + data_off ..][0..512];
    const kelvin = std.mem.readInt(u16, log[1..3], .little);
    if (kelvin < 200 or kelvin > 400) return null; // not a plausible NVMe composite temperature -> do not trust any field
    var hl = NvmeHealth{};
    hl.critical_warning = log[0];
    hl.temp_c = @as(i32, kelvin) - 273;
    hl.spare_pct = log[3];
    hl.spare_threshold_pct = log[4];
    hl.used_pct = log[5];
    hl.data_read_bytes = std.mem.readInt(u64, log[32..40], .little) *| 512_000;
    hl.data_written_bytes = std.mem.readInt(u64, log[48..56], .little) *| 512_000;
    hl.power_cycles = std.mem.readInt(u64, log[112..120], .little);
    hl.power_on_hours = std.mem.readInt(u64, log[128..136], .little);
    hl.unsafe_shutdowns = std.mem.readInt(u64, log[144..152], .little);
    hl.media_errors = std.mem.readInt(u64, log[160..168], .little);
    hl.error_log_entries = std.mem.readInt(u64, log[176..184], .little);
    hl.thermal = diskcheck.parseThermal(log);
    if (hl.spare_pct > 100) return null;
    return hl;
}

// ---------------- Letras de unidad -> (disco, offset) ----------------
const VolExtent = struct { letter: u8, disk: u32, offset: u64, length: u64 };

fn volumeExtent(letter: u8) ?VolExtent {
    var path = [_:0]u16{ '\\', '\\', '.', '\\', letter, ':' };
    const h = CreateFileW(&path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var buf: [256]u8 align(8) = undefined;
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, null, 0, &buf, buf.len, &ret, null) == 0 or ret < 32) return null;
    if (std.mem.readInt(u32, buf[0..4], .little) != 1) return null; // spanned volumes are not mapped to a single partition
    return .{
        .letter = letter,
        .disk = std.mem.readInt(u32, buf[8..12], .little),
        .offset = std.mem.readInt(u64, buf[16..24], .little),
        .length = std.mem.readInt(u64, buf[24..32], .little),
    };
}

fn collectVolumeExtents(out: []VolExtent) usize {
    const mask = GetLogicalDrives();
    var n: usize = 0;
    var i: u5 = 2; // C..Z (A:/B: are legacy floppy letters)
    while (true) : (i += 1) {
        if ((mask & (@as(u32, 1) << i)) != 0 and n < out.len) {
            if (volumeExtent('A' + @as(u8, i))) |e| {
                out[n] = e;
                n += 1;
            }
        }
        if (i == 25) break;
    }
    return n;
}

const GUID_EFI = [16]u8{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B };
const GUID_MSR = [16]u8{ 0x16, 0xE3, 0xC9, 0xE3, 0x5C, 0x0B, 0xB8, 0x4D, 0x81, 0x7D, 0xF9, 0x2D, 0xF0, 0x02, 0x15, 0xAE };
const GUID_DATA = [16]u8{ 0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 };
const GUID_WINRE = [16]u8{ 0xA4, 0xBB, 0x94, 0xDE, 0xD1, 0x06, 0x40, 0x4D, 0xA1, 0x6A, 0xBF, 0xD5, 0x01, 0x79, 0xD6, 0xAC };

fn gptKind(type_guid: []const u8) []const u8 {
    if (std.mem.eql(u8, type_guid, &GUID_EFI)) return "efi";
    if (std.mem.eql(u8, type_guid, &GUID_MSR)) return "msr";
    if (std.mem.eql(u8, type_guid, &GUID_DATA)) return "data";
    if (std.mem.eql(u8, type_guid, &GUID_WINRE)) return "recovery";
    return "other";
}

fn mbrKind(t: u8) []const u8 {
    return switch (t) {
        0x07 => "data",
        0x27 => "recovery",
        0xEF => "efi",
        0x0B, 0x0C, 0x0E, 0x06 => "data",
        else => "other",
    };
}

/// True when the first sector of the partition carries the BitLocker signature "-FVE-FS-" (raw read,
/// requires Administrator). null = could not be read.
fn partitionIsBitLocker(h_raw: HANDLE, offset: u64) ?bool {
    var sector: [4096]u8 align(4096) = undefined;
    if (SetFilePointerEx(h_raw, @intCast(offset), null, 0) == 0) return null;
    var n: u32 = 0;
    if (ReadFile(h_raw, &sector, sector.len, &n, null) == 0 or n < 512) return null;
    return std.mem.eql(u8, sector[3..11], "-FVE-FS-");
}

fn writeVolumeInfo(j: *Json, letter: u8) void {
    var root = [_:0]u16{ letter, ':', '\\' };
    var label16: [64]u16 = @splat(0);
    var fs16: [32]u16 = @splat(0);
    j.raw(",\"letter\":");
    var lb: [2]u8 = .{ letter, ':' };
    j.str(&lb);
    if (GetVolumeInformationW(&root, &label16, label16.len, null, null, null, &fs16, fs16.len) != 0) {
        var l8: [192]u8 = undefined;
        var f8: [64]u8 = undefined;
        j.raw(",\"label\":");
        j.strOrNull(utf16ToUtf8Buf(&label16, &l8));
        j.raw(",\"fs\":");
        j.strOrNull(utf16ToUtf8Buf(&fs16, &f8));
    } else {
        j.raw(",\"label\":null,\"fs\":null");
    }
    var avail: u64 = 0;
    var total: u64 = 0;
    var free: u64 = 0;
    if (GetDiskFreeSpaceExW(&root, &avail, &total, &free) != 0 and total > 0) {
        j.print(",\"fs_total_bytes\":{d},\"fs_free_bytes\":{d}", .{ total, free });
    } else {
        j.raw(",\"fs_total_bytes\":null,\"fs_free_bytes\":null");
    }
}

fn writeDiskJson(j: *Json, disk: u32, h: HANDLE, extents: []const VolExtent, deep: bool) void {
    j.print("{{\"number\":{d}", .{disk});
    const desc = readDiskDescriptor(h);
    if (desc) |d| {
        j.raw(",\"vendor\":");
        j.strOrNull(d.vendor[0..d.vendor_len]);
        j.raw(",\"model\":");
        j.strOrNull(d.product[0..d.product_len]);
        j.raw(",\"firmware\":");
        j.strOrNull(d.revision[0..d.revision_len]);
        j.raw(",\"serial\":");
        // Many USB bridges report an all-zero serial: that is not a real serial number.
        const s = d.serial[0..d.serial_len];
        const all_zero = s.len > 0 and std.mem.allEqual(u8, s, '0');
        if (all_zero) j.raw("null") else j.strOrNull(s);
        j.raw(",\"serial_hidden_by_bridge\":");
        j.raw(if (all_zero) "true" else "false");
        j.raw(",\"bus\":");
        j.str(busTypeName(d.bus));
        j.raw(",\"removable\":");
        j.raw(if (d.removable) "true" else "false");
    } else {
        j.raw(",\"vendor\":null,\"model\":null,\"firmware\":null,\"serial\":null,\"serial_hidden_by_bridge\":false,\"bus\":null,\"removable\":null");
    }
    var path_buf: [64]u8 = undefined;
    const dev = std.fmt.bufPrint(&path_buf, "\\\\.\\PhysicalDrive{d}", .{disk}) catch "";
    const bytes = getVolumeLengthBytes(dev);
    if (bytes > 0) j.print(",\"bytes\":{d}", .{bytes}) else j.raw(",\"bytes\":null");
    if (diskLogicalSectorBytes(disk)) |ss| j.print(",\"logical_sector_bytes\":{d}", .{ss}) else j.raw(",\"logical_sector_bytes\":null");

    // Real partition table.
    var layout: [8192]u8 align(8) = undefined;
    var ret: u32 = 0;
    const ok = DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_LAYOUT_EX, null, 0, &layout, layout.len, &ret, null) != 0 and ret >= 48;
    if (!ok) {
        j.raw(",\"style\":null,\"partitions\":[]");
    } else {
        const style = std.mem.readInt(u32, layout[0..4], .little);
        const count = std.mem.readInt(u32, layout[4..8], .little);
        j.raw(",\"style\":");
        j.str(switch (style) {
            0 => "MBR",
            1 => "GPT",
            else => "RAW",
        });
        const h_raw: ?HANDLE = if (deep) openPhysicalDrive(disk, GENERIC_READ, 0) else null;
        defer if (h_raw) |hr| {
            _ = CloseHandle(hr);
        };
        j.raw(",\"partitions\":[");
        var first = true;
        var i: u32 = 0;
        while (i < count and i < 64) : (i += 1) {
            const base: usize = 48 + @as(usize, i) * 144;
            if (base + 144 > ret) break;
            const p = layout[base..][0..144];
            const offset = std.mem.readInt(u64, p[8..16], .little);
            const length = std.mem.readInt(u64, p[16..24], .little);
            const number = std.mem.readInt(u32, p[24..28], .little);
            if (length == 0) continue; // empty MBR slots
            const pstyle = std.mem.readInt(u32, p[0..4], .little);
            const kind = if (pstyle == 1) gptKind(p[32..48]) else mbrKind(p[32]);
            if (!first) j.raw(",");
            first = false;
            j.print("{{\"number\":{d},\"offset\":{d},\"bytes\":{d},\"kind\":", .{ number, offset, length });
            j.str(kind);
            j.raw(",\"name\":");
            if (pstyle == 1) {
                var name16: [36]u16 = undefined;
                for (&name16, 0..) |*c, k| c.* = std.mem.readInt(u16, p[72 + k * 2 ..][0..2], .little);
                var n8: [128]u8 = undefined;
                j.strOrNull(utf16ToUtf8Buf(&name16, &n8));
            } else j.raw("null");
            var mapped = false;
            for (extents) |e| {
                if (e.disk == disk and e.offset == offset) {
                    writeVolumeInfo(j, e.letter);
                    mapped = true;
                    break;
                }
            }
            if (!mapped) j.raw(",\"letter\":null,\"label\":null,\"fs\":null,\"fs_total_bytes\":null,\"fs_free_bytes\":null");
            j.raw(",\"bitlocker\":");
            if (h_raw != null and std.mem.eql(u8, kind, "data")) {
                if (partitionIsBitLocker(h_raw.?, offset)) |b| j.raw(if (b) "true" else "false") else j.raw("null");
            } else j.raw("null");
            j.raw("}");
        }
        j.raw("]");
    }

    // v2.6: health and temperature are plain IOCTL queries: no Administrator needed, safe during a clone.
    const health = queryNvmeHealth(h);
    const tprop = queryTemperatureProperty(h);
    if (health) |hl| {
        j.print(",\"temp_c\":{d},\"temp_source\":\"nvme\"", .{hl.temp_c});
    } else if (tprop) |tp| {
        j.print(",\"temp_c\":{d},\"temp_source\":\"windows\"", .{tp.temp_c});
    } else j.raw(",\"temp_c\":null,\"temp_source\":null");
    if (tprop) |tp| {
        if (tp.warn_c > 0 and tp.warn_c < 150) j.print(",\"temp_warn_c\":{d}", .{tp.warn_c}) else j.raw(",\"temp_warn_c\":null");
        if (tp.crit_c > 0 and tp.crit_c < 150) j.print(",\"temp_crit_c\":{d}", .{tp.crit_c}) else j.raw(",\"temp_crit_c\":null");
    } else j.raw(",\"temp_warn_c\":null,\"temp_crit_c\":null");
    j.raw(",\"health\":");
    {
        if (health) |hl| {
            j.print("{{\"critical_warning\":{d},\"temp_c\":{d},\"spare_pct\":{d},\"spare_threshold_pct\":{d},\"used_pct\":{d},\"data_read_bytes\":{d},\"data_written_bytes\":{d},\"power_on_hours\":{d},\"power_cycles\":{d},\"unsafe_shutdowns\":{d},\"media_errors\":{d},\"error_log_entries\":{d}", .{
                hl.critical_warning, hl.temp_c, hl.spare_pct, hl.spare_threshold_pct, hl.used_pct, hl.data_read_bytes, hl.data_written_bytes, hl.power_on_hours, hl.power_cycles, hl.unsafe_shutdowns, hl.media_errors, hl.error_log_entries,
            });
            // v3.0 (F10): thermal history of the disk, straight from the same NVMe health log.
            const t = hl.thermal;
            j.print(",\"warn_temp_minutes\":{d},\"crit_temp_minutes\":{d},\"throttle_count_1\":{d},\"throttle_count_2\":{d},\"throttle_secs_1\":{d},\"throttle_secs_2\":{d},\"busy_minutes\":{d},\"sensors_c\":[", .{
                t.warn_temp_minutes, t.crit_temp_minutes, t.tmt1_count, t.tmt2_count, t.tmt1_secs, t.tmt2_secs, t.busy_minutes,
            });
            var last: usize = 0; // trailing unimplemented sensors are left out; gaps stay as null
            for (t.sensors_c, 0..) |sc, i| {
                if (sc != null) last = i + 1;
            }
            for (t.sensors_c[0..last], 0..) |sc, i| {
                if (i > 0) j.raw(",");
                if (sc) |c| j.print("{d}", .{c}) else j.raw("null");
            }
            j.raw("]}");
        } else j.raw("null");
    }
    writeDiskExtrasJson(j, disk, h);
    if (health) |hl| {
        if (desc) |d| recordHealthDaily(d.serial[0..d.serial_len], d.product[0..d.product_len], hl);
    }
    j.raw("}");
}

// ---------------- v3.1: historial de salud por día (logs\health_history.tsv) ----------------
// date \t serial \t model \t used_pct \t written_bytes \t read_bytes \t power_on_hours \t temp_c \t
// warn_min \t crit_min \t throttle_total \t media_errors. One row per disk (serial) per day.
var g_health_mutex: std.Thread.Mutex = .{};
var g_health_done: [MAX_DISKS][64]u8 = undefined; // "YYYY-MM-DD|serial" already recorded by this process
var g_health_done_n: usize = 0;

var g_health_day: u32 = 0; // yyyymmdd of the keys in g_health_done

fn recordHealthDaily(serial_raw: []const u8, model_raw: []const u8, hl: NvmeHealth) void {
    if (@import("builtin").is_test) return; // tests must not write rows into the user's real history
    const serial = std.mem.trim(u8, serial_raw, " .");
    if (serial.len == 0 or std.mem.allEqual(u8, serial, '0')) return; // no stable identity: do not mix disks
    var st = SYSTEMTIME{};
    GetLocalTime(&st);
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d:0>4}-{d:0>2}-{d:0>2}|{s}", .{ st.wYear, st.wMonth, st.wDay, serial[0..@min(serial.len, 48)] }) catch return;
    g_health_mutex.lock();
    defer g_health_mutex.unlock();
    const today: u32 = @as(u32, st.wYear) * 10000 + @as(u32, st.wMonth) * 100 + st.wDay;
    if (today != g_health_day) { // new day: yesterday's keys can never match again
        g_health_day = today;
        g_health_done_n = 0;
    }
    for (g_health_done[0..g_health_done_n]) |*k| {
        if (std.mem.eql(u8, std.mem.sliceTo(k, 0), key)) return;
    }
    // Not seen by this process: the file may already have today's row (NVMeForge opened earlier today).
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, "health_history.tsv") orelse return;
    const already = blk: {
        const f = std.fs.cwd().openFile(path, .{}) catch break :blk false;
        defer f.close();
        var buf: [65536]u8 = undefined;
        const size = f.getEndPos() catch break :blk false;
        if (size > buf.len) f.seekTo(size - buf.len) catch {};
        const n = f.readAll(&buf) catch break :blk false;
        var tab_key: [64]u8 = undefined;
        const tk = std.fmt.bufPrint(&tab_key, "{s}\t{s}\t", .{ key[0..10], key[11..] }) catch break :blk false;
        break :blk std.mem.indexOf(u8, buf[0..n], tk) != null;
    };
    if (g_health_done_n < g_health_done.len) {
        @memset(&g_health_done[g_health_done_n], 0);
        @memcpy(g_health_done[g_health_done_n][0..key.len], key);
        g_health_done_n += 1;
    }
    if (already) return;
    ensureLogDir();
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};
    var model: [64]u8 = undefined;
    var mn: usize = 0;
    for (model_raw) |ch| {
        if (mn >= model.len) break;
        model[mn] = if (ch == '\t' or ch == '\r' or ch == '\n') ' ' else ch;
        mn += 1;
    }
    const t = hl.thermal;
    var line: [400]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\r\n", .{
        key[0..10], key[11..], std.mem.trim(u8, model[0..mn], " "), hl.used_pct, hl.data_written_bytes, hl.data_read_bytes, hl.power_on_hours, hl.temp_c, t.warn_temp_minutes, t.crit_temp_minutes, t.throttleCount(), hl.media_errors,
    }) catch return;
    f.writeAll(s) catch {};
}

/// Pure: health_history.tsv -> JSON array oldest first (at most the last 400 rows), malformed rows skipped.
fn healthHistoryJsonFromTsv(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    var j = Json{ .gpa = gpa };
    errdefer j.deinit();
    j.raw("[");
    var rows: [400][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitBackwardsScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, "\r ");
        if (t.len == 0) continue;
        rows[n] = t;
        n += 1;
        if (n == rows.len) break;
    }
    var first = true;
    var i: usize = n;
    row: while (i > 0) {
        i -= 1;
        var cols: [12][]const u8 = undefined;
        var k: usize = 0;
        var cit = std.mem.splitScalar(u8, rows[i], '\t');
        while (cit.next()) |c| {
            if (k == cols.len) continue :row;
            cols[k] = c;
            k += 1;
        }
        if (k != cols.len or cols[0].len != 10) continue;
        var v: [9]i64 = undefined;
        for (0..9) |x| v[x] = std.fmt.parseInt(i64, cols[3 + x], 10) catch continue :row;
        if (!first) j.raw(",");
        first = false;
        j.raw("{\"date\":");
        j.str(cols[0]);
        j.raw(",\"serial\":");
        j.str(cols[1]);
        j.raw(",\"model\":");
        j.str(cols[2]);
        j.print(",\"used_pct\":{d},\"written_bytes\":{d},\"read_bytes\":{d},\"power_on_hours\":{d},\"temp_c\":{d},\"warn_min\":{d},\"crit_min\":{d},\"throttle\":{d},\"media_errors\":{d}}}", .{ v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8] });
    }
    j.raw("]");
    return j.list.toOwnedSlice(gpa) catch null;
}

/// v3.0 (F10): NVMe identify, TRIM, write cache and PCIe link of one disk. All read-only queries.
fn writeDiskExtrasJson(j: *Json, disk: u32, h: HANDLE) void {
    j.raw(",\"nvme\":");
    if (cachedIdentify(disk, h)) |id| {
        if (id.ver_major > 0) j.print("{{\"version\":\"{d}.{d}\"", .{ id.ver_major, id.ver_minor }) else j.raw("{\"version\":null");
        j.print(",\"hctm\":{s},\"volatile_cache\":{s},\"wctemp_c\":", .{ if (id.hctm) "true" else "false", if (id.volatile_cache) "true" else "false" });
        if (id.wctemp_c) |v| j.print("{d}", .{v}) else j.raw("null");
        j.raw(",\"cctemp_c\":");
        if (id.cctemp_c) |v| j.print("{d}", .{v}) else j.raw("null");
        j.raw("}");
    } else j.raw("null");
    j.raw(",\"trim\":");
    if (diskcheck.queryTrim(h)) |t| j.raw(if (t) "true" else "false") else j.raw("null");
    j.raw(",\"write_cache\":");
    if (diskcheck.queryWriteCache(h)) |wc| {
        j.raw("{\"enabled\":");
        if (wc.enabled) |e| j.raw(if (e) "true" else "false") else j.raw("null");
        j.print(",\"changeable\":{s},\"flush_off\":{s}}}", .{ if (wc.changeable) "true" else "false", if (wc.flush_off) "true" else "false" });
    } else j.raw("null");
    j.raw(",\"pcie\":");
    if (cachedPcieLink(disk)) |l| {
        j.print("{{\"cur_gen\":{d},\"cur_width\":{d},\"max_gen\":{d},\"max_width\":{d}", .{ l.cur_gen, l.cur_width, l.max_gen, l.max_width });
        if (diskcheck.pcieLinkMBs(l.cur_gen, l.cur_width)) |m| j.print(",\"cur_mbs\":{d:.0}", .{m}) else j.raw(",\"cur_mbs\":null");
        if (diskcheck.pcieLinkMBs(l.max_gen, l.max_width)) |m| j.print(",\"max_mbs\":{d:.0}}}", .{m}) else j.raw(",\"max_mbs\":null}");
    } else j.raw("null");
}

// Identify Controller is static: ask each disk once a minute, not on every /api/status (a 4 KiB admin
// command per poll would also disturb a running benchmark).
var g_ident_cache: [MAX_DISKS]struct { at_ms: i64 = 0, id: ?diskcheck.Identify = null } = @splat(.{});

fn cachedIdentify(disk: u32, h: HANDLE) ?diskcheck.Identify {
    if (disk >= MAX_DISKS) return diskcheck.queryIdentify(h);
    const now = std.time.milliTimestamp();
    g_pcie_mutex.lock();
    const c = g_ident_cache[disk];
    g_pcie_mutex.unlock();
    if (c.at_ms != 0 and now - c.at_ms < 60_000) return c.id;
    const id = diskcheck.queryIdentify(h);
    g_pcie_mutex.lock();
    g_ident_cache[disk] = .{ .at_ms = now, .id = id };
    g_pcie_mutex.unlock();
    return id;
}

// The PCIe query walks SetupAPI; /api/status is polled every few seconds, so keep each answer 10 s.
var g_pcie_mutex: std.Thread.Mutex = .{};
var g_pcie_cache: [MAX_DISKS]struct { at_ms: i64 = 0, link: ?diskcheck.PcieLink = null } = @splat(.{});

fn cachedPcieLink(disk: u32) ?diskcheck.PcieLink {
    if (disk >= MAX_DISKS) return null;
    const now = std.time.milliTimestamp();
    g_pcie_mutex.lock();
    const c = g_pcie_cache[disk];
    g_pcie_mutex.unlock();
    if (c.at_ms != 0 and now - c.at_ms < 10_000) return c.link;
    const l = diskcheck.queryPcieLink(disk);
    g_pcie_mutex.lock();
    g_pcie_cache[disk] = .{ .at_ms = now, .link = l };
    g_pcie_mutex.unlock();
    return l;
}

// ---------------- Equipo: SMBIOS (firmware) + memoria + Windows ----------------
fn smbiosString(area: []const u8, idx: u8) []const u8 {
    if (idx == 0) return "";
    var it = std.mem.splitScalar(u8, area, 0);
    var k: u8 = 1;
    while (it.next()) |s| : (k += 1) {
        if (k == idx) return std.mem.trim(u8, s, " ");
    }
    return "";
}

fn ddrName(t: u8) []const u8 {
    return switch (t) {
        0x18 => "DDR3",
        0x1A => "DDR4",
        0x1D => "LPDDR3",
        0x1E => "LPDDR4",
        0x22 => "DDR5",
        0x23 => "LPDDR5",
        else => "",
    };
}

fn writeSystemJson(j: *Json, gpa: std.mem.Allocator) void {
    j.raw("{");
    var sys_vendor: []const u8 = "";
    var sys_product: []const u8 = "";
    var board_vendor: []const u8 = "";
    var board_product: []const u8 = "";
    var bios_vendor: []const u8 = "";
    var bios_version: []const u8 = "";
    var bios_date: []const u8 = "";
    var cpu: []const u8 = "";
    var cores: u32 = 0;
    var threads: u32 = 0;
    var mem = Json{ .gpa = gpa };
    defer mem.deinit();
    mem.raw("[");
    var mem_first = true;

    const RSMB: u32 = 0x52534D42;
    const need = GetSystemFirmwareTable(RSMB, 0, null, 0);
    const table: ?[]u8 = if (need > 8 and need < 4 * 1024 * 1024) (gpa.alloc(u8, need) catch null) else null;
    defer if (table) |t| gpa.free(t);
    if (table) |t| {
        const got = GetSystemFirmwareTable(RSMB, 0, t.ptr, need);
        if (got >= 8) {
            const tlen = std.mem.readInt(u32, t[4..8], .little);
            const end = @min(t.len, 8 + @as(usize, tlen));
            var off: usize = 8;
            while (off + 4 <= end) {
                const typ = t[off];
                const len = t[off + 1];
                if (len < 4 or off + len > end) break;
                const f = t[off .. off + len];
                var s = off + len;
                const str_start = s;
                while (s + 1 < end and !(t[s] == 0 and t[s + 1] == 0)) s += 1;
                const area = t[str_start..s];
                switch (typ) {
                    0 => if (len >= 0x09) {
                        bios_vendor = smbiosString(area, f[4]);
                        bios_version = smbiosString(area, f[5]);
                        bios_date = smbiosString(area, f[8]);
                    },
                    1 => if (len >= 0x08) {
                        sys_vendor = smbiosString(area, f[4]);
                        sys_product = smbiosString(area, f[5]);
                    },
                    2 => if (len >= 0x08) {
                        board_vendor = smbiosString(area, f[4]);
                        board_product = smbiosString(area, f[5]);
                    },
                    4 => if (len >= 0x11 and cpu.len == 0) {
                        cpu = smbiosString(area, f[0x10]);
                        if (len > 0x23) cores = f[0x23];
                        if (len > 0x25) threads = f[0x25];
                        if (len >= 0x2C and cores == 0xFF) cores = std.mem.readInt(u16, f[0x2A..0x2C], .little);
                        if (len >= 0x30 and threads == 0xFF) threads = std.mem.readInt(u16, f[0x2E..0x30], .little);
                    },
                    17 => if (len >= 0x1B) {
                        var size_mb: u64 = std.mem.readInt(u16, f[0x0C..0x0E], .little);
                        if (size_mb == 0x7FFF and len >= 0x20) {
                            size_mb = std.mem.readInt(u32, f[0x1C..0x20], .little);
                        } else if (size_mb != 0xFFFF and (size_mb & 0x8000) != 0) {
                            size_mb = (size_mb & 0x7FFF) / 1024; // value in KB
                        }
                        if (size_mb != 0 and size_mb != 0xFFFF) {
                            if (!mem_first) mem.raw(",");
                            mem_first = false;
                            const speed = std.mem.readInt(u16, f[0x15..0x17], .little);
                            const cfg_speed: u16 = if (len >= 0x22) std.mem.readInt(u16, f[0x20..0x22], .little) else 0;
                            mem.print("{{\"size_mb\":{d},\"speed_mts\":{d},\"configured_mts\":{d},\"type\":", .{ size_mb, speed, cfg_speed });
                            mem.strOrNull(ddrName(f[0x12]));
                            mem.raw(",\"slot\":");
                            mem.strOrNull(smbiosString(area, f[0x10]));
                            mem.raw(",\"manufacturer\":");
                            mem.strOrNull(smbiosString(area, f[0x17]));
                            mem.raw(",\"part\":");
                            mem.strOrNull(smbiosString(area, f[0x1A]));
                            mem.raw("}");
                        }
                    },
                    else => {},
                }
                off = s + 2;
                if (typ == 127) break;
            }
        }
    }
    mem.raw("]");

    j.raw("\"manufacturer\":");
    j.strOrNull(sys_vendor);
    j.raw(",\"product\":");
    j.strOrNull(sys_product);
    j.raw(",\"board_vendor\":");
    j.strOrNull(board_vendor);
    j.raw(",\"board\":");
    j.strOrNull(board_product);
    j.raw(",\"bios_vendor\":");
    j.strOrNull(bios_vendor);
    j.raw(",\"bios_version\":");
    j.strOrNull(bios_version);
    j.raw(",\"bios_date\":");
    j.strOrNull(bios_date);
    j.raw(",\"cpu\":");
    j.strOrNull(cpu);
    if (cores > 0) j.print(",\"cores\":{d}", .{cores}) else j.raw(",\"cores\":null");
    if (threads > 0) j.print(",\"threads\":{d}", .{threads}) else j.raw(",\"threads\":null");
    j.raw(",\"memory_modules\":");
    j.raw(mem.list.items);
    var ms = MEMORYSTATUSEX{};
    if (GlobalMemoryStatusEx(&ms) != 0) j.print(",\"ram_total_bytes\":{d}", .{ms.ullTotalPhys}) else j.raw(",\"ram_total_bytes\":null");
    var vi: std.os.windows.RTL_OSVERSIONINFOW = undefined;
    vi.dwOSVersionInfoSize = @sizeOf(std.os.windows.RTL_OSVERSIONINFOW);
    if (std.os.windows.ntdll.RtlGetVersion(&vi) == .SUCCESS) {
        j.print(",\"os_major\":{d},\"os_build\":{d}", .{ vi.dwMajorVersion, vi.dwBuildNumber });
    } else j.raw(",\"os_major\":null,\"os_build\":null");
    j.raw("}");
}

/// GET /api/status — everything the UI shows about disks, power and the machine. Read-only.
/// "deep" reads (raw sector for BitLocker, NVMe health) are skipped while a clone is running.
fn buildStatusJsonV2(gpa: std.mem.Allocator, with_system: bool) ?[]u8 {
    var j = Json{ .gpa = gpa };
    errdefer j.deinit();
    const running = g_clone_running.load(.seq_cst);
    const deep = !running and isAdmin();
    var extents: [26]VolExtent = undefined;
    const n_ext = collectVolumeExtents(&extents);
    const b = getBatteryInfo();
    var pct_buf: [8]u8 = undefined;
    j.print("{{\"version\":\"{s}\",\"is_admin\":{s},\"clone_running\":{s},\"battery_pct\":{s},\"ac_online\":{s},\"battery_charging\":{s},\"has_battery\":{s},\"min_c_free_bytes\":{d}", .{
        VERSION,
        if (isAdmin()) "true" else "false",
        if (running) "true" else "false",
        jsonOptU8(b.pct, &pct_buf),
        jsonOptBool(b.ac),
        if (b.chg) "true" else "false",
        if (b.has_battery) "true" else "false",
        MIN_C_FREE_BYTES,
    });
    {
        // v3.0 (F10): settings that change disk speed. Read only; NVMeForge never changes them.
        const pw = diskcheck.queryPower();
        j.raw(",\"power_cfg\":{\"aspm_ac\":");
        if (pw.aspm_ac) |v| j.print("{d}", .{v}) else j.raw("null");
        j.raw(",\"aspm_dc\":");
        if (pw.aspm_dc) |v| j.print("{d}", .{v}) else j.raw("null");
        j.print(",\"mode\":\"{s}\"}}", .{pw.mode});
        j.raw(",\"os_trim\":");
        if (diskcheck.osTrimEnabled()) |t| j.raw(if (t) "true" else "false") else j.raw("null");
        j.print(",\"bench_running\":{s}", .{if (g_bench_running.load(.seq_cst)) "true" else "false"});
    }
    const c_disk_opt = getVolumeDiskNumber('C');
    if (c_disk_opt) |c| j.print(",\"source_disk\":{d}", .{c}) else j.raw(",\"source_disk\":null");
    const c_part = getVolumePartitionBytes('C');
    if (c_part > 0) j.print(",\"c_partition_bytes\":{d}", .{c_part}) else j.raw(",\"c_partition_bytes\":null");
    {
        const c_w = [_:0]u16{ 'C', ':', '\\' };
        var avail: u64 = 0;
        var total: u64 = 0;
        var free: u64 = 0;
        if (GetDiskFreeSpaceExW(&c_w, &avail, &total, &free) != 0 and total >= free) {
            j.print(",\"c_used_bytes\":{d},\"c_free_bytes\":{d}", .{ total - free, free });
        } else j.raw(",\"c_used_bytes\":null,\"c_free_bytes\":null");
    }
    // NVF-E031: which disk (other than the source) already holds a finished clone on W:.
    const marker_disk: ?u32 = blk: {
        const mk = findCloneMarker(null, c_disk_opt) orelse break :blk null;
        break :blk mk.disk;
    };
    j.raw(",\"clone_marker\":");
    j.raw(if (marker_disk != null) "true" else "false");
    if (marker_disk) |md| j.print(",\"clone_marker_disk\":{d}", .{md}) else j.raw(",\"clone_marker_disk\":null");
    // NVF-E009/E039: reserved letters, so the UI can warn before the clone starts.
    j.raw(",\"letters\":[");
    for (RESERVED_LETTERS, 0..) |letter, li| {
        if (li > 0) j.raw(",");
        var ld: ?u32 = null;
        const use = reservedLetterUse(letter, &ld);
        j.print("{{\"letter\":\"{c}\",\"state\":\"{s}\"", .{ letter, @tagName(use) });
        if (ld) |d| j.print(",\"disk\":{d}}}", .{d}) else j.raw(",\"disk\":null}");
    }
    j.raw("]");
    // F4: letters the next clone would use (preferred ones when free, other free letters otherwise).
    if (chooseCloneLetters(GetLogicalDrives(), RESERVED_LETTERS)) |pl| {
        j.print(",\"letters_plan\":\"{c},{c},{c},{c},{c}\"", .{ pl[0], pl[1], pl[2], pl[3], pl[4] });
    } else j.raw(",\"letters_plan\":null");
    j.raw(",\"deep_scan\":");
    j.raw(if (deep) "true" else "false");
    j.raw(",\"disks\":[");
    var first = true;
    var present: [MAX_DISKS]u32 = undefined;
    var n_present: usize = 0;
    var disk: u32 = 0;
    while (disk < MAX_DISKS) : (disk += 1) {
        const h = openPhysicalDrive(disk, 0, 0) orelse continue;
        defer _ = CloseHandle(h);
        if (!first) j.raw(",");
        first = false;
        present[n_present] = disk;
        n_present += 1;
        writeDiskJson(&j, disk, h, extents[0..n_ext], deep);
    }
    j.raw("]");
    // NVF-E038 (v2.7): no fixed target. "target_disk" is only a pre-selection when exactly one disk other
    // than the source is connected; "active_target_disk" is the disk of the clone in progress.
    if (soleCandidate(present[0..n_present], c_disk_opt)) |t| j.print(",\"target_disk\":{d}", .{t}) else j.raw(",\"target_disk\":null");
    const active = targetDisk();
    if (running and active != NO_DISK) j.print(",\"active_target_disk\":{d}", .{active}) else j.raw(",\"active_target_disk\":null");
    if (currentClonePlan()) |plan| {
        const need = plan.requiredBytes();
        j.print(",\"required_target_bytes\":{d},\"min_target_bytes\":{d}", .{ need, need });
    } else j.raw(",\"required_target_bytes\":null,\"min_target_bytes\":null");
    // v2.8: the other partitions of the source disk and whether they are copied.
    j.raw(",\"extra_partitions\":[");
    var extra_bytes: u64 = 0;
    if (c_disk_opt) |cd| {
        var ex: [MAX_EXTRAS]ExtraPart = undefined;
        const re_n: ?u32 = if (findGptPartition(cd, &GUID_WINRE, 300 * MIB)) |rp| rp.number else null;
        const nx = sourceExtras(cd, re_n, &ex);
        for (ex[0..nx], 0..) |e, xi| {
            if (xi > 0) j.raw(",");
            var nb: [128]u8 = undefined;
            const nmu = e.entry.nameUtf8(&nb);
            j.print("{{\"number\":{d},\"bytes\":{d},\"kind\":\"{s}\",\"name\":", .{ e.entry.number, e.entry.bytes, gptKind(&e.entry.type_guid) });
            j.strOrNull(nmu);
            if (e.letter != 0) j.print(",\"letter\":\"{c}:\"", .{e.letter}) else j.raw(",\"letter\":null");
            j.print(",\"copy\":\"{s}\"}}", .{@tagName(e.copy)});
            if (e.copy == .raw) extra_bytes += e.entry.bytes;
        }
    }
    j.print("],\"extra_bytes\":{d}", .{extra_bytes});
    if (with_system) {
        j.raw(",\"system\":");
        writeSystemJson(&j, gpa);
    }
    j.raw("}");
    return j.list.toOwnedSlice(gpa) catch null;
}

// ---------------- Benchmark real (solo lectura) + historial ----------------
const BenchResult = struct { seq_mbs: f64, seq_bytes: u64, seq_secs: f64, iops: f64, lat_us: f64 };

/// Sequential: 4 x 256 MiB at 10/35/60/85 % of the disk, 8 MiB per read. Random: 4 KiB reads at random
/// 4 KiB-aligned offsets, queue depth 1, for 3 s. NO_BUFFERING: never served from the Windows cache.
/// Nothing is ever written. MB/s = 10^6 bytes per second.
fn runRealBenchmark(disk: u32) ?BenchResult {
    const h = openPhysicalDrive(disk, GENERIC_READ, FILE_FLAG_NO_BUFFERING) orelse return null;
    defer _ = CloseHandle(h);
    var path_buf: [64]u8 = undefined;
    const dev = std.fmt.bufPrint(&path_buf, "\\\\.\\PhysicalDrive{d}", .{disk}) catch return null;
    const disk_bytes = getVolumeLengthBytes(dev);
    if (disk_bytes < 2 * 1024 * 1024 * 1024) return null;

    const chunk: u32 = 8 * 1024 * 1024;
    const buf = VirtualAlloc(null, chunk, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return null;
    defer _ = VirtualFree(buf, 0, MEM_RELEASE);

    const region: u64 = 256 * 1024 * 1024;
    const mib: u64 = 1024 * 1024;
    const fractions = [_]u64{ 10, 35, 60, 85 };
    var seq_bytes: u64 = 0;
    var timer = std.time.Timer.start() catch return null;
    for (fractions) |fr| {
        var start = (disk_bytes / 100 * fr) / mib * mib;
        if (start + region > disk_bytes) start = (disk_bytes - region) / mib * mib;
        var done: u64 = 0;
        while (done < region) {
            const n = positionedIo(false, h, @intCast(start + done), buf, chunk, "benchmark_secuencial") orelse return null;
            done += n;
        }
        seq_bytes += done;
    }
    const seq_ns = timer.read();
    if (seq_ns == 0) return null;
    const seq_secs = @as(f64, @floatFromInt(seq_ns)) / 1e9;

    var prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(std.time.milliTimestamp())));
    const rnd = prng.random();
    const blocks = disk_bytes / 4096;
    var ops: u64 = 0;
    timer.reset();
    while (timer.read() < 3 * std.time.ns_per_s) {
        const blk = rnd.uintLessThan(u64, blocks);
        _ = positionedIo(false, h, @intCast(blk * 4096), buf, 4096, "benchmark_aleatorio") orelse return null;
        ops += 1;
    }
    const rnd_secs = @as(f64, @floatFromInt(timer.read())) / 1e9;
    const iops = @as(f64, @floatFromInt(ops)) / rnd_secs;
    return .{
        .seq_mbs = @as(f64, @floatFromInt(seq_bytes)) / 1e6 / seq_secs,
        .seq_bytes = seq_bytes,
        .seq_secs = seq_secs,
        .iops = iops,
        .lat_us = if (iops > 0) 1e6 / iops else 0,
    };
}

fn appendBenchHistory(disk: u32, model: []const u8, r: BenchResult) void {
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, "bench_history.tsv") orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};
    var st = SYSTEMTIME{};
    GetLocalTime(&st);
    var clean: [64]u8 = undefined;
    var cn: usize = 0;
    for (model) |ch| {
        if (cn >= clean.len) break;
        clean[cn] = if (ch == '\t' or ch == '\r' or ch == '\n') ' ' else ch;
        cn += 1;
    }
    var line: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\t{d}\t{s}\t{d:.1}\t{d:.0}\t{d:.1}\r\n", .{
        st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, disk, clean[0..cn], r.seq_mbs, r.iops, r.lat_us,
    }) catch return;
    f.writeAll(s) catch {};
}

fn buildBenchHistoryJson(gpa: std.mem.Allocator) ?[]u8 {
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, "bench_history.tsv") orelse return benchHistoryJsonFromTsv(gpa, "");
    const f = std.fs.cwd().openFile(path, .{}) catch return benchHistoryJsonFromTsv(gpa, "");
    defer f.close();
    const data = f.readToEndAlloc(gpa, 1024 * 1024) catch return benchHistoryJsonFromTsv(gpa, "");
    defer gpa.free(data);
    return benchHistoryJsonFromTsv(gpa, data);
}

/// Pure: bench_history.tsv text -> JSON array, newest first, at most 40 rows, malformed rows skipped.
fn benchHistoryJsonFromTsv(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    var j = Json{ .gpa = gpa };
    errdefer j.deinit();
    j.raw("[");
    var lines: [40][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitBackwardsScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, "\r ");
        if (t.len == 0) continue;
        lines[n] = t;
        n += 1;
        if (n == lines.len) break;
    }
    var first = true;
    for (lines[0..n]) |t| {
        var cols = std.mem.splitScalar(u8, t, '\t');
        const when = cols.next() orelse continue;
        const disk = std.fmt.parseInt(u32, cols.next() orelse continue, 10) catch continue;
        const model = cols.next() orelse continue;
        const seq = std.fmt.parseFloat(f64, cols.next() orelse continue) catch continue;
        const iops = std.fmt.parseFloat(f64, cols.next() orelse continue) catch continue;
        const lat = std.fmt.parseFloat(f64, cols.next() orelse continue) catch continue;
        if (!std.math.isFinite(seq) or !std.math.isFinite(iops) or !std.math.isFinite(lat)) continue;
        if (!first) j.raw(",");
        first = false;
        j.raw("{\"when\":");
        j.str(when);
        j.print(",\"disk\":{d},\"model\":", .{disk});
        j.str(model);
        j.print(",\"seq_mbs\":{d:.1},\"iops\":{d:.0},\"lat_us\":{d:.1}}}", .{ seq, iops, lat });
    }
    j.raw("]");
    return j.list.toOwnedSlice(gpa) catch null;
}

// ---------------- v3.0 (F11): banco de 4 pruebas (diskcheck) ----------------
const GIB: u64 = 1024 * 1024 * 1024;
/// v3.1: test file size, 1 GiB (CrystalDiskMark's default), 4 or 16 GiB. Passes are timed (5 s), so a bigger
/// file spreads the tests over more of the disk (less help from its caches); it does not make writes longer.
fn suiteSizeGib(raw: ?[]const u8) u64 {
    const v = std.fmt.parseInt(u64, raw orelse "1", 10) catch 1;
    return if (v == 4 or v == 16) v else 1;
}
const DRIVE_FIXED: u32 = 3;

const SuiteStart = struct { ok: bool, msg: []const u8 };

/// Validates POST /api/suite-start?disk=N&letter=X&passes=P and launches the run. The letter must be a
/// fixed volume that lives on disk N and has room for the 1 GiB file plus a 2 GiB margin.
fn startSuite(first_line: []const u8, msg_buf: []u8) SuiteStart {
    if (!isAdmin()) return .{ .ok = false, .msg = "La prueba crea un archivo en la raíz de la unidad y necesita permisos de administrador." };
    if (g_clone_running.load(.seq_cst)) return .{ .ok = false, .msg = "Hay una clonación en curso. La prueba se podrá usar cuando termine." };
    const disk = std.fmt.parseInt(u32, queryParam(first_line, "disk") orelse "", 10) catch NO_DISK;
    if (disk >= MAX_DISKS) return .{ .ok = false, .msg = "Falta elegir el disco que se va a medir." };
    const ls = queryParam(first_line, "letter") orelse "";
    if (ls.len != 1 or std.ascii.toUpper(ls[0]) < 'C' or std.ascii.toUpper(ls[0]) > 'Z') return .{ .ok = false, .msg = "Falta elegir la unidad donde se crea el archivo de prueba." };
    const letter = std.ascii.toUpper(ls[0]);
    const passes_raw = std.fmt.parseInt(u8, queryParam(first_line, "passes") orelse "3", 10) catch 3;
    const passes: u8 = if (passes_raw == 1 or passes_raw == 5) passes_raw else 3;
    const file_bytes = suiteSizeGib(queryParam(first_line, "size_gib")) * GIB;
    const ext = volumeExtent(letter) orelse return .{ .ok = false, .msg = std.fmt.bufPrint(msg_buf, "No se pudo leer la unidad {c}:.", .{letter}) catch "No se pudo leer la unidad." };
    if (ext.disk != disk) return .{ .ok = false, .msg = std.fmt.bufPrint(msg_buf, "{c}: no está en el disco {d}.", .{ letter, disk }) catch "La unidad no está en ese disco." };
    var root = [_:0]u16{ letter, ':', '\\' };
    if (GetDriveTypeW(&root) != DRIVE_FIXED) return .{ .ok = false, .msg = std.fmt.bufPrint(msg_buf, "{c}: no es una unidad fija.", .{letter}) catch "No es una unidad fija." };
    var avail: u64 = 0;
    if (GetDiskFreeSpaceExW(&root, &avail, null, null) == 0 or avail < file_bytes + diskcheck.MARGIN_BYTES) {
        return .{ .ok = false, .msg = std.fmt.bufPrint(msg_buf, "[NVF-E042] {c}: necesita al menos {d} GiB libres para la prueba (archivo de {d} GiB más 2 GiB de margen).", .{ letter, file_bytes / GIB + 2, file_bytes / GIB }) catch "[NVF-E042] Falta espacio libre." };
    }
    if (g_bench_running.swap(true, .seq_cst)) return .{ .ok = false, .msg = "Ya hay una prueba de rendimiento en curso." };
    if (g_clone_running.load(.seq_cst)) { // a clone started between the first check and the flag
        g_bench_running.store(false, .seq_cst);
        return .{ .ok = false, .msg = "Hay una clonación en curso." };
    }
    const b = getBatteryInfo();
    diskcheck.on_finish = suiteFinished;
    diskcheck.start(.{ .disk = disk, .letter = letter, .passes = passes, .file_bytes = file_bytes, .on_battery = b.ac != null and !b.ac.? }) catch {
        g_bench_running.store(false, .seq_cst);
        return .{ .ok = false, .msg = "No se pudo iniciar la prueba." };
    };
    return .{ .ok = true, .msg = "Prueba iniciada." };
}

fn suiteProgressJson(buf: []u8) []const u8 {
    const snap = diskcheck.snapshot();
    var esc: [400]u8 = undefined;
    return diskcheck.snapJson(buf, &snap, jsonEscapeInto(&esc, snap.message()));
}

/// Called by diskcheck when a run ends (the temporary file is already closed and deleted).
fn suiteFinished(snap: *const diskcheck.Snap) void {
    defer g_bench_running.store(false, .seq_cst);
    ensureLogDir();
    {
        var l: [200]u8 = undefined;
        if (std.fmt.bufPrint(&l, "BENCH4 disco={d} unidad={c}: pasadas={d} fase={s} {s}", .{ snap.disk, snap.letter, snap.passes, @tagName(snap.phase), snap.message() })) |x| appendRunLog(x) else |_| {}
    }
    if (snap.phase != .done) return;
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, "bench_suite_history.tsv") orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};
    var model: []const u8 = "Disco";
    var mb: [64]u8 = undefined;
    if (getDiskIdentity(snap.disk)) |id| {
        const m = id.product();
        var n: usize = 0;
        for (m) |ch| {
            if (n >= mb.len) break;
            mb[n] = if (ch == '\t' or ch == '\r' or ch == '\n') ' ' else ch;
            n += 1;
        }
        model = mb[0..n];
    }
    var st = SYSTEMTIME{};
    GetLocalTime(&st);
    var line: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line);
    w.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\t{d}\t{s}\t{c}\t{d}", .{ st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, snap.disk, model, snap.letter, snap.passes }) catch return;
    for (snap.read) |c| w.print("\t{d:.2}", .{c.mbs}) catch return;
    for (snap.write) |c| w.print("\t{d:.2}", .{c.mbs}) catch return;
    {
        const r1 = if (snap.temp_max) |t| w.print("\t{d}", .{t}) else w.writeAll("\t-");
        r1 catch return;
        const r2 = if (snap.throttleEvents()) |t| w.print("\t{d}", .{t}) else w.writeAll("\t-");
        r2 catch return;
    }
    w.print("\t{s}\t{d}\r\n", .{ if (snap.on_battery) "bateria" else "cargador", snap.file_bytes >> 20 }) catch return;
    f.writeAll(w.buffered()) catch {};
}

fn buildSuiteHistoryJson(gpa: std.mem.Allocator) ?[]u8 {
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, "bench_suite_history.tsv") orelse return suiteHistoryJsonFromTsv(gpa, "");
    const f = std.fs.cwd().openFile(path, .{}) catch return suiteHistoryJsonFromTsv(gpa, "");
    defer f.close();
    const data = f.readToEndAlloc(gpa, 1024 * 1024) catch return suiteHistoryJsonFromTsv(gpa, "");
    defer gpa.free(data);
    return suiteHistoryJsonFromTsv(gpa, data);
}

/// Pure: bench_suite_history.tsv -> JSON array, newest first, at most 30 rows, malformed rows skipped.
fn suiteHistoryJsonFromTsv(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    var j = Json{ .gpa = gpa };
    errdefer j.deinit();
    j.raw("[");
    var lines: [30][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitBackwardsScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, "\r ");
        if (t.len == 0) continue;
        lines[n] = t;
        n += 1;
        if (n == lines.len) break;
    }
    var first = true;
    row: for (lines[0..n]) |t| {
        var cols: [17][]const u8 = undefined; // v3.1: 17th = file size in MiB (older rows: 16 columns = 1 GiB)
        var k: usize = 0;
        var cit = std.mem.splitScalar(u8, t, '\t');
        while (cit.next()) |c| {
            if (k == cols.len) continue :row;
            cols[k] = c;
            k += 1;
        }
        if (k != 16 and k != 17) continue;
        const size_mib: u64 = if (k == 17) std.fmt.parseInt(u64, cols[16], 10) catch continue else 1024;
        const disk = std.fmt.parseInt(u32, cols[1], 10) catch continue;
        const passes = std.fmt.parseInt(u8, cols[4], 10) catch continue;
        if (cols[3].len != 1 or cols[3][0] < 'A' or cols[3][0] > 'Z') continue;
        var vals: [8]f64 = undefined;
        for (0..8) |i| {
            vals[i] = std.fmt.parseFloat(f64, cols[5 + i]) catch continue :row;
            if (!std.math.isFinite(vals[i])) continue :row;
        }
        if (!first) j.raw(",");
        first = false;
        j.raw("{\"when\":");
        j.str(cols[0]);
        j.print(",\"disk\":{d},\"model\":", .{disk});
        j.str(cols[2]);
        j.print(",\"letter\":\"{s}:\",\"passes\":{d},\"read\":[{d:.2},{d:.2},{d:.2},{d:.2}],\"write\":[{d:.2},{d:.2},{d:.2},{d:.2}]", .{ cols[3], passes, vals[0], vals[1], vals[2], vals[3], vals[4], vals[5], vals[6], vals[7] });
        const tmax = std.fmt.parseInt(i32, cols[13], 10) catch null;
        const thr = std.fmt.parseInt(u64, cols[14], 10) catch null;
        j.raw(",\"temp_max_c\":");
        if (tmax) |v| j.print("{d}", .{v}) else j.raw("null");
        j.raw(",\"throttle_events\":");
        if (thr) |v| j.print("{d}", .{v}) else j.raw("null");
        j.print(",\"on_battery\":{s},\"size_mib\":{d}}}", .{ if (std.mem.eql(u8, cols[15], "bateria")) "true" else "false", size_mib });
    }
    j.raw("]");
    return j.list.toOwnedSlice(gpa) catch null;
}

/// GET /api/run-summary — clone_run.log without the per-400 ms progress lines (only the last one kept),
/// so the UI can show every real event of the run: commands, checks, verification, result.
fn buildRunSummary(gpa: std.mem.Allocator, run: ?[]const u8) ?[]u8 {
    const data = readRunFileAlloc(gpa, run, 8 * 1024 * 1024) orelse return null;
    defer gpa.free(data);
    return filterRunLog(gpa, data);
}

/// Pure: drops the per-400 ms progress lines of a clone_run.log (keeping the last one of each burst)
/// and returns the newest 48 KB of real events.
fn filterRunLog(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var last_progress: []const u8 = "";
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |ln| {
        const t = std.mem.trimRight(u8, ln, "\r");
        if (t.len == 0) continue;
        const is_progress = std.mem.indexOf(u8, t, "Etapa 5/7: Clonación DMA Nativa (") != null or
            std.mem.indexOf(u8, t, "Etapa 5/7: Verificación completa de la copia (") != null;
        if (is_progress) {
            last_progress = t;
            continue;
        }
        if (last_progress.len > 0) {
            out.appendSlice(gpa, last_progress) catch {};
            out.append(gpa, '\n') catch {};
            last_progress = "";
        }
        out.appendSlice(gpa, t) catch {};
        out.append(gpa, '\n') catch {};
    }
    if (last_progress.len > 0) {
        out.appendSlice(gpa, last_progress) catch {};
        out.append(gpa, '\n') catch {};
    }
    // Keep the newest 48 KB.
    const keep: usize = 48 * 1024;
    if (out.items.len > keep) {
        const cut = out.items.len - keep;
        const nl = std.mem.indexOfScalarPos(u8, out.items, cut, '\n') orelse cut;
        const tail = out.items[nl + 1 ..];
        const res = gpa.dupe(u8, tail) catch return null;
        out.deinit(gpa);
        return res;
    }
    return out.toOwnedSlice(gpa) catch null;
}

fn sendHttpStatus(stream: std.net.Stream, status: []const u8, content_type: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
        .{ status, content_type, body.len },
    ) catch return;
    stream.writeAll(hdr) catch return;
    stream.writeAll(body) catch return;
}

/// Value of an HTTP request header (case-insensitive name), or null.
fn headerValue(req: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, req, "\r\n");
    _ = it.next(); // request line
    while (it.next()) |ln| {
        if (ln.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, ln, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, ln[0..colon], " "), name)) return std.mem.trim(u8, ln[colon + 1 ..], " \t");
    }
    return null;
}

/// NVF-E032: only NVMeForge's own page may drive the backend. Any web page open in the browser could
/// otherwise send "POST http://127.0.0.1:8999/api/start-clone" and wipe Disk 1.
///  - Host must be 127.0.0.1:8999 / localhost:8999 (blocks DNS rebinding).
///  - POST needs "X-NVMeForge: 1": a custom header forces a CORS preflight that this server never
///    approves, so other origins can never send it; and Origin, when present, must be our own.
fn requestAllowed(req: []const u8, is_post: bool) bool {
    const host = headerValue(req, "Host") orelse return false;
    if (!std.mem.eql(u8, host, "127.0.0.1:8999") and !std.mem.eql(u8, host, "localhost:8999")) return false;
    if (!is_post) return true;
    const token = headerValue(req, "X-NVMeForge") orelse return false;
    if (!std.mem.eql(u8, token, "1")) return false;
    if (headerValue(req, "Origin")) |o| {
        if (!std.mem.eql(u8, o, "http://127.0.0.1:8999") and !std.mem.eql(u8, o, "http://localhost:8999")) return false;
    }
    return true;
}

// ============================================================================================
// v2.6.0 — temperatura genérica, historial de clones, cambios en C: desde el clon (diario USN de
// NTFS) e historial de corridas. Todo de solo lectura salvo el archivo de historial en logs\.
// ============================================================================================

const TempInfo = struct { temp_c: i16, warn_c: i16, crit_c: i16 };

/// StorageDeviceTemperatureProperty (51): generic Windows temperature query (works for many disks that do
/// not answer the NVMe health log). Implausible values are discarded.
fn queryTemperatureProperty(h: HANDLE) ?TempInfo {
    var q = [_]u8{0} ** 12;
    std.mem.writeInt(u32, q[0..4], 51, .little);
    var out: [512]u8 align(8) = @splat(0);
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, q.len, &out, out.len, &ret, null) == 0 or ret < 40) return null;
    const count = std.mem.readInt(u16, out[12..14], .little);
    if (count == 0) return null;
    const t = std.mem.readInt(i16, out[26..28], .little);
    if (t < -20 or t > 120) return null;
    return .{
        .temp_c = t,
        .warn_c = std.mem.readInt(i16, out[10..12], .little),
        .crit_c = std.mem.readInt(i16, out[8..10], .little),
    };
}

// ---------------- Diario USN de NTFS (cambios en C: desde el clon) ----------------
const FSCTL_QUERY_USN_JOURNAL: u32 = 0x000900F4;
const FSCTL_READ_USN_JOURNAL: u32 = 0x000900BB;
const ERROR_JOURNAL_ENTRY_DELETED: u32 = 1181;
const ERROR_JOURNAL_NOT_ACTIVE: u32 = 1179;

const UsnState = struct { journal_id: u64, first_usn: i64, next_usn: i64 };

fn openVolumeForJournal(letter: u8) ?HANDLE {
    var path = [_:0]u16{ '\\', '\\', '.', '\\', letter, ':' };
    const h = CreateFileW(&path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    return h;
}

fn queryUsnJournal(h: HANDLE) ?UsnState {
    var out: [80]u8 align(8) = @splat(0);
    var ret: u32 = 0;
    if (DeviceIoControl(h, FSCTL_QUERY_USN_JOURNAL, null, 0, &out, out.len, &ret, null) == 0 or ret < 24) return null;
    return .{
        .journal_id = std.mem.readInt(u64, out[0..8], .little),
        .first_usn = std.mem.readInt(i64, out[8..16], .little),
        .next_usn = std.mem.readInt(i64, out[16..24], .little),
    };
}

// Journal position of C: captured right after the VSS snapshot of the running clone.
var g_clone_usn_mutex: std.Thread.Mutex = .{};
var g_clone_usn: ?UsnState = null;

const UsnChanges = struct { files: u64, records: u64, truncated: bool };
const UsnError = error{ Wrapped, JournalChanged, NotActive, ReadFailed, OutOfMemory };

/// Parses one FSCTL_READ_USN_JOURNAL output buffer (8-byte next USN + USN_RECORD_V2/V3 records).
/// Calls `sink` with a per-file key for every record whose USN is < end_usn. Returns false when end_usn
/// was reached. Pure (no I/O) so it can be unit-tested.
fn parseUsnBuffer(buf: []const u8, end_usn: i64, ctx: anytype, comptime sink: fn (@TypeOf(ctx), u64) void) bool {
    var off: usize = 8;
    while (off + 60 <= buf.len) {
        const rl = std.mem.readInt(u32, buf[off..][0..4], .little);
        if (rl < 60 or off + rl > buf.len) break;
        const major = std.mem.readInt(u16, buf[off + 4 ..][0..2], .little);
        const usn: i64 = if (major >= 3) std.mem.readInt(i64, buf[off + 40 ..][0..8], .little) else std.mem.readInt(i64, buf[off + 24 ..][0..8], .little);
        if (usn >= end_usn) return false;
        const key: u64 = if (major >= 3)
            std.mem.readInt(u64, buf[off + 8 ..][0..8], .little) ^ (std.mem.readInt(u64, buf[off + 16 ..][0..8], .little) *% 0x9E3779B97F4A7C15)
        else
            std.mem.readInt(u64, buf[off + 8 ..][0..8], .little);
        sink(ctx, key);
        off += rl;
    }
    return true;
}

const UsnCounter = struct {
    set: std.AutoHashMap(u64, void),
    records: u64 = 0,
    fn add(self: *UsnCounter, key: u64) void {
        self.records += 1;
        self.set.put(key, {}) catch {};
    }
};

/// Counts the distinct files of C: changed since `since` (journal position saved at clone time).
/// Read-only; stops after 4 s or 20 M records (truncated = true).
fn countUsnChangesSince(gpa: std.mem.Allocator, since: UsnState) UsnError!UsnChanges {
    const h = openVolumeForJournal('C') orelse return error.ReadFailed;
    defer _ = CloseHandle(h);
    const now = queryUsnJournal(h) orelse {
        return if (GetLastError() == ERROR_JOURNAL_NOT_ACTIVE) error.NotActive else error.ReadFailed;
    };
    if (now.journal_id != since.journal_id) return error.JournalChanged;
    if (since.next_usn < now.first_usn) return error.Wrapped;
    const buf = VirtualAlloc(null, 65536, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse return error.OutOfMemory;
    defer _ = VirtualFree(buf, 0, MEM_RELEASE);
    var counter = UsnCounter{ .set = std.AutoHashMap(u64, void).init(gpa) };
    defer counter.set.deinit();
    var input: [40]u8 align(8) = @splat(0);
    var usn = since.next_usn;
    var truncated = false;
    var timer = std.time.Timer.start() catch return error.ReadFailed;
    while (usn < now.next_usn) {
        std.mem.writeInt(i64, input[0..8], usn, .little);
        std.mem.writeInt(u32, input[8..12], 0xFFFFFFFF, .little); // every reason
        std.mem.writeInt(u32, input[12..16], 0, .little);
        std.mem.writeInt(u64, input[16..24], 0, .little); // no wait
        std.mem.writeInt(u64, input[24..32], 0, .little);
        std.mem.writeInt(u64, input[32..40], since.journal_id, .little);
        var ret: u32 = 0;
        if (DeviceIoControl(h, FSCTL_READ_USN_JOURNAL, &input, input.len, buf, 65536, &ret, null) == 0) {
            return if (GetLastError() == ERROR_JOURNAL_ENTRY_DELETED) error.Wrapped else error.ReadFailed;
        }
        if (ret <= 8) break;
        const next = std.mem.readInt(i64, buf[0..8], .little);
        const more = parseUsnBuffer(buf[0..ret], now.next_usn, &counter, UsnCounter.add);
        if (!more or next <= usn) break;
        usn = next;
        if (timer.read() > 4 * std.time.ns_per_s or counter.records > 20_000_000) {
            truncated = true;
            break;
        }
    }
    return .{ .files = counter.set.count(), .records = counter.records, .truncated = truncated };
}

// ---------------- Historial de clones (logs\clones.tsv) ----------------
// when \t model \t target_bytes \t copied_bytes \t status \t journal_id \t usn
fn appendCloneHistory(model: []const u8, target_bytes: u64, copied: u64, status: []const u8, usn: ?UsnState, secs: u64, basis: u64) void {
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, "clones.tsv") orelse return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch {};
    var st = SYSTEMTIME{};
    GetLocalTime(&st);
    var clean_model: [96]u8 = undefined;
    var cm: usize = 0;
    for (model) |ch| {
        if (cm >= clean_model.len) break;
        clean_model[cm] = if (ch == '\t' or ch == '\r' or ch == '\n') ' ' else ch;
        cm += 1;
    }
    var clean_status: [64]u8 = undefined;
    var cs: usize = 0;
    for (status) |ch| {
        if (cs >= clean_status.len) break;
        clean_status[cs] = if (ch == '\t' or ch == '\r' or ch == '\n') ' ' else ch;
        cs += 1;
    }
    var line: [400]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\t{d}\r\n", .{
        st.wYear,                 st.wMonth,                     st.wDay, st.wHour, st.wMinute, st.wSecond,
        clean_model[0..cm],       target_bytes,                  copied,  clean_status[0..cs],
        if (usn) |u| u.journal_id else 0, if (usn) |u| u.next_usn else 0, secs, basis,
    }) catch return;
    f.writeAll(s) catch {};
}

const CloneRecord = struct { when: []const u8, model: []const u8, target_bytes: u64, copied: u64, status: []const u8, usn: ?UsnState, secs: u64 = 0, basis: u64 = 0 };

fn parseCloneLine(t: []const u8) ?CloneRecord {
    var cols = std.mem.splitScalar(u8, t, '\t');
    const when = cols.next() orelse return null;
    const model = cols.next() orelse return null;
    const tb = std.fmt.parseInt(u64, cols.next() orelse return null, 10) catch return null;
    const cp = std.fmt.parseInt(u64, cols.next() orelse return null, 10) catch return null;
    const status = cols.next() orelse return null;
    const jid = std.fmt.parseInt(u64, cols.next() orelse return null, 10) catch return null;
    const usn = std.fmt.parseInt(i64, cols.next() orelse return null, 10) catch return null;
    if (when.len < 19) return null;
    // v3.0.1: optional 8th column = duration of the whole run in seconds (older lines do not have it).
    const secs = if (cols.next()) |c| std.fmt.parseInt(u64, c, 10) catch 0 else 0;
    const basis = if (cols.next()) |c| std.fmt.parseInt(u64, c, 10) catch 0 else 0;
    return .{ .when = when, .model = model, .target_bytes = tb, .copied = cp, .status = status, .usn = if (jid != 0) UsnState{ .journal_id = jid, .first_usn = 0, .next_usn = usn } else null, .secs = secs, .basis = basis };
}

/// Pure: clones.tsv -> JSON array, newest first, at most 50.
fn cloneHistoryJson(gpa: std.mem.Allocator, data: []const u8) ?[]u8 {
    var j = Json{ .gpa = gpa };
    errdefer j.deinit();
    j.raw("[");
    var it = std.mem.splitBackwardsScalar(u8, data, '\n');
    var n: usize = 0;
    while (it.next()) |ln| {
        const t = std.mem.trim(u8, ln, "\r ");
        const r = parseCloneLine(t) orelse continue;
        if (n > 0) j.raw(",");
        j.raw("{\"when\":");
        j.str(r.when);
        j.raw(",\"model\":");
        j.str(r.model);
        j.print(",\"target_bytes\":{d},\"copied_bytes\":{d},\"status\":", .{ r.target_bytes, r.copied });
        j.str(r.status);
        j.raw(",\"tracks_changes\":");
        j.raw(if (r.usn != null) "true" else "false");
        if (r.secs > 0) j.print(",\"secs\":{d}", .{r.secs}) else j.raw(",\"secs\":null");
        if (r.basis > 0) j.print(",\"basis_bytes\":{d}", .{r.basis}) else j.raw(",\"basis_bytes\":null");
        j.raw("}");
        n += 1;
        if (n == 50) break;
    }
    j.raw("]");
    return j.list.toOwnedSlice(gpa) catch null;
}

fn readLogFileAlloc(gpa: std.mem.Allocator, name: []const u8, max: usize) ?[]u8 {
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, name) orelse return null;
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    return f.readToEndAlloc(gpa, max) catch null;
}

/// GET /api/changes — files of C: changed since the newest clone that recorded a journal position.
fn buildChangesJson(gpa: std.mem.Allocator) ?[]u8 {
    var j = Json{ .gpa = gpa };
    errdefer j.deinit();
    const data = readLogFileAlloc(gpa, "clones.tsv", 1024 * 1024) orelse {
        j.raw("{\"ok\":false,\"reason\":\"sin_clones\"}");
        return j.list.toOwnedSlice(gpa) catch null;
    };
    defer gpa.free(data);
    var latest: ?CloneRecord = null;
    var it = std.mem.splitBackwardsScalar(u8, data, '\n');
    while (it.next()) |ln| {
        if (parseCloneLine(std.mem.trim(u8, ln, "\r "))) |r| {
            if (r.usn != null) {
                latest = r;
                break;
            }
        }
    }
    const r = latest orelse {
        j.raw("{\"ok\":false,\"reason\":\"sin_clones\"}");
        return j.list.toOwnedSlice(gpa) catch null;
    };
    j.raw("{\"when\":");
    j.str(r.when);
    j.raw(",\"model\":");
    j.str(r.model);
    if (!isAdmin()) {
        j.raw(",\"ok\":false,\"reason\":\"admin\"}");
        return j.list.toOwnedSlice(gpa) catch null;
    }
    if (countUsnChangesSince(gpa, r.usn.?)) |c| {
        j.print(",\"ok\":true,\"files\":{d},\"records\":{d},\"truncated\":{s}}}", .{ c.files, c.records, if (c.truncated) "true" else "false" });
    } else |e| {
        j.raw(",\"ok\":false,\"reason\":");
        j.str(switch (e) {
            error.Wrapped => "demasiados_cambios",
            error.JournalChanged => "diario_reiniciado",
            error.NotActive => "diario_inactivo",
            else => "lectura",
        });
        j.raw("}");
    }
    return j.list.toOwnedSlice(gpa) catch null;
}

// ---------------- Historial de corridas (logs\runs) ----------------
/// Only names produced by archivePreviousRunLog are accepted (no paths, no "..").
fn validRunName(name: []const u8) bool {
    if (name.len < 15 or name.len > 64) return false;
    if (!std.mem.startsWith(u8, name, "clone_run_") or !std.mem.endsWith(u8, name, ".log")) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.')) return false;
    return true;
}

fn readRunFileAlloc(gpa: std.mem.Allocator, run: ?[]const u8, max: usize) ?[]u8 {
    var name_buf: [96]u8 = undefined;
    const rel = if (run) |r| (std.fmt.bufPrint(&name_buf, "runs\\{s}", .{r}) catch return null) else "clone_run.log";
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, rel) orelse return null;
    const f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const end = f.getEndPos() catch return null;
    if (end > max) f.seekTo(end - max) catch {};
    return f.readToEndAlloc(gpa, max) catch null;
}

fn buildRunsJson(gpa: std.mem.Allocator) ?[]u8 {
    var j = Json{ .gpa = gpa };
    errdefer j.deinit();
    j.raw("[");
    var runs_buf: [512]u8 = undefined;
    const runs_dir = getLogPath(&runs_buf, "runs") orelse {
        j.raw("]");
        return j.list.toOwnedSlice(gpa) catch null;
    };
    var names: [64][64]u8 = undefined;
    var lens: [64]usize = undefined;
    var count: usize = 0;
    if (std.fs.cwd().openDir(runs_dir, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .file or !validRunName(e.name) or count == names.len) continue;
            @memcpy(names[count][0..e.name.len], e.name);
            lens[count] = e.name.len;
            count += 1;
        }
    } else |_| {}
    // Newest first (names sort chronologically).
    var emitted: usize = 0;
    var used = [_]bool{false} ** 64;
    while (emitted < count) : (emitted += 1) {
        var best: ?usize = null;
        for (0..count) |i| {
            if (used[i]) continue;
            if (best == null or std.mem.order(u8, names[i][0..lens[i]], names[best.?][0..lens[best.?]]) == .gt) best = i;
        }
        const b = best orelse break;
        used[b] = true;
        if (emitted > 0) j.raw(",");
        j.str(names[b][0..lens[b]]);
    }
    j.raw("]");
    return j.list.toOwnedSlice(gpa) catch null;
}

fn sendHttpResponse(stream: std.net.Stream, content_type: []const u8, body: []const u8) void {
    var hdr_buf: [512]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        .{ content_type, body.len },
    ) catch return;
    stream.writeAll(hdr) catch return;
    stream.writeAll(body) catch return;
}

fn handleClient(alloc: std.mem.Allocator, stream: std.net.Stream) void {
    var req_buf: [4096]u8 = undefined;
    var net_reader = stream.reader(&.{});
    var iov: [1][]u8 = .{&req_buf};
    const n = net_reader.interface().readVec(&iov) catch return;
    if (n == 0) return;
    const req = req_buf[0..n];
    var lines = std.mem.splitSequence(u8, req, "\r\n");
    const first_line = lines.next() orelse "";

    // NVF-E032: reject anything that is not NVMeForge's own page (see requestAllowed).
    if (!requestAllowed(req, std.mem.startsWith(u8, first_line, "POST "))) {
        sendHttpStatus(stream, "403 Forbidden", "text/plain; charset=utf-8", "NVMeForge: solicitud rechazada. Solo la interfaz local de NVMeForge puede usar esta API.");
        return;
    }

    // NVF-E033: track whether an NVMeForge window is still alive.
    if (std.mem.startsWith(u8, first_line, "POST /api/ui-closed")) {
        g_ui_closed_ms.store(std.time.milliTimestamp(), .seq_cst);
        sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":true}");
        return;
    }
    g_last_ui_ms.store(std.time.milliTimestamp(), .seq_cst);

    if (std.mem.startsWith(u8, first_line, "GET /favicon.ico")) {
        sendHttpResponse(stream, "image/x-icon", ICO_FILE);
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/power")) {
        var buf: [256]u8 = undefined;
        sendHttpResponse(stream, "application/json; charset=utf-8", buildPowerJson(&buf));
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/status")) {
        const with_system = std.mem.indexOf(u8, first_line, "system=1") != null;
        if (buildStatusJsonV2(alloc, with_system)) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "application/json; charset=utf-8", body);
        } else sendHttpStatus(stream, "500 Internal Server Error", "application/json; charset=utf-8", "{\"error\":\"status\"}");
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/bench-history")) {
        if (buildBenchHistoryJson(alloc)) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "application/json; charset=utf-8", body);
        } else sendHttpResponse(stream, "application/json; charset=utf-8", "[]");
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/runs")) {
        if (buildRunsJson(alloc)) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "application/json; charset=utf-8", body);
        } else sendHttpResponse(stream, "application/json; charset=utf-8", "[]");
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/clones")) {
        const data = readLogFileAlloc(alloc, "clones.tsv", 1024 * 1024);
        defer if (data) |d| alloc.free(d);
        if (cloneHistoryJson(alloc, data orelse "")) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "application/json; charset=utf-8", body);
        } else sendHttpResponse(stream, "application/json; charset=utf-8", "[]");
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/changes")) {
        if (buildChangesJson(alloc)) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "application/json; charset=utf-8", body);
        } else sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"reason\":\"lectura\"}");
        return;
    }

    // ?run=<archived run name> selects logs\runs\<name>; without it, the current run.
    const run_param: ?[]const u8 = if (queryParam(first_line, "run")) |r| (if (validRunName(r)) r else null) else null;
    if (queryParam(first_line, "run") != null and run_param == null) {
        sendHttpStatus(stream, "400 Bad Request", "text/plain; charset=utf-8", "Nombre de corrida no válido.");
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/run-summary")) {
        if (buildRunSummary(alloc, run_param)) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "text/plain; charset=utf-8", body);
        } else sendHttpResponse(stream, "text/plain; charset=utf-8", "");
        return;
    }

    if (run_param != null and std.mem.startsWith(u8, first_line, "GET /api/log")) {
        if (readRunFileAlloc(alloc, run_param, 64 * 1024)) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "text/plain; charset=utf-8", body);
        } else sendHttpResponse(stream, "text/plain; charset=utf-8", "");
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/log")) {
        // Live run log for the UI panel "Registro en vivo": status line of the running external
        // command (watchdog counters) + last ~12 KB of %TEMP%\NVMeForge\logs\clone_run.log.
        var out: [14336]u8 = undefined;
        var w: usize = 0;
        {
            g_cmd_mutex.lock();
            defer g_cmd_mutex.unlock();
            const hdr = if (g_cmd_name_len > 0)
                std.fmt.bufPrint(out[0..], "▶ EN CURSO: {s} · {d} s · sin actividad {d} s\n", .{ g_cmd_name_buf[0..g_cmd_name_len], g_cmd_elapsed_s, g_cmd_idle_s }) catch ""
            else
                std.fmt.bufPrint(out[0..], "■ Sin comando externo en curso\n", .{}) catch "";
            w = hdr.len;
        }
        var path_buf: [512]u8 = undefined;
        if (getLogPath(&path_buf, "clone_run.log")) |path| {
            if (std.fs.cwd().openFile(path, .{})) |f| {
                defer f.close();
                const room = out.len - w;
                const end = f.getEndPos() catch 0;
                if (end > room) f.seekTo(end - room) catch {};
                const n_log = f.readAll(out[w..]) catch 0;
                w += n_log;
            } else |_| {}
        }
        sendHttpResponse(stream, "text/plain; charset=utf-8", out[0..w]);
        return;
    }

    if (std.mem.startsWith(u8, first_line, "GET /api/progress")) {
        var buf: [2048]u8 = undefined;
        sendHttpResponse(stream, "application/json; charset=utf-8", getProgressJson(&buf));
        return;
    }

    if (std.mem.startsWith(u8, first_line, "POST /api/open-app-window")) {
        _ = openDesktopWindow(alloc);
        sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":true,\"message\":\"Ventana dedicada de escritorio NVMeForge abierta.\"}");
        return;
    }

    if (std.mem.startsWith(u8, first_line, "POST /api/shutdown")) {
        sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":true}");
        g_shutdown_requested.store(true, .seq_cst);
        Sleep(20);
        std.process.exit(0);
    }

    if (std.mem.startsWith(u8, first_line, "POST /api/elevate")) {
        if (isAdmin()) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":true,\"message\":\"NVMeForge.exe ya está ejecutándose como Administrador.\"}");
            return;
        }
        sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":true,\"message\":\"Solicitud UAC enviada para NVMeForge.exe.\"}");
        _ = elevateSelf(alloc, "--rebind-admin");
        return;
    }

    // v2.9.2: "quiero reclonarlo" from the UI: removes the NVF-E031 marker of the chosen target only.
    if (std.mem.startsWith(u8, first_line, "POST /api/clear-marker")) {
        if (!isAdmin() or g_clone_running.load(.seq_cst)) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Necesita administrador y que no haya una clonación en curso.\"}");
            return;
        }
        const d = std.fmt.parseInt(u32, queryParam(first_line, "disk") orelse "", 10) catch NO_DISK;
        const c_disk = getVolumeDiskNumber('C');
        if (!validTargetChoice(d, c_disk)) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Ese disco no puede ser el destino.\"}");
            return;
        }
        const mk = findCloneMarker(d, c_disk) orelse {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":true,\"message\":\"Ese disco ya no tiene la marca.\"}");
            return;
        };
        var pb: [40]u8 = undefined;
        const pth = std.fmt.bufPrint(&pb, "{c}:\\{s}", .{ mk.letter, CLONE_MARKER_NAME }) catch return;
        const ok = blk: {
            std.fs.deleteFileAbsolute(pth) catch break :blk false;
            break :blk true;
        };
        ensureLogDir();
        var l: [96]u8 = undefined;
        if (std.fmt.bufPrint(&l, "MARCA borrada por el usuario (quiere reclonar): {s} -> {s}", .{ pth, if (ok) "OK" else "NO SE PUDO" })) |x| appendRunLog(x) else |_| {}
        sendHttpResponse(stream, "application/json; charset=utf-8", if (ok) "{\"ok\":true,\"message\":\"Marca borrada: ya puedes volver a clonar ese disco.\"}" else "{\"ok\":false,\"message\":\"No se pudo borrar la marca.\"}");
        return;
    }

    if (std.mem.startsWith(u8, first_line, "POST /api/start-clone")) {
        // v2.5: the UI must already run as Administrator (no blind auto-start after a UAC relaunch) and
        // must send the identity of the target the user confirmed (NVF-E035).
        if (!isAdmin()) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"need_admin\":true,\"message\":\"Primero da permisos de administrador (botón Pedir) y vuelve a confirmar la clonación.\"}");
            return;
        }
        // NVF-E045: g_starting closes the double-POST race: two simultaneous requests would
        // overwrite g_expect_*/g_slowack_set before the worker reads them. The worker lowers it
        // right after capturing the flags (or the spawn cleanup below does, if it never runs).
        if (g_clone_running.load(.seq_cst) or g_starting.swap(true, .seq_cst)) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Ya hay una clonación en curso.\"}");
            return;
        }
        if (g_bench_running.load(.seq_cst)) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Hay una prueba de rendimiento en curso. Espera a que termine o cancélala en Rendimiento.\"}");
            g_starting.store(false, .seq_cst);
            return;
        }
        const bytes_s = queryParam(first_line, "bytes") orelse "";
        const model_s = queryParam(first_line, "model") orelse "";
        const disk_s = queryParam(first_line, "disk") orelse "";
        const slow_s = queryParam(first_line, "slow_ok") orelse "";
        const exp_bytes = std.fmt.parseInt(u64, bytes_s, 10) catch 0;
        const exp_disk = std.fmt.parseInt(u32, disk_s, 10) catch NO_DISK;
        var model_dec: [96]u8 = undefined;
        const exp_model = percentDecode(model_s, &model_dec);
        if (exp_bytes == 0 or exp_model.len == 0 or exp_disk == NO_DISK) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Falta la identidad del disco confirmado. Recarga la ventana y vuelve a confirmar.\"}");
            g_starting.store(false, .seq_cst);
            return;
        }
        // NVF-E038: the chosen disk must exist and must not be the disk of the running Windows.
        if (!validTargetChoice(exp_disk, getVolumeDiskNumber('C'))) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Ese disco no puede ser el destino: es el disco de Windows o no existe. Elige otro disco.\"}");
            g_starting.store(false, .seq_cst);
            return;
        }
        g_target_disk.store(exp_disk, .seq_cst);
        {
            g_expect_mutex.lock();
            defer g_expect_mutex.unlock();
            g_expect_bytes = exp_bytes;
            @memcpy(g_expect_model_buf[0..exp_model.len], exp_model);
            g_expect_model_len = exp_model.len;
            g_expect_set = true;
        }
        // NVF-E045: explicit slow-link confirmation for this run only (consumed by the worker).
        if (std.mem.eql(u8, slow_s, "1")) {
            g_slowack_mutex.lock();
            g_slowack_set = true;
            g_slowack_mutex.unlock();
        }
        updateProgress("Iniciando la clonación", "Comprobando el disco destino confirmado...", 6.0, 0.0, false);
        sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":true,\"message\":\"Clonación iniciada.\"}");
        const t = std.Thread.spawn(.{}, cloneWorkerThread, .{}) catch {
            // The worker never ran: drop this run's flags so nothing stays armed (one confirmation = one run).
            g_starting.store(false, .seq_cst);
            g_slowack_mutex.lock();
            g_slowack_set = false;
            g_slowack_mutex.unlock();
            g_expect_mutex.lock();
            g_expect_set = false;
            g_expect_mutex.unlock();
            return;
        };
        t.detach();
        return;
    }

    // v3.0 (F11): 4-test benchmark on a temporary file. Routes named /api/suite* so they never match the
    // older "POST /api/bench" prefix.
    if (std.mem.startsWith(u8, first_line, "GET /api/health-history")) {
        const data = readLogFileAlloc(alloc, "health_history.tsv", 4 * 1024 * 1024);
        defer if (data) |d| alloc.free(d);
        if (healthHistoryJsonFromTsv(alloc, data orelse "")) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "application/json; charset=utf-8", body);
        } else sendHttpResponse(stream, "application/json; charset=utf-8", "[]");
        return;
    }
    if (std.mem.startsWith(u8, first_line, "GET /api/suite-history")) {
        if (buildSuiteHistoryJson(alloc)) |body| {
            defer alloc.free(body);
            sendHttpResponse(stream, "application/json; charset=utf-8", body);
        } else sendHttpResponse(stream, "application/json; charset=utf-8", "[]");
        return;
    }
    if (std.mem.startsWith(u8, first_line, "GET /api/suite")) {
        var buf: [3072]u8 = undefined;
        sendHttpResponse(stream, "application/json; charset=utf-8", suiteProgressJson(&buf));
        return;
    }
    if (std.mem.startsWith(u8, first_line, "POST /api/suite-cancel")) {
        diskcheck.requestCancel();
        sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":true}");
        return;
    }
    if (std.mem.startsWith(u8, first_line, "POST /api/suite-start")) {
        var msg_buf: [256]u8 = undefined;
        const r = startSuite(first_line, &msg_buf);
        var esc: [400]u8 = undefined;
        var out: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&out, "{{\"ok\":{s},\"message\":\"{s}\"}}", .{ if (r.ok) "true" else "false", jsonEscapeInto(&esc, r.msg) }) catch "{\"ok\":false}";
        sendHttpResponse(stream, "application/json; charset=utf-8", body);
        return;
    }

    if (std.mem.startsWith(u8, first_line, "POST /api/bench")) {
        // v2.4: real, read-only benchmark of the chosen disk (?disk=N). No invented write speed or IOPS.
        if (g_clone_running.load(.seq_cst)) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Hay una clonación en curso. El benchmark se podrá usar cuando termine.\"}");
            return;
        }
        if (g_bench_running.swap(true, .seq_cst)) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Ya hay un benchmark en curso.\"}");
            return;
        }
        defer g_bench_running.store(false, .seq_cst);
        const disk: u32 = std.fmt.parseInt(u32, queryParam(first_line, "disk") orelse "", 10) catch NO_DISK;
        if (disk >= MAX_DISKS) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"Falta elegir el disco que se va a medir.\"}");
            return;
        }
        var model_buf: [64]u8 = undefined;
        var model: []const u8 = "Disco";
        if (getDiskIdentity(disk)) |id| {
            const m = id.product();
            const mn = @min(m.len, model_buf.len);
            @memcpy(model_buf[0..mn], m[0..mn]);
            model = model_buf[0..mn];
        }
        if (!isAdmin()) {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"El benchmark lee el disco directamente y necesita permisos de Administrador.\"}");
            return;
        }
        if (runRealBenchmark(disk)) |r| {
            appendBenchHistory(disk, model, r);
            var j = Json{ .gpa = alloc };
            defer j.deinit();
            j.print("{{\"ok\":true,\"disk\":{d},\"model\":", .{disk});
            j.str(model);
            j.print(",\"seq_read_mbs\":{d:.1},\"seq_bytes\":{d},\"seq_secs\":{d:.2},\"rand_read_iops\":{d:.0},\"rand_read_lat_us\":{d:.1}}}", .{ r.seq_mbs, r.seq_bytes, r.seq_secs, r.iops, r.lat_us });
            sendHttpResponse(stream, "application/json; charset=utf-8", j.list.items);
        } else {
            sendHttpResponse(stream, "application/json; charset=utf-8", "{\"ok\":false,\"message\":\"No se pudo leer ese disco. Revisa que siga conectado.\"}");
        }
        return;
    }

    sendHttpResponse(stream, "text/html; charset=utf-8", UI_HTML);
}

fn clientWorker(stream: std.net.Stream) void {
    defer stream.close();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    handleClient(gpa.allocator(), stream);
}

fn runNativeServer(alloc: std.mem.Allocator, open_window: bool, auto_start_clone: bool) u8 {
    initDefaultProgress();

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8999);
    var maybe_server: ?std.net.Server = null;
    var retries: u32 = 0;
    while (retries < 25) : (retries += 1) {
        if (addr.listen(.{ .reuse_address = true })) |srv| {
            maybe_server = srv;
            break;
        } else |_| {
            Sleep(80);
        }
    }

    var server = maybe_server orelse return 1;
    // v3.0: this instance owns the port, so no benchmark of another instance is running: remove a
    // benchmark file left by a power cut (DELETE_ON_CLOSE does not run then).
    diskcheck.cleanupLeftovers();
    defer server.deinit();

    // v2.6.1: every NVMeForge session starts with a clean current log; the previous one is archived
    // in logs\runs (still visible in Registro). No clone can be running yet at this point.
    ensureLogDir();
    archivePreviousRunLog();

    // NVF-E033: exit by itself when the last window is gone (never during a clone or a benchmark).
    g_last_ui_ms.store(std.time.milliTimestamp(), .seq_cst);
    if (std.Thread.spawn(.{}, idleExitWatchdog, .{})) |t| t.detach() else |_| {}

    if (open_window) {
        _ = openDesktopWindow(alloc);
    }

    if (auto_start_clone and isAdmin()) {
        updateProgress(
            "Iniciando la clonación",
            "Modo --clone por línea de comandos: preparando el disco elegido con --target...",
            7.0,
            0.0,
            false,
        );
        if (std.Thread.spawn(.{}, cloneWorkerThread, .{})) |t| {
            t.detach();
        } else |_| {}
    }

    while (!g_shutdown_requested.load(.seq_cst)) {
        const conn = server.accept() catch continue;
        if (std.Thread.spawn(.{}, clientWorker, .{conn.stream})) |t| {
            t.detach();
        } else |_| {
            conn.stream.close();
        }
    }
    return 0;
}

/// `NVMeForge.exe --preflight`: NON-destructive diagnostics of every precondition the clone flow
/// checks (NVF-E001/E007/E008/E009). Writes %TEMP%\NVMeForge\logs\preflight.log. Never writes to any disk.
fn runPreflightDiagnostics(alloc: std.mem.Allocator) u8 {
    ensureLogDir();
    var path_buf: [512]u8 = undefined;
    const path = getLogPath(&path_buf, "preflight.log") orelse return 3;
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return 3;
    defer f.close();
    var line: [512]u8 = undefined;
    var failures: u32 = 0;

    const admin = isAdmin();
    f.writeAll(std.fmt.bufPrint(&line, "NVMeForge v{s} --preflight | admin={s}\r\n", .{ VERSION, if (admin) "si" else "no" }) catch "") catch {};

    // NVF-E038: source = disk of C:, target = --target=N or, if absent, the only other disk connected.
    const c_disk = getVolumeDiskNumber('C');
    var present: [MAX_DISKS]u32 = undefined;
    var n_present: usize = 0;
    {
        var d: u32 = 0;
        while (d < MAX_DISKS) : (d += 1) {
            const h = openPhysicalDrive(d, 0, 0) orelse continue;
            _ = CloseHandle(h);
            present[n_present] = d;
            n_present += 1;
        }
    }
    const tdisk: u32 = if (targetDisk() != NO_DISK) targetDisk() else (soleCandidate(present[0..n_present], c_disk) orelse NO_DISK);
    const ok_e038 = validTargetChoice(tdisk, c_disk);
    if (!ok_e038) failures += 1;
    f.writeAll(std.fmt.bufPrint(&line, "[NVF-E038] origen (C:)={?d} destino={s}{d} discos={d} -> {s}\r\n", .{
        c_disk, if (targetDisk() != NO_DISK) "--target=" else "auto ", if (tdisk == NO_DISK) 0 else tdisk, n_present,
        if (ok_e038) "PASS" else "FAIL (elige el destino con --target=N)",
    }) catch "") catch {};
    if (!ok_e038) {
        f.writeAll(std.fmt.bufPrint(&line, "RESULTADO: {d} fallas\r\n", .{failures}) catch "") catch {};
        return 1;
    }

    // NVF-E001: target size against the real plan for this machine
    const plan = currentClonePlan();
    var dev_buf: [64]u8 = undefined;
    const dev = std.fmt.bufPrint(&dev_buf, "\\\\.\\PhysicalDrive{d}", .{tdisk}) catch "";
    const d_bytes = getVolumeLengthBytes(dev);
    const need: u64 = if (plan) |p| p.requiredBytes() else 0;
    const ok_e001 = plan != null and d_bytes >= need;
    if (!ok_e001) failures += 1;
    f.writeAll(std.fmt.bufPrint(&line, "[NVF-E001] Disco {d} bytes={d} necesita={d} estilo={s} -> {s}\r\n", .{ tdisk, d_bytes, need, getDiskPartitionStyle(tdisk), if (ok_e001) "PASS" else "FAIL" }) catch "") catch {};

    // NVF-E023: target must be a different physical device than the source
    {
        const id_dst = getDiskIdentity(tdisk);
        const id_src = getDiskIdentity(c_disk.?);
        const distinct = id_dst != null and id_dst.?.product_len > 0 and (id_src == null or id_dst.?.serial_len == 0 or !std.mem.eql(u8, id_dst.?.serial(), id_src.?.serial()));
        if (!distinct) failures += 1;
        f.writeAll(std.fmt.bufPrint(&line, "[NVF-E023] destino=\"{s}\" serie=\"{s}\" bus={s} | origen=\"{s}\" serie=\"{s}\" -> {s}\r\n", .{
            if (id_dst) |d| d.product() else "?", if (id_dst) |d| d.serial() else "?", if (id_dst) |d| busTypeName(d.bus) else "?",
            if (id_src) |s| s.product() else "?", if (id_src) |s| s.serial() else "?", if (distinct) "PASS" else "FAIL",
        }) catch "") catch {};
    }

    // NVF-E009 / NVF-E039: reserved letters
    for (RESERVED_LETTERS) |letter| {
        var owner: ?u32 = null;
        const use = reservedLetterUse(letter, &owner);
        const ok = switch (use) {
            .free, .orphan => true, // an orphan is removed when the clone starts
            .volume => letter != 'Z' and letter != 'Y' and owner != null and owner.? == tdisk,
            .unknown => false,
        };
        // F4: a taken letter is no longer a failure, another free one is chosen.
        f.writeAll(std.fmt.bufPrint(&line, "[NVF-E009] Letra {c}: estado={s} disco={?d} -> {s}\r\n", .{ letter, @tagName(use), owner, if (!ok) "OCUPADA (se usara otra letra libre)" else if (use == .orphan) "AVISO (huerfana: se quita al clonar, NVF-E039)" else "PASS" }) catch "") catch {};
    }
    if (chooseCloneLetters(GetLogicalDrives(), RESERVED_LETTERS)) |pl| {
        f.writeAll(std.fmt.bufPrint(&line, "[F4] Letras que usaria el clon: EFI={c}: Windows={c}: WinRE={c}: EFI_origen={c}: WinRE_origen={c}: -> PASS\r\n", .{ pl[0], pl[1], pl[2], pl[3], pl[4] }) catch "") catch {};
    } else {
        failures += 1;
        f.writeAll("[F4] No hay 5 letras libres -> FAIL\r\n") catch {};
    }

    // NVF-E020 / v2.7: EFI and WinRE of the source disk, found by GPT type
    {
        const efi = findGptPartition(c_disk.?, &GUID_EFI, MIB);
        const re = findGptPartition(c_disk.?, &GUID_WINRE, 300 * MIB);
        const efi_n: ?u32 = if (efi) |p| p.number else null;
        const re_n: ?u32 = if (re) |p| p.number else null;
        f.writeAll(std.fmt.bufPrint(&line, "[EFI] Disco {d} particion EFI={?d} -> {s}\r\n", .{ c_disk.?, efi_n, if (efi != null) "PASS" else "AVISO (sin EFI en el disco de C:)" }) catch "") catch {};
        f.writeAll(std.fmt.bufPrint(&line, "[NVF-E020] Disco {d} particion WinRE={?d} -> {s}\r\n", .{ c_disk.?, re_n, if (re != null) "PASS" else "AVISO (sin WinRE origen)" }) catch "") catch {};
    }

    // NVF-E007: preview the exact diskpart scripts (not executed)
    if (plan) |p| {
        var dp_buf: [1024]u8 = undefined;
        var ex_buf: [512]u8 = undefined;
        if (buildInitScript(&dp_buf, tdisk, p)) |dp| {
            var prev_buf: [512]u8 = undefined;
            if (getLogPath(&prev_buf, "dp_init.preview.txt")) |pp| {
                if (std.fs.cwd().createFile(pp, .{ .truncate = true })) |pf| {
                    defer pf.close();
                    pf.writeAll(dp) catch {};
                    if (buildExpandScript(&ex_buf, p, &.{})) |ex| {
                        pf.writeAll("\r\n--- dp_expand ---\r\n") catch {};
                        pf.writeAll(ex) catch {};
                    }
                } else |_| {}
            }
            const has_select_volume = std.mem.indexOf(u8, dp, "select volume") != null;
            if (has_select_volume) failures += 1;
            f.writeAll(std.fmt.bufPrint(&line, "[NVF-E007] dp_init sin 'select volume'={s} | EFI {d} MiB, Windows {d} MiB, WinRE {d} MiB | preview: dp_init.preview.txt\r\n", .{ if (has_select_volume) "FAIL" else "PASS", p.efi_mb, p.windows_mb, p.recovery_mb }) catch "") catch {};
        }
    } else {
        failures += 1;
        f.writeAll("[NVF-E022] No se pudo medir C: -> FAIL\r\n") catch {};
    }

    const rc_cap = runLoggedCommand(alloc, "preflight_capture", "\"C:\\Windows\\System32\\cmd.exe\" /d /c ver");
    var tail_buf: [256]u8 = undefined;
    const tail = readLogTail("preflight_capture", 2, &tail_buf);
    const ok_cap = rc_cap == 0 and tail.len > 0;
    if (!ok_cap) failures += 1;
    f.writeAll(std.fmt.bufPrint(&line, "[LOG] captura stdout rc={d} tail=\"{s}\" -> {s}\r\n", .{ rc_cap, tail, if (ok_cap) "PASS" else "FAIL" }) catch "") catch {};

    if (admin) {
        var dd_buf: [64]u8 = undefined;
        if (std.fmt.bufPrint(&dd_buf, "select disk {d}\r\ndetail disk\r\nexit\r\n", .{tdisk})) |dd| {
            const rc_dp = runDiskpartScript(alloc, "preflight_dp_detail", dd);
            var dtail_buf: [256]u8 = undefined;
            const dtail = readLogTail("preflight_dp_detail", 2, &dtail_buf);
            f.writeAll(std.fmt.bufPrint(&line, "[NVF-E007] diskpart solo-lectura 'detail disk' rc={d} tail=\"{s}\"\r\n", .{ rc_dp, dtail }) catch "") catch {};
        } else |_| {}
    } else {
        f.writeAll("[NVF-E007] diskpart solo-lectura omitido (requiere Admin)\r\n") catch {};
    }

    f.writeAll(std.fmt.bufPrint(&line, "RESULTADO: {d} fallas\r\n", .{failures}) catch "") catch {};
    return if (failures == 0) 0 else 1;
}

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = std.process.argsAlloc(alloc) catch return 2;
    defer std.process.argsFree(alloc, args);

    var mode_clone = false;
    var mode_rebind_admin = false;
    var mode_rebind_clone = false;
    var mode_no_window = false;
    var mode_preflight = false;
    var mode_slow_ok = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--version") or std.mem.eql(u8, a, "-v")) {
            writeOut("NVMeForge " ++ VERSION ++ " (Windows x64, GPL-3.0-or-later)\n");
            return 0;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            writeOut(
                "NVMeForge v" ++ VERSION ++ " - clonador de Windows a NVMe con verificacion (GPL-3.0-or-later)\n" ++
                    "Uso: NVMeForge.exe [--gui | --clone --target=N [--slow-ok] | --preflight [--target=N] | --version | --help]\n" ++
                    "  (sin args / --gui)  Inicia el motor nativo y abre la ventana de escritorio NVMeForge\n" ++
                    "  --clone --target=N [--slow-ok]  Clona el Windows en el disco N (BORRA el disco N). --target es obligatorio; --slow-ok confirma un enlace lento (<60 MB/s) en PCs sin USB 3\n" ++
                    "  --preflight         Diagnostico NO destructivo -> %TEMP%\\NVMeForge\\logs\\preflight.log\n" ++
                    "  --version           Muestra la version del ejecutable nativo\n" ++
                    "  --help              Muestra esta ayuda\n",
            );
            return 0;
        }
        if (std.mem.eql(u8, a, "--clone")) mode_clone = true;
        if (std.mem.eql(u8, a, "--slow-ok")) mode_slow_ok = true;
        if (std.mem.startsWith(u8, a, "--target=")) {
            const t = std.fmt.parseInt(u32, a["--target=".len..], 10) catch NO_DISK;
            if (t >= MAX_DISKS) {
                writeOut("--target=N: N debe ser el numero de disco de Windows (0-15).\n");
                return 2;
            }
            g_target_disk.store(t, .seq_cst);
        }
        if (std.mem.eql(u8, a, "--preflight")) mode_preflight = true;
        if (std.mem.eql(u8, a, "--rebind-admin")) mode_rebind_admin = true;
        if (std.mem.eql(u8, a, "--rebind-admin-clone")) mode_rebind_clone = true;
        if (std.mem.eql(u8, a, "--no-window")) mode_no_window = true;
    }

    // NVF-E045: --slow-ok is the command-line form of the single-use slow-link confirmation.
    // Only for an actual clone run: in GUI/preflight mode a stale ack must never skip the UI confirm.
    if (mode_slow_ok and !(mode_clone or mode_rebind_clone)) {
        writeOut("--slow-ok solo tiene efecto con --clone (confirma un enlace lento de un solo uso).\n");
    }
    if (mode_slow_ok and (mode_clone or mode_rebind_clone)) {
        g_slowack_mutex.lock();
        g_slowack_set = true;
        g_slowack_mutex.unlock();
    }

    if (mode_preflight) return runPreflightDiagnostics(alloc);

    // NVF-E038: a command-line clone needs an explicit --target=N (there is no default target any more).
    if ((mode_clone or mode_rebind_clone) and targetDisk() == NO_DISK) {
        writeOut("--clone necesita --target=N (numero del disco destino; se BORRA por completo).\n");
        return 2;
    }

    if (mode_rebind_admin or mode_rebind_clone) {
        requestExistingBackendShutdown();
        Sleep(150);
        return runNativeServer(alloc, false, mode_rebind_clone);
    }

    if (mode_clone) {
        if (!isAdmin()) {
            var eb: [64]u8 = undefined;
            const ea = if (mode_slow_ok)
                std.fmt.bufPrint(&eb, "--rebind-admin-clone --target={d} --slow-ok", .{targetDisk()}) catch return 2
            else
                std.fmt.bufPrint(&eb, "--rebind-admin-clone --target={d}", .{targetDisk()}) catch return 2;
            _ = elevateSelf(alloc, ea);
            return 0;
        }
        requestExistingBackendShutdown();
        Sleep(150);
        return runNativeServer(alloc, true, true);
    }

    if (isBackendListening()) {
        if (!mode_no_window) {
            _ = openDesktopWindow(alloc);
        }
        return 0;
    }

    return runNativeServer(alloc, !mode_no_window, false);
}

test {
    _ = diskcheck;
}

test "v3.0.1 copyDirFiles copia los archivos de una carpeta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("logs/runs");
    try tmp.dir.writeFile(.{ .sub_path = "logs/clone_run.log", .data = "linea 1\r\nlinea 2\r\n" });
    try tmp.dir.writeFile(.{ .sub_path = "logs/runs/clone_run_x.log", .data = "vieja" });
    var pb: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&pb, ".zig-cache\\tmp\\{s}", .{tmp.sub_path});
    var sb: [600]u8 = undefined;
    var db: [600]u8 = undefined;
    const src = try std.fmt.bufPrint(&sb, "{s}\\logs", .{base});
    const dst = try std.fmt.bufPrint(&db, "{s}\\clon\\logs", .{base});
    var copied: u32 = 0;
    var failed: u32 = 0;
    copyDirFiles(src, dst, &copied, &failed);
    try std.testing.expectEqual(@as(u32, 1), copied); // only files, not the runs folder itself
    try std.testing.expectEqual(@as(u32, 0), failed);
    var buf: [64]u8 = undefined;
    const got = try tmp.dir.readFile("clon/logs/clone_run.log", &buf);
    try std.testing.expectEqualStrings("linea 1\r\nlinea 2\r\n", got);
}

test "v3.1 historial de salud y tamaño de prueba" {
    const tsv = "2026-11-01\tS7L9NJ0L319892L\tSamsung SSD 990 PRO 2TB\t0\t2565000000000\t1374000000000\t21\t40\t14\t1\t27\t0\r\n" ++
        "roto\tx\r\n" ++
        "2026-11-02\tS7L9NJ0L319892L\tSamsung SSD 990 PRO 2TB\t0\t2601000000000\t1400000000000\t30\t41\t14\t1\t27\t0\r\n";
    const out = healthHistoryJsonFromTsv(std.testing.allocator, tsv).?;
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "[{\"date\":\"2026-11-01\""));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"written_bytes\":2601000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "roto") == null);
    try std.testing.expectEqual(@as(u64, 1), suiteSizeGib(null));
    try std.testing.expectEqual(@as(u64, 16), suiteSizeGib("16"));
    try std.testing.expectEqual(@as(u64, 1), suiteSizeGib("64"));
}

test "v3.0.1 clonePathFor y duración en clones.tsv" {
    var b: [128]u8 = undefined;
    try std.testing.expectEqualStrings("W:\\Users\\x\\AppData\\Local\\Temp\\NVMeForge\\logs", clonePathFor(&b, "C:\\Users\\x\\AppData\\Local\\Temp\\NVMeForge\\logs", 'W').?);
    try std.testing.expect(clonePathFor(&b, "D:\\Temp\\NVMeForge\\logs", 'W') == null);
    const old = parseCloneLine("2026-10-30 23:19:00\tSSD 990 PRO 2TB\t2000398934016\t402000000000\tOK\t0\t0").?;
    try std.testing.expectEqual(@as(u64, 0), old.secs);
    const new = parseCloneLine("2026-10-31 11:55:00\tSSD 990 PRO 2TB\t2000398934016\t402000000000\tOK\t0\t0\t1500\t447000000000").?;
    try std.testing.expectEqual(@as(u64, 1500), new.secs);
    try std.testing.expectEqual(@as(u64, 447000000000), new.basis);
}

test "suiteHistoryJsonFromTsv: filas válidas, la más nueva primero" {
    const tsv = "2026-10-31 13:00:00\t0\tSamsung SSD 990 PRO 2TB\tC\t3\t7038.49\t2862.86\t422.88\t67.67\t6560.16\t3971.11\t524.53\t113.54\t58\t0\tcargador\r\n" ++
        "basura\r\n" ++
        "2026-10-31 14:00:00\t0\tSamsung SSD 990 PRO 2TB\tC\t1\t7100\t2900\t430\t70\t6600\t4000\t530\t115\t-\t-\tbateria\r\n";
    const out = suiteHistoryJsonFromTsv(std.testing.allocator, tsv).?;
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "[{\"when\":\"2026-10-31 14:00:00\""));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"temp_max_c\":null,\"throttle_events\":null,\"on_battery\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"read\":[7038.49,2862.86,422.88,67.67]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "basura") == null);
}

test "version string non-empty" {
    try std.testing.expect(VERSION.len > 0);
    try std.testing.expect(UI_HTML.len > 1000);
    try std.testing.expect(ICO_FILE.len > 1000);
}

test "NVF-E016 watchdog kills a silent zero-CPU child and NUL stdin never blocks" {
    ensureLogDir();
    var timer = try std.time.Timer.start();
    // waitfor.exe blocks with no CPU and no output -> must be killed by the idle watchdog (3 s).
    const rc_idle = runLoggedCommandEx(std.testing.allocator, "test_watchdog_idle", "\"C:\\Windows\\System32\\waitfor.exe\" /t 60 NVMeForgeWatchdogTest", 3, 30);
    try std.testing.expectEqual(WATCHDOG_IDLE_RC, rc_idle);
    try std.testing.expect(timer.read() < 15 * std.time.ns_per_s);

    // "set /p" reads stdin: with stdin = NUL it must return immediately instead of hanging (chkdsk (S/N) case).
    timer.reset();
    const rc_stdin = runLoggedCommandEx(std.testing.allocator, "test_stdin_nul", "\"C:\\Windows\\System32\\cmd.exe\" /d /c set /p X=Desea forzar el desmontaje (S/N)", 10, 30);
    try std.testing.expect(rc_stdin != WATCHDOG_IDLE_RC and rc_stdin != WATCHDOG_TIMEOUT_RC);
    try std.testing.expect(timer.read() < 8 * std.time.ns_per_s);
}

test "NVF-E025/E029 boot region: target must equal written; only $Boot non-BPB bytes may differ in the snapshot" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const clusters: usize = 256;
    const data = try std.testing.allocator.alloc(u8, clusters * 4096);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    const written = data; // what the copy sent to the target

    const fa = try tmp.dir.createFile("src.bin", .{ .read = true });
    defer fa.close();
    const fb = try tmp.dir.createFile("dst.bin", .{ .read = true });
    defer fb.close();
    try fa.writeAll(data);
    try fb.writeAll(data);

    var bitmap = [_]u8{0xFF} ** (256 / 8);
    const work = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 8192);
    defer std.testing.allocator.free(work);

    // Everything identical -> OK.
    try verifyBootRegion(fa.handle, fb.handle, &bitmap, clusters, work.ptr, written, clusters);

    // Snapshot changed inside $Boot cluster 1 (BitLocker virtualized sectors, 2026-10-30 09:05) -> tolerated.
    try fa.seekTo(1 * 4096 + 100);
    try fa.writeAll("VIRT");
    try verifyBootRegion(fa.handle, fb.handle, &bitmap, clusters, work.ptr, written, clusters);

    // Snapshot changed in cluster 0 boot code (outside the BPB) -> tolerated.
    try fa.seekTo(0x100);
    try fa.writeAll("CODE");
    try verifyBootRegion(fa.handle, fb.handle, &bitmap, clusters, work.ptr, written, clusters);

    // Snapshot changed in the NTFS BPB (bytes per sector @0x0B) -> fatal.
    try fa.seekTo(0x0B);
    try fa.writeAll("\x00\x10");
    try std.testing.expectError(error.VerifyMismatch, verifyBootRegion(fa.handle, fb.handle, &bitmap, clusters, work.ptr, written, clusters));
    try fa.seekTo(0);
    try fa.writeAll(data[0..4096]);

    // Snapshot changed outside $Boot (cluster 2) -> fatal.
    try fa.seekTo(2 * 4096 + 7);
    try fa.writeAll("X");
    try std.testing.expectError(error.VerifyMismatch, verifyBootRegion(fa.handle, fb.handle, &bitmap, clusters, work.ptr, written, clusters));
    try fa.seekTo(0);
    try fa.writeAll(data);

    // Target differs from what was written, even in cluster 1 -> always fatal.
    try fb.seekTo(1 * 4096 + 5);
    try fb.writeAll("CORRUPT");
    try std.testing.expectError(error.VerifyMismatch, verifyBootRegion(fa.handle, fb.handle, &bitmap, clusters, work.ptr, written, clusters));

    // Free clusters are never compared (they are not copied).
    bitmap[0] = 0xFD; // cluster 1 -> free
    try verifyBootRegion(fa.handle, fb.handle, &bitmap, clusters, work.ptr, written, clusters);

    // Boot copy not fully captured during the copy -> refuse to judge.
    bitmap[0] = 0xFF;
    try fb.seekTo(0);
    try fb.writeAll(data[0 .. 2 * 4096]);
    try std.testing.expectError(error.VerifyTooFewSamples, verifyBootRegion(fa.handle, fb.handle, &bitmap, clusters, work.ptr, written, 10));
}

test "NVF-E026 run iterator covers exactly the allocated clusters and never passes the volume end" {
    const total: u64 = 1003; // not a multiple of 8: the last bitmap byte has padding bits
    var bitmap = [_]u8{0xFF} ** ((1003 + 7) / 8);
    bitmap[3] = 0x00;
    bitmap[10] = 0x5A;
    bitmap[50] = 0x0F;
    var expected_set: u64 = 0;
    var c: u64 = 0;
    while (c < total) : (c += 1) {
        if (isClusterAllocated(&bitmap, c)) expected_set += 1;
    }

    var it = ClusterRunIter{ .bitmap = &bitmap, .total_clusters = total, .max_run = 64 };
    var covered: u64 = 0;
    var last_end: u64 = 0;
    while (it.next()) |run| {
        try std.testing.expect(run.len > 0 and run.len <= 64);
        try std.testing.expect(run.start >= last_end);
        try std.testing.expect(run.start + run.len <= total);
        var k: u64 = run.start;
        while (k < run.start + run.len) : (k += 1) try std.testing.expect(isClusterAllocated(&bitmap, k));
        covered += run.len;
        last_end = run.start + run.len;
    }
    try std.testing.expectEqual(expected_set, covered);

    // Segment sizing always fits the digest table, even for a full 2 TB source.
    const two_tb: u64 = 2000398934016;
    const seg = digestSegmentTargetBytes(two_tb);
    try std.testing.expect(two_tb / seg + 1 <= VERIFY_MAX_SEGMENTS);
    try std.testing.expect(digestSegmentTargetBytes(1) == VERIFY_MIN_SEGMENT_BYTES);
}

test "NVF-E026 full read-back verification detects any corrupted allocated cluster" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const total: u64 = 1003;
    const file_clusters: usize = 1008;
    const data = try std.testing.allocator.alloc(u8, file_clusters * 4096);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate((i *% 2654435761) >> 9);

    const fa = try tmp.dir.createFile("src.bin", .{ .read = true });
    defer fa.close();
    const fb = try tmp.dir.createFile("dst.bin", .{ .read = true });
    defer fb.close();
    try fa.writeAll(data);
    try fb.writeAll(data);

    var bitmap = [_]u8{0xFF} ** ((1003 + 7) / 8);
    bitmap[3] = 0x00; // clusters 24..31 free
    bitmap[50] = 0x0F; // clusters 404..407 free

    const max_run: u64 = 64;
    const seg_target: u64 = 128 * 1024; // 32 clusters -> many segments
    const work = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), max_run * 4096);
    defer std.testing.allocator.free(work);

    // Simulate the copy side: digest exactly what would be written, run by run.
    var digests: [256]SegmentDigest = undefined;
    var n: usize = 0;
    var bytes: u64 = 0;
    var hasher = SegmentHasher{ .seg_target_bytes = seg_target };
    var it = ClusterRunIter{ .bitmap = &bitmap, .total_clusters = total, .max_run = max_run };
    while (it.next()) |run| {
        const len: u32 = @intCast(run.len * 4096);
        try std.testing.expect(readRunAt(fa.handle, run.start, len, work.ptr));
        bytes += len;
        if (hasher.feed(run.start, work[0..len])) |s| {
            digests[n] = s;
            n += 1;
        }
    }
    if (hasher.close()) |s| {
        digests[n] = s;
        n += 1;
    }
    try std.testing.expect(n > 4);

    // Identical target -> OK.
    try verifyTargetAgainstDigests(fb.handle, &bitmap, total, max_run, work.ptr, digests[0..n], seg_target, bytes, false);

    // One corrupted byte deep inside an allocated cluster -> detected.
    try fb.seekTo(777 * 4096 + 123);
    try fb.writeAll("X");
    try std.testing.expectError(error.VerifyMismatch, verifyTargetAgainstDigests(fb.handle, &bitmap, total, max_run, work.ptr, digests[0..n], seg_target, bytes, false));
    try fb.seekTo(777 * 4096 + 123);
    try fb.writeAll(data[777 * 4096 + 123 ..][0..1]);
    try verifyTargetAgainstDigests(fb.handle, &bitmap, total, max_run, work.ptr, digests[0..n], seg_target, bytes, false);

    // Last allocated cluster of the volume -> detected.
    try fb.seekTo((total - 1) * 4096);
    try fb.writeAll("TAIL");
    try std.testing.expectError(error.VerifyMismatch, verifyTargetAgainstDigests(fb.handle, &bitmap, total, max_run, work.ptr, digests[0..n], seg_target, bytes, false));
    try fb.seekTo((total - 1) * 4096);
    try fb.writeAll(data[(total - 1) * 4096 ..][0..4]);

    // Free cluster (never copied) -> ignored.
    try fb.seekTo(26 * 4096);
    try fb.writeAll("FREE");
    try verifyTargetAgainstDigests(fb.handle, &bitmap, total, max_run, work.ptr, digests[0..n], seg_target, bytes, false);

    // Wrong number of segments / bytes -> detected.
    try std.testing.expectError(error.VerifyMismatch, verifyTargetAgainstDigests(fb.handle, &bitmap, total, max_run, work.ptr, digests[0 .. n - 1], seg_target, bytes, false));
}

test "NVF-E012 progress JSON escapes backslashes, quotes and control chars" {
    var buf: [128]u8 = undefined;
    const out = jsonEscapeInto(&buf, "UEFI \\EFI\\HP \"x\"\r\n");
    try std.testing.expectEqualStrings("UEFI \\\\EFI\\\\HP \\\"x\\\"  ", out);
}

test "NVF-E007 diskpart OEM850 output is mapped to ASCII" {
    try std.testing.expectEqual(@as(u8, 'o'), oem850ToAscii(0xA2));
    try std.testing.expectEqual(@as(u8, 'n'), oem850ToAscii(0xA4));
    try std.testing.expectEqual(@as(u8, 'A'), oem850ToAscii('A'));
}

test "NVF-E028 positioned I/O reads and writes at the exact offset and reports EOF as failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("io.bin", .{ .read = true });
    defer f.close();
    const zeros = [_]u8{0} ** (3 * 4096);
    try f.writeAll(&zeros);

    const buf = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    defer std.testing.allocator.free(buf);
    @memset(buf, 0xA5);
    try std.testing.expectEqual(@as(?u32, 4096), positionedIo(true, f.handle, 4096, buf.ptr, 4096, "test_escritura"));

    @memset(buf, 0);
    try std.testing.expect(readClusterAt(f.handle, 1, buf.ptr));
    for (buf) |b| try std.testing.expectEqual(@as(u8, 0xA5), b);
    try std.testing.expect(readClusterAt(f.handle, 0, buf.ptr));
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    // Past the end of the file: every attempt returns 0 bytes -> failure (never an endless loop).
    try std.testing.expect(!readClusterAt(f.handle, 10, buf.ptr));
}

test "NVF-E032 only NVMeForge's own page can drive the API" {
    const ok_get = "GET /api/status HTTP/1.1\r\nHost: 127.0.0.1:8999\r\n\r\n";
    try std.testing.expect(requestAllowed(ok_get, false));
    // DNS rebinding: foreign Host header.
    try std.testing.expect(!requestAllowed("GET /api/status HTTP/1.1\r\nHost: evil.example:8999\r\n\r\n", false));
    try std.testing.expect(!requestAllowed("GET / HTTP/1.1\r\n\r\n", false));
    // A web page sending a "simple" cross-site POST (no custom header) must be refused.
    try std.testing.expect(!requestAllowed("POST /api/start-clone HTTP/1.1\r\nHost: 127.0.0.1:8999\r\nOrigin: https://evil.example\r\nContent-Type: text/plain\r\n\r\n", true));
    try std.testing.expect(!requestAllowed("POST /api/start-clone HTTP/1.1\r\nHost: 127.0.0.1:8999\r\n\r\n", true));
    // Header present but foreign Origin -> refused.
    try std.testing.expect(!requestAllowed("POST /api/start-clone HTTP/1.1\r\nHost: 127.0.0.1:8999\r\nX-NVMeForge: 1\r\nOrigin: https://evil.example\r\n\r\n", true));
    // NVMeForge's own page (and its own shutdown request without Origin) -> allowed. Header names are case-insensitive.
    try std.testing.expect(requestAllowed("POST /api/start-clone HTTP/1.1\r\nhost: 127.0.0.1:8999\r\nx-nvmeforge: 1\r\norigin: http://127.0.0.1:8999\r\n\r\n", true));
    try std.testing.expect(requestAllowed("POST /api/shutdown HTTP/1.1\r\nHost: 127.0.0.1:8999\r\nX-NVMeForge: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", true));
}

test "v2.4 status JSON is valid JSON even without real disks" {
    const body = buildStatusJsonV2(std.testing.allocator, true) orelse return error.NoStatus;
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("disks") != null);
    try std.testing.expect(parsed.value.object.get("system") != null);
    try std.testing.expectEqualStrings(VERSION, parsed.value.object.get("version").?.string);
}

test "v2.4 JSON writer escapes and drops control characters" {
    var j = Json{ .gpa = std.testing.allocator };
    defer j.deinit();
    j.str("a\"b\\c\x01\nñ");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nñ\"", j.list.items);
}

test "v2.4 benchmark history: newest first, malformed and non-finite rows skipped" {
    const tsv = "2026-10-30 09:53:28\t1\tSSD 990 PRO 2TB\t888.6\t9800\t102.0\r\n" ++
        "basura sin columnas\r\n" ++
        "2026-10-30 10:00:00\t0\tSK hynix\tnan\t1\t1\r\n" ++
        "2026-10-30 10:05:00\t0\tSK hynix \"PVC10\"\t5120.4\t15000\t66.7\r\n";
    const body = benchHistoryJsonFromTsv(std.testing.allocator, tsv) orelse return error.NoJson;
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("2026-10-30 10:05:00", arr[0].object.get("when").?.string);
    try std.testing.expectEqualStrings("SK hynix \"PVC10\"", arr[0].object.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 1), arr[1].object.get("disk").?.integer);
}

test "v2.4 run summary keeps every event and only the last progress line of each burst" {
    const log =
        "[t0] ===== NVMeForge v2.4.0 clone run | admin=si =====\r\n" ++
        "[t1]  20.0% | Etapa 5/7: Clonación DMA Nativa (0.1%) | Copiados 0.1 / 300 GiB\r\n" ++
        "[t2]  50.0% | Etapa 5/7: Clonación DMA Nativa (50.0%) | Copiados 150 / 300 GiB\r\n" ++
        "[t3] FLUSH destino OK\r\n" ++
        "[t4]  81.0% | Etapa 5/7: Verificación completa de la copia (10.0%) | Releídos 30 / 300 GiB\r\n" ++
        "[t5]  89.9% | Etapa 5/7: Verificación completa de la copia (99.0%) | Releídos 297 / 300 GiB\r\n";
    const out = filterRunLog(std.testing.allocator, log) orelse return error.NoSummary;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "[t0] ===== NVMeForge v2.4.0 clone run | admin=si =====\n" ++
            "[t2]  50.0% | Etapa 5/7: Clonación DMA Nativa (50.0%) | Copiados 150 / 300 GiB\n" ++
            "[t3] FLUSH destino OK\n" ++
            "[t5]  89.9% | Etapa 5/7: Verificación completa de la copia (99.0%) | Releídos 297 / 300 GiB\n",
        out,
    );
}

test "v2.4 SMBIOS string table lookup" {
    const area = "HP\x008DF7\x00X78 Ver. 01.05.05 ";
    try std.testing.expectEqualStrings("HP", smbiosString(area, 1));
    try std.testing.expectEqualStrings("8DF7", smbiosString(area, 2));
    try std.testing.expectEqualStrings("X78 Ver. 01.05.05", smbiosString(area, 3));
    try std.testing.expectEqualStrings("", smbiosString(area, 0));
    try std.testing.expectEqualStrings("", smbiosString(area, 9));
}

test "NVF-E033 the backend exits when the window is gone, never during a clone or benchmark" {
    const t0: i64 = 1_000_000;
    // Window open and polling: stay.
    try std.testing.expect(!shouldExitForIdle(t0 + 1_000, t0 + 900, 0, false, false));
    // Window closed, no page came back for > 2 s: exit.
    try std.testing.expect(shouldExitForIdle(t0 + 3_000, t0, t0 + 500, false, false));
    // Window closed but a reload came back after the close: stay.
    try std.testing.expect(!shouldExitForIdle(t0 + 6_000, t0 + 900, t0 + 500, false, false));
    // Closed only 1.5 s ago: wait (a reload comes back in < 1 s).
    try std.testing.expect(!shouldExitForIdle(t0 + 2_000, t0, t0 + 500, false, false));
    // No page at all for more than 2 min: exit.
    try std.testing.expect(shouldExitForIdle(t0 + 121_000, t0, 0, false, false));
    // Never during a clone or a benchmark, even with the window closed long ago.
    try std.testing.expect(!shouldExitForIdle(t0 + 999_000, t0, t0 + 500, true, false));
    try std.testing.expect(!shouldExitForIdle(t0 + 999_000, t0, t0 + 500, false, true));
}

test "NVF-E035 start request carries the confirmed target and it must match exactly" {
    const line = "POST /api/start-clone?disk=1&bytes=2000398934016&model=SSD%20990%20PRO%202TB HTTP/1.1";
    try std.testing.expectEqualStrings("2000398934016", queryParam(line, "bytes").?);
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("SSD 990 PRO 2TB", percentDecode(queryParam(line, "model").?, &buf));
    try std.testing.expect(queryParam(line, "nada") == null);
    try std.testing.expect(queryParam("POST /api/start-clone HTTP/1.1", "bytes") == null);
    try std.testing.expectEqualStrings("a+b %zz c", percentDecode("a%2Bb+%zz+c", &buf));
    try std.testing.expect(targetMatchesConfirmed("SSD 990 PRO 2TB", 2000398934016, "SSD 990 PRO 2TB", 2000398934016));
    try std.testing.expect(!targetMatchesConfirmed("SSD 990 PRO 2TB", 2000398934016, "SSD 990 PRO 2TB", 1000204886016));
    try std.testing.expect(!targetMatchesConfirmed("WD_BLACK SN850X 2000GB", 2000398934016, "SSD 990 PRO 2TB", 2000398934016));
}

test "NVF-E045 slow link ETA comes only from the measured speed" {
    // 60 MiB through a 60 MiB/s link: 1 s write + 1 s re-read + 210 s tail = 212 s.
    try std.testing.expectEqual(@as(?u64, 212), slowLinkEtaSec(60 * 1024 * 1024, 60.0));
    try std.testing.expectEqual(@as(?u64, 214), slowLinkEtaSec(60 * 1024 * 1024, 30.0));
    try std.testing.expect(slowLinkEtaSec(500_000_000_000, 60.0).? > 4 * 3600); // ~500 GB at 60 MB/s: hours, not minutes
    try std.testing.expect(slowLinkEtaSec(0, 60.0) == null);
    try std.testing.expect(slowLinkEtaSec(1000, 0.0) == null);
    try std.testing.expect(slowLinkEtaSec(1000, -1.0) == null);
}

test "NVF-E045 slow-link confirmation needs a slow speed and the ack is single-use" {
    try std.testing.expect(slowLinkNeedsConfirm(59.9));
    try std.testing.expect(slowLinkNeedsConfirm(0.1));
    try std.testing.expect(!slowLinkNeedsConfirm(0.0));
    try std.testing.expect(!slowLinkNeedsConfirm(-1.0));
    try std.testing.expect(!slowLinkNeedsConfirm(60.0));
    try std.testing.expect(!slowLinkNeedsConfirm(650.0));
    g_slowack_mutex.lock();
    g_slowack_set = true;
    g_slowack_mutex.unlock();
    try std.testing.expect(takeSlowAck()); // second attempt proceeds
    try std.testing.expect(!takeSlowAck()); // consumed: a third attempt stops again
    // slow_ok values other than "1" (or absent) never arm the ack.
    try std.testing.expect(!std.mem.eql(u8, queryParam("POST /api/start-clone?disk=1&slow_ok=0 HTTP/1.1", "slow_ok") orelse "", "1"));
    try std.testing.expectEqualStrings("", queryParam("POST /api/start-clone?disk=1 HTTP/1.1", "slow_ok") orelse "");
}

test "NVF-E036 power rule never blocks on unknown data and blocks low battery" {
    try std.testing.expect(powerAllowsClone(.{ .pct = 20, .ac = true, .chg = true, .has_battery = true }));
    try std.testing.expect(powerAllowsClone(.{ .pct = 75, .ac = false, .chg = false, .has_battery = true }));
    try std.testing.expect(!powerAllowsClone(.{ .pct = 59, .ac = false, .chg = false, .has_battery = true }));
    try std.testing.expect(powerAllowsClone(.{ .pct = null, .ac = null, .chg = false, .has_battery = false }));
    try std.testing.expect(powerAllowsClone(.{ .pct = null, .ac = false, .chg = false, .has_battery = true }));
}

test "NVF-E037 run log archive name comes from the run header" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2026-10-30_095331", runStampFromHeader("[2026-10-30 09:53:31.440] ===== NVMeForge v2.5.0 clone run | admin=si =====", &buf).?);
    try std.testing.expect(runStampFromHeader("basura", &buf) == null);
    try std.testing.expect(runStampFromHeader("[2026/10/30 09:53:31.440]", &buf) == null);
}

test "v2.6 USN journal buffer: V2 and V3 records, stops at the end position" {
    var buf: [8 + 64 + 80 + 64]u8 = @splat(0);
    // V2 record (60 bytes header + 4 bytes name), file 0x11, usn 100
    std.mem.writeInt(u32, buf[8..12], 64, .little);
    std.mem.writeInt(u16, buf[12..14], 2, .little);
    std.mem.writeInt(u64, buf[16..24], 0x11, .little);
    std.mem.writeInt(i64, buf[32..40], 100, .little);
    // V3 record (80 bytes), file id 128-bit, usn 200
    const o3 = 8 + 64;
    std.mem.writeInt(u32, buf[o3..][0..4], 80, .little);
    std.mem.writeInt(u16, buf[o3 + 4 ..][0..2], 3, .little);
    std.mem.writeInt(u64, buf[o3 + 8 ..][0..8], 0x22, .little);
    std.mem.writeInt(i64, buf[o3 + 40 ..][0..8], 200, .little);
    // V2 record of the same file 0x11, usn 300 (beyond end 250 in the second pass)
    const o4 = o3 + 80;
    std.mem.writeInt(u32, buf[o4..][0..4], 64, .little);
    std.mem.writeInt(u16, buf[o4 + 4 ..][0..2], 2, .little);
    std.mem.writeInt(u64, buf[o4 + 8 ..][0..8], 0x11, .little);
    std.mem.writeInt(i64, buf[o4 + 24 ..][0..8], 300, .little);

    var c = UsnCounter{ .set = std.AutoHashMap(u64, void).init(std.testing.allocator) };
    defer c.set.deinit();
    try std.testing.expect(parseUsnBuffer(&buf, 1000, &c, UsnCounter.add));
    try std.testing.expectEqual(@as(u64, 3), c.records);
    try std.testing.expectEqual(@as(u32, 2), c.set.count()); // same file twice counts once

    var c2 = UsnCounter{ .set = std.AutoHashMap(u64, void).init(std.testing.allocator) };
    defer c2.set.deinit();
    try std.testing.expect(!parseUsnBuffer(&buf, 250, &c2, UsnCounter.add));
    try std.testing.expectEqual(@as(u64, 2), c2.records);
}

test "v2.6 run names: only archived run files, never paths" {
    try std.testing.expect(validRunName("clone_run_2026-10-30_095331.log"));
    try std.testing.expect(validRunName("clone_run_2026-10-30_095331_2.log"));
    try std.testing.expect(!validRunName("..\\clones.tsv"));
    try std.testing.expect(!validRunName("clone_run_../../x.log"));
    try std.testing.expect(!validRunName("clone_run_2026\\a.log"));
    try std.testing.expect(!validRunName("otra_cosa.log"));
    try std.testing.expect(!validRunName("clone_run_x.txt"));
}

test "v2.6 clone history: newest first, journal flag, malformed lines skipped" {
    const tsv = "2026-10-29 22:33:41\tSSD 990 PRO 2TB\t2000398934016\t370799148800\tOK\t123\t456\r\n" ++
        "rota\r\n" ++
        "2026-10-30 13:10:00\tSSD 990 PRO 2TB\t2000398934016\t371000000000\tADVERTENCIAS: winre_copy\t0\t0\r\n";
    const body = cloneHistoryJson(std.testing.allocator, tsv) orelse return error.NoJson;
    defer std.testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const a = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), a.len);
    try std.testing.expectEqualStrings("2026-10-30 13:10:00", a[0].object.get("when").?.string);
    try std.testing.expect(!a[0].object.get("tracks_changes").?.bool);
    try std.testing.expect(a[1].object.get("tracks_changes").?.bool);
    const r = parseCloneLine("2026-10-29 22:33:41\tSSD 990 PRO 2TB\t2000398934016\t370799148800\tOK\t123\t456").?;
    try std.testing.expectEqual(@as(u64, 123), r.usn.?.journal_id);
    try std.testing.expectEqual(@as(i64, 456), r.usn.?.next_usn);
}


test "NVF-E038 target choice: never the source disk, never unknown" {
    try std.testing.expect(validTargetChoice(1, 0));
    try std.testing.expect(validTargetChoice(0, 2)); // Windows on disk 2 (desktop), target disk 0
    try std.testing.expect(!validTargetChoice(0, 0));
    try std.testing.expect(!validTargetChoice(1, null)); // unknown source: nothing may be wiped
    try std.testing.expect(!validTargetChoice(NO_DISK, 0));
    try std.testing.expect(!validTargetChoice(MAX_DISKS, 0));
}

test "NVF-E038 pre-selection only with exactly one disk besides the source" {
    try std.testing.expectEqual(@as(?u32, 1), soleCandidate(&.{ 0, 1 }, 0));
    try std.testing.expectEqual(@as(?u32, 0), soleCandidate(&.{ 0, 3 }, 3));
    try std.testing.expectEqual(@as(?u32, null), soleCandidate(&.{0}, 0)); // nothing connected
    try std.testing.expectEqual(@as(?u32, null), soleCandidate(&.{ 0, 1, 2 }, 0)); // two adapters: user picks
    try std.testing.expectEqual(@as(?u32, null), soleCandidate(&.{ 0, 1 }, null));
}

test "NVF-E001 v2.7 required target size comes from the source, not a fixed 1.5 TB" {
    // This laptop: C: 443.77 GiB, EFI 260 MiB, WinRE ~990 MiB.
    const c: u64 = 476_490_000_000;
    const p = planClone(c, 260 * MIB, 990 * MIB);
    try std.testing.expectEqual(@as(u64, 260), p.efi_mb);
    try std.testing.expectEqual(@as(u64, 1000), p.recovery_mb);
    try std.testing.expectEqual(c / MIB + 32, p.windows_mb);
    const need = p.requiredBytes();
    try std.testing.expect(need > c and need < c + 2 * 1024 * MIB); // C: + ~1.4 GiB
    try std.testing.expect(need < 500_000_000_000); // a 500 GB disk is enough, 1.5 TB is no longer required
    // A bigger OEM EFI / WinRE is kept at its size; absurd values are capped.
    const q = planClone(c, 650 * MIB, 2100 * MIB);
    try std.testing.expectEqual(@as(u64, 650), q.efi_mb);
    try std.testing.expectEqual(@as(u64, 2100), q.recovery_mb);
    const r = planClone(c, 0, 900 * 1024 * MIB);
    try std.testing.expectEqual(MIN_EFI_MB, r.efi_mb);
    try std.testing.expectEqual(MAX_SYS_PART_MB, r.recovery_mb);
}

test "NVF-E007 v2.7 diskpart scripts use the chosen disk and the planned sizes" {
    const p = ClonePlan{ .efi_mb = 300, .windows_mb = 454_437, .recovery_mb = 1200 };
    var b1: [1024]u8 = undefined;
    const init = buildInitScript(&b1, 3, p).?;
    try std.testing.expect(std.mem.startsWith(u8, init, "select disk 3\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, init, "create partition efi size=300\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, init, "create partition primary size=454437\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, init, "select volume") == null);
    try std.testing.expect(std.mem.indexOf(u8, init, "create partition msr") == null); // NVF-E015
    var b2: [512]u8 = undefined;
    const ex = buildExpandScript(&b2, p, &.{}).?;
    try std.testing.expect(std.mem.indexOf(u8, ex, "shrink desired=1200 minimum=1150 noerr\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ex, "id=de94bba4-06d1-4d40-a16a-bfd50179d6ac") != null);
}

test "v2.7 GPT partitions are found by type, not by number" {
    var layout = [_]u8{0} ** (48 + 4 * 144);
    std.mem.writeInt(u32, layout[0..4], 1, .little); // GPT
    std.mem.writeInt(u32, layout[4..8], 4, .little);
    const Entry = struct { num: u32, len: u64, guid: [16]u8 };
    const entries = [_]Entry{
        .{ .num = 1, .len = 16 * MIB, .guid = GUID_MSR },
        .{ .num = 2, .len = 100 * MIB, .guid = GUID_EFI }, // EFI is NOT partition 1 here
        .{ .num = 3, .len = 400 * 1024 * MIB, .guid = GUID_DATA },
        .{ .num = 4, .len = 990 * MIB, .guid = GUID_WINRE },
    };
    for (entries, 0..) |e, k| {
        const off = 48 + k * 144;
        std.mem.writeInt(u64, layout[off + 16 ..][0..8], e.len, .little);
        std.mem.writeInt(u32, layout[off + 24 ..][0..4], e.num, .little);
        @memcpy(layout[off + 32 .. off + 48], &e.guid);
    }
    const efi = findGptPartitionInLayout(&layout, &GUID_EFI, MIB).?;
    try std.testing.expectEqual(@as(u32, 2), efi.number);
    try std.testing.expectEqual(100 * MIB, efi.bytes);
    try std.testing.expectEqual(@as(u32, 4), findGptPartitionInLayout(&layout, &GUID_WINRE, 300 * MIB).?.number);
    try std.testing.expectEqual(@as(?GptPart, null), findGptPartitionInLayout(&layout, &GUID_WINRE, 2000 * MIB));
    // MBR disk or truncated buffer: nothing is assumed.
    std.mem.writeInt(u32, layout[0..4], 0, .little);
    try std.testing.expectEqual(@as(?GptPart, null), findGptPartitionInLayout(&layout, &GUID_EFI, MIB));
    try std.testing.expectEqual(@as(?GptPart, null), findGptPartitionInLayout(layout[0..20], &GUID_EFI, MIB));
}

test "NVF-E039 only a letter whose device no longer exists counts as an orphan" {
    // 2026-10-30 21:54: \\.\S: -> error 2 and its \Device\HarddiskVolumeNN is gone -> orphan.
    try std.testing.expect(isOrphanLetterEvidence(2, "\\Device\\HarddiskVolume27", 2));
    try std.testing.expect(isOrphanLetterEvidence(3, "\\Device\\HarddiskVolume27", 3));
    // The device exists (opens) or only refuses access (EFI partition, card reader): never an orphan.
    try std.testing.expect(!isOrphanLetterEvidence(2, "\\Device\\HarddiskVolume27", 0));
    try std.testing.expect(!isOrphanLetterEvidence(2, "\\Device\\HarddiskVolume27", 5));
    try std.testing.expect(!isOrphanLetterEvidence(5, "\\Device\\HarddiskVolume5", 2));
    try std.testing.expect(!isOrphanLetterEvidence(21, "\\Device\\Harddisk2\\DR2", 2)); // not ready
    // subst drives are never touched (network drives are excluded before, by GetDriveTypeW).
    try std.testing.expect(!isOrphanLetterEvidence(2, "\\??\\C:\\proyectos", 2));
}

fn testLayout(buf: []u8, parts: []const GptEntry) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    std.mem.writeInt(u32, buf[4..8], @intCast(parts.len), .little);
    for (parts, 0..) |e, k| {
        const off = 48 + k * 144;
        std.mem.writeInt(u64, buf[off + 8 ..][0..8], e.offset, .little);
        std.mem.writeInt(u64, buf[off + 16 ..][0..8], e.bytes, .little);
        std.mem.writeInt(u32, buf[off + 24 ..][0..4], e.number, .little);
        @memcpy(buf[off + 32 .. off + 48], &e.type_guid);
        std.mem.writeInt(u64, buf[off + 64 ..][0..8], e.attributes, .little);
    }
}

test "v2.8 full clone: the HP partitions of this laptop are selected and copied, EFI/MSR/C:/WinRE are not" {
    // Disk 0 of this laptop: EFI 1, MSR 2, C: 3, WinRE 4, data 1.07 GB 5, data 33.3 GB 6.
    const src = [_]GptEntry{
        .{ .number = 1, .offset = 1 * MIB, .bytes = 260 * MIB, .type_guid = GUID_EFI },
        .{ .number = 2, .offset = 261 * MIB, .bytes = 16 * MIB, .type_guid = GUID_MSR },
        .{ .number = 3, .offset = 277 * MIB, .bytes = 454_356 * MIB, .type_guid = GUID_DATA },
        .{ .number = 4, .offset = 454_633 * MIB, .bytes = 985 * MIB, .type_guid = GUID_WINRE, .attributes = 0x8000000000000001 },
        .{ .number = 6, .offset = 456_643 * MIB, .bytes = 31_744 * MIB, .type_guid = GUID_DATA, .attributes = 0xC000000000000000 },
        .{ .number = 5, .offset = 455_618 * MIB, .bytes = 1_025 * MIB, .type_guid = GUID_DATA, .attributes = 0x8000000000000001 },
    };
    var lay: [48 + 6 * 144]u8 = undefined;
    testLayout(&lay, &src);
    var entries: [8]GptEntry = undefined;
    const n = parseGptEntries(&lay, &entries);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqual(@as(u32, 5), entries[4].number); // sorted by offset
    var ex: [8]ExtraPart = undefined;
    const ne = selectExtraPartitions(entries[0..n], 277 * MIB, 4, &.{}, &ex);
    try std.testing.expectEqual(@as(usize, 2), ne);
    try std.testing.expectEqual(@as(u32, 5), ex[0].entry.number);
    try std.testing.expectEqual(@as(u32, 6), ex[1].entry.number);
    try std.testing.expect(ex[0].copy == .raw and ex[1].copy == .raw);
    try std.testing.expectEqual(@as(u64, 1_025 + 31_744 + 2 * EXTRA_MARGIN_MB), extrasMb(ex[0..ne]));
    // A partition with a drive letter (in use) is reported, never copied raw.
    const d_letter = [_]VolExtent{.{ .letter = 'D', .disk = 0, .offset = 456_643 * MIB, .length = 31_744 * MIB }};
    var ex2: [8]ExtraPart = undefined;
    const ne2 = selectExtraPartitions(entries[0..n], 277 * MIB, 4, &d_letter, &ex2);
    try std.testing.expect(ex2[ne2 - 1].copy == .skip_mounted and ex2[ne2 - 1].letter == 'D');
    try std.testing.expectEqual(@as(u64, 1_025 + EXTRA_MARGIN_MB), extrasMb(ex2[0..ne2]));
    // The required size grows with the extras.
    var plan = planClone(454_356 * MIB, 260 * MIB, 985 * MIB);
    const before = plan.requiredBytes();
    plan.extras_mb = extrasMb(ex[0..ne]);
    try std.testing.expectEqual(before + plan.extras_mb * MIB, plan.requiredBytes());
    // diskpart script: recovery with an explicit size, then each extra with its type and attributes, no letter.
    var b: [4096]u8 = undefined;
    const sc = buildExpandScript(&b, plan, ex[0..ne]).?;
    try std.testing.expect(std.mem.indexOf(u8, sc, "create partition primary size=1000 id=de94bba4-06d1-4d40-a16a-bfd50179d6ac") != null);
    try std.testing.expect(std.mem.indexOf(u8, sc, "create partition primary size=1025 id=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7\r\ncreate partition primary size=31744 id=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7\r\nexit\r\n") != null);
    // Review #3/#6: no "remove all" (volume focus) and no attributes before the copy.
    try std.testing.expect(std.mem.indexOf(u8, sc, "remove all") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sc, "gpt attributes")); // only R:
    try std.testing.expect(std.mem.indexOf(u8, sc, "select volume W\r\nextend\r\nshrink desired=") != null);
    try std.testing.expect(std.mem.endsWith(u8, sc, "exit\r\n"));
}

test "v2.8 GUID text and mapping of the created partitions on the target" {
    var g: [36]u8 = undefined;
    try std.testing.expectEqualStrings("c12a7328-f81f-11d2-ba4b-00a0c93ec93b", fmtGuid(&GUID_EFI, &g));
    try std.testing.expectEqualStrings("de94bba4-06d1-4d40-a16a-bfd50179d6ac", fmtGuid(&GUID_WINRE, &g));
    const extras = [_]ExtraPart{
        .{ .entry = .{ .number = 5, .bytes = 1_025 * MIB, .type_guid = GUID_DATA }, .copy = .raw },
        .{ .entry = .{ .number = 7, .bytes = 50 * MIB, .type_guid = GUID_DATA }, .copy = .skip_mounted },
        .{ .entry = .{ .number = 6, .bytes = 31_744 * MIB, .type_guid = GUID_DATA }, .copy = .raw },
    };
    const W: u64 = 277 * MIB;
    const tgt = [_]GptEntry{
        .{ .number = 1, .offset = 1 * MIB, .bytes = 16 * MIB, .type_guid = GUID_MSR },
        .{ .number = 2, .offset = 17 * MIB, .bytes = 260 * MIB, .type_guid = GUID_EFI },
        .{ .number = 3, .offset = W, .bytes = 1_800_000 * MIB, .type_guid = GUID_DATA },
        .{ .number = 4, .offset = W + 1_800_000 * MIB, .bytes = 1000 * MIB, .type_guid = GUID_WINRE },
        .{ .number = 5, .offset = W + 1_801_000 * MIB, .bytes = 1_025 * MIB, .type_guid = GUID_DATA },
        .{ .number = 6, .offset = W + 1_802_026 * MIB, .bytes = 31_744 * MIB, .type_guid = GUID_DATA },
    };
    const R = tgt[3].offset;
    var nums: [2]u32 = undefined;
    try std.testing.expect(mapExtrasToTarget(&tgt, R, &extras, &nums));
    try std.testing.expectEqual(@as(u32, 5), nums[0]);
    try std.testing.expectEqual(@as(u32, 6), nums[1]);
    // Missing, too small, or a different count after R: -> do not write anything.
    try std.testing.expect(!mapExtrasToTarget(tgt[0..5], R, &extras, &nums));
    var small = tgt;
    small[5].bytes = 31_000 * MIB;
    try std.testing.expect(!mapExtrasToTarget(&small, R, &extras, &nums));
    // Review #1: R: (WinRE type) can never be taken for a WinRE-typed extra: only partitions AFTER R: count.
    const re_extra = [_]ExtraPart{.{ .entry = .{ .number = 9, .bytes = 990 * MIB, .type_guid = GUID_WINRE }, .copy = .raw }};
    var one: [1]u32 = undefined;
    try std.testing.expect(!mapExtrasToTarget(tgt[0..4], R, &re_extra, &one));
    try std.testing.expect(!mapExtrasToTarget(tgt[0..4], W, &re_extra, &one));
    // Unsupported types (Storage Spaces) are never copied raw.
    const spaces = [_]u8{ 0x8F, 0xAF, 0x5C, 0xE7, 0x80, 0xF6, 0xEE, 0x4C, 0xA3, 0xB0, 0x01, 0xE5, 0x6E, 0xFC, 0x2D, 0x2D };
    const src2 = [_]GptEntry{ .{ .number = 3, .offset = W, .bytes = 100 * MIB, .type_guid = GUID_DATA }, .{ .number = 4, .offset = W + 100 * MIB, .bytes = 100 * MIB, .type_guid = spaces } };
    var ex: [2]ExtraPart = undefined;
    const ne = selectExtraPartitions(&src2, W, null, &.{}, &ex);
    try std.testing.expectEqual(@as(usize, 1), ne);
    try std.testing.expect(ex[0].copy == .skip_unsupported);
}

test "v2.9 F4: letters are chosen free, preferred S W R Z Y kept when possible" {
    const bit = struct {
        fn b(c: u8) u32 {
            return @as(u32, 1) << @intCast(c - 'A');
        }
    }.b;
    // Only C: and D: in use -> the usual letters.
    try std.testing.expectEqualSlices(u8, "SWRZY", &chooseCloneLetters(bit('C') | bit('D'), RESERVED_LETTERS).?);
    // S: taken (e.g. a USB stick) -> another free letter for the EFI, the rest unchanged.
    const r = chooseCloneLetters(bit('C') | bit('S'), RESERVED_LETTERS).?;
    try std.testing.expect(r[0] != 'S' and r[0] != 'C' and r[0] != 'W' and r[0] != 'R' and r[0] != 'Z' and r[0] != 'Y');
    try std.testing.expectEqualSlices(u8, "WRZY", r[1..]);
    // Every chosen letter is distinct and free.
    const busy = bit('C') | bit('S') | bit('W') | bit('T') | bit('U');
    const r2 = chooseCloneLetters(busy, RESERVED_LETTERS).?;
    for (r2, 0..) |x, i| {
        try std.testing.expect(busy & bit(x) == 0);
        for (r2[i + 1 ..]) |y| try std.testing.expect(x != y);
    }
    // Not enough free letters -> null (the clone stops before touching anything).
    try std.testing.expectEqual(@as(?[5]u8, null), chooseCloneLetters(0x03FF_FFFF & ~(bit('Z') | bit('Y')), RESERVED_LETTERS));
}

test "v2.9 F4: templates get the chosen letters" {
    var b: [128]u8 = undefined;
    const L5 = [5]u8{ 'T', 'W', 'Q', 'Z', 'P' };
    try std.testing.expectEqualStrings("\"bcdboot.exe\" W:\\Windows /s T: /f UEFI", substLetters(&b, "\"bcdboot.exe\" @W:\\Windows /s @S: /f UEFI", L5).?);
    try std.testing.expectEqualStrings("P:\\Recovery Q:\\Recovery Z:\\EFI", substLetters(&b, "@Y:\\Recovery @R:\\Recovery @Z:\\EFI", L5).?);
    try std.testing.expectEqualStrings("a@b @x", substLetters(&b, "a@b @x", L5).?); // unknown tokens untouched
    var small: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), substLetters(&small, "@W:\\Windows", L5));
}

test "v2.9 F3: the clone's BCD must boot its own Windows" {
    const good =
        "Windows Boot Loader\r\n-------------------\r\nidentifier              {default}\r\ndevice                  partition=W:\r\npath                    \\Windows\\system32\\winload.efi\r\nosdevice                partition=W:\r\n";
    try std.testing.expect(bcdPointsTo(good, 'W'));
    try std.testing.expect(!bcdPointsTo(good, 'T'));
    const wrong = "device                  partition=C:\r\npath \\Windows\\system32\\winload.efi\r\nosdevice                partition=C:\r\n";
    try std.testing.expect(!bcdPointsTo(wrong, 'W'));
    try std.testing.expect(!bcdPointsTo("", 'W'));
}

test "v2.9 F1: pagefile/hiberfil clusters leave the copy, except the first 1 MiB and the volume edges" {
    const total: u64 = 20_000;
    var bm = [_]u8{0xFF} ** ((20_000 + 7) / 8);
    const edge: u64 = 4096;
    // File of 1000 clusters at LCN 8000: first 256 kept, 744 cleared.
    try std.testing.expectEqual(@as(u64, 744), clearFileExtentBits(&bm, total, edge, 0, 8000, 1000));
    try std.testing.expect(isClusterAllocated(&bm, 8000) and isClusterAllocated(&bm, 8255));
    try std.testing.expect(!isClusterAllocated(&bm, 8256) and !isClusterAllocated(&bm, 8999));
    // Second extent (VCN 1000..) entirely cleared; extents inside the edges never.
    try std.testing.expectEqual(@as(u64, 100), clearFileExtentBits(&bm, total, edge, 1000, 10_000, 100));
    try std.testing.expectEqual(@as(u64, 0), clearFileExtentBits(&bm, total, edge, 2000, 100, 50));
    try std.testing.expectEqual(@as(u64, 0), clearFileExtentBits(&bm, total, edge, 2000, total - 100, 50));
}

test "v2.9 F2: overall time left" {
    try std.testing.expectEqual(@as(?u64, null), estimateEtaSec(0, 0, 0, 10_000, false));
    try std.testing.expectEqual(@as(?u64, null), estimateEtaSec(1000, 10, 0, 1000, false)); // < 3 s: no rate yet
    // 100 GB to copy (200 GB of work), 50 GB done in 100 s -> 150 GB left at 0.5 GB/s = 300 s + 150 s tail.
    try std.testing.expectEqual(@as(?u64, 510), estimateEtaSec(100_000_000_000, 50_000_000_000, 0, 100_000, false));
    try std.testing.expectEqual(@as(?u64, 90), estimateEtaSec(1000, 1000, 1000, 100_000, true));
}

test "v2.9 F1: read-ahead delivers every run once, in order, with the right bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const clusters: usize = 300;
    const data = try std.testing.allocator.alloc(u8, clusters * 4096);
    defer std.testing.allocator.free(data);
    for (data, 0..) |*x, i| x.* = @truncate((i *% 2654435761) >> 7);
    const f = try tmp.dir.createFile("v.bin", .{ .read = true });
    defer f.close();
    try f.writeAll(data);
    var bitmap = [_]u8{0xFF} ** ((300 + 7) / 8);
    bitmap[5] = 0x0F;
    bitmap[20] = 0x00;
    const max_run: u64 = 16;
    var bufs: [PREFETCH_SLOTS][*]u8 = undefined;
    const base = allocPrefetchBuffers(@intCast(max_run * 4096), &bufs).?;
    defer _ = VirtualFree(base, 0, MEM_RELEASE);
    var pf = RunPrefetcher{ .h = f.handle, .runs = ClusterRunIter{ .bitmap = &bitmap, .total_clusters = 300, .max_run = max_run }, .bufs = bufs, .label = "t" };
    const th = try std.Thread.spawn(.{}, RunPrefetcher.producer, .{&pf});
    var ref = ClusterRunIter{ .bitmap = &bitmap, .total_clusters = 300, .max_run = max_run };
    var n: usize = 0;
    while (try pf.next()) |it| {
        const r = ref.next().?;
        try std.testing.expectEqual(r.start, it.start);
        try std.testing.expectEqual(r.len, it.len);
        try std.testing.expectEqualSlices(u8, data[@intCast(it.start * 4096)..][0..@intCast(it.len * 4096)], it.buf[0..@intCast(it.len * 4096)]);
        pf.release();
        n += 1;
    }
    try std.testing.expectEqual(@as(?ClusterRunIter.Run, null), ref.next());
    pf.abort();
    th.join();
    try std.testing.expect(n > 10);
}
