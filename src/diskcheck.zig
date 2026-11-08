//! NVMeForge — diskcheck.zig
//! v3.0 (F10 + F11): salud ampliada del NVMe, enlace PCIe, propiedades de caché y TRIM, ajustes de energía
//! y el banco de pruebas de 4 pruebas (lectura y escritura sobre un archivo temporal).
//!
//! Todo sale de interfaces públicas: la especificación NVM Express (log de salud 0x02 e Identify Controller)
//! y las API documentadas de Windows (IOCTL_STORAGE_QUERY_PROPERTY, SetupAPI/CfgMgr, PowrProf, Registro).
//! Nada se escribe en el disco en bruto: el banco de pruebas escribe solo dentro de su propio archivo temporal,
//! abierto con FILE_FLAG_DELETE_ON_CLOSE para que Windows lo borre aunque el programa se cierre a la fuerza.
//!
//! Copyright (C) 2026 Carlos Javier y los autores de NVMeForge. GPL-3.0-or-later.

const std = @import("std");

const HANDLE = *anyopaque;
const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
const IOCTL_STORAGE_QUERY_PROPERTY: u32 = 0x002D1400;
const IOCTL_STORAGE_GET_DEVICE_NUMBER: u32 = 0x002D1080;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const DELETE_ACCESS: u32 = 0x00010000;
const FILE_SHARE_READ: u32 = 0x1;
const FILE_SHARE_WRITE: u32 = 0x2;
const OPEN_EXISTING: u32 = 3;
const CREATE_NEW: u32 = 1;
const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
const FILE_ATTRIBUTE_TEMPORARY: u32 = 0x100;
const FILE_FLAG_NO_BUFFERING: u32 = 0x20000000;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const FILE_FLAG_DELETE_ON_CLOSE: u32 = 0x04000000;
const ERROR_FILE_EXISTS: u32 = 80;
const ERROR_IO_PENDING: u32 = 997;
const MEM_COMMIT: u32 = 0x1000;
const MEM_RESERVE: u32 = 0x2000;
const MEM_RELEASE: u32 = 0x8000;
const PAGE_READWRITE: u32 = 0x04;

const GUID = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };
const DEVPROPKEY = extern struct { fmtid: GUID, pid: u32 };
const OVERLAPPED = extern struct {
    internal: usize = 0,
    internal_high: usize = 0,
    offset: u32 = 0,
    offset_high: u32 = 0,
    h_event: ?*anyopaque = null,
};
const SP_DEVICE_INTERFACE_DATA = extern struct { cb_size: u32, guid: GUID, flags: u32, reserved: usize };
const SP_DEVINFO_DATA = extern struct { cb_size: u32, class_guid: GUID, dev_inst: u32, reserved: usize };

extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: ?*anyopaque) callconv(.winapi) HANDLE;
extern "kernel32" fn CloseHandle(h: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn DeviceIoControl(h: HANDLE, code: u32, in: ?*const anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32, ret: *u32, ov: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(h: HANDLE, buf: *anyopaque, len: u32, done: ?*u32, ov: ?*OVERLAPPED) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(h: HANDLE, buf: *const anyopaque, len: u32, done: ?*u32, ov: ?*OVERLAPPED) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn CreateIoCompletionPort(file: HANDLE, existing: ?*anyopaque, key: usize, threads: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetQueuedCompletionStatus(port: *anyopaque, bytes: *u32, key: *usize, ov: *?*OVERLAPPED, ms: u32) callconv(.winapi) i32;
extern "kernel32" fn CancelIoEx(h: HANDLE, ov: ?*OVERLAPPED) callconv(.winapi) i32;
extern "kernel32" fn SetFilePointerEx(h: HANDLE, dist: i64, newp: ?*i64, method: u32) callconv(.winapi) i32;
extern "kernel32" fn SetEndOfFile(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn FlushFileBuffers(h: HANDLE) callconv(.winapi) i32;
extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn GetDiskFreeSpaceExW(root: [*:0]const u16, avail: ?*u64, total: ?*u64, free: ?*u64) callconv(.winapi) i32;
extern "kernel32" fn VirtualAlloc(addr: ?*anyopaque, size: usize, typ: u32, prot: u32) callconv(.winapi) ?[*]u8;
extern "kernel32" fn VirtualFree(addr: *anyopaque, size: usize, typ: u32) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceCounter(v: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(v: *i64) callconv(.winapi) i32;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn LocalFree(p: ?*anyopaque) callconv(.winapi) ?*anyopaque;

extern "setupapi" fn SetupDiGetClassDevsW(class: ?*const GUID, enumerator: ?[*:0]const u16, hwnd: ?*anyopaque, flags: u32) callconv(.winapi) HANDLE;
extern "setupapi" fn SetupDiEnumDeviceInterfaces(set: HANDLE, info: ?*SP_DEVINFO_DATA, class: *const GUID, index: u32, data: *SP_DEVICE_INTERFACE_DATA) callconv(.winapi) i32;
extern "setupapi" fn SetupDiGetDeviceInterfaceDetailW(set: HANDLE, data: *SP_DEVICE_INTERFACE_DATA, detail: ?*anyopaque, size: u32, required: ?*u32, info: ?*SP_DEVINFO_DATA) callconv(.winapi) i32;
extern "setupapi" fn SetupDiDestroyDeviceInfoList(set: HANDLE) callconv(.winapi) i32;
extern "cfgmgr32" fn CM_Get_Parent(parent: *u32, inst: u32, flags: u32) callconv(.winapi) u32;
extern "cfgmgr32" fn CM_Get_Device_IDW(inst: u32, buf: [*]u16, len: u32, flags: u32) callconv(.winapi) u32;
extern "cfgmgr32" fn CM_Get_DevNode_PropertyW(inst: u32, key: *const DEVPROPKEY, typ: *u32, buf: ?*anyopaque, size: *u32, flags: u32) callconv(.winapi) u32;
extern "powrprof" fn PowerGetActiveScheme(root: ?*anyopaque, scheme: *?*GUID) callconv(.winapi) u32;
extern "powrprof" fn PowerReadACValueIndex(root: ?*anyopaque, scheme: ?*const GUID, sub: ?*const GUID, setting: ?*const GUID, value: *u32) callconv(.winapi) u32;
extern "powrprof" fn PowerReadDCValueIndex(root: ?*anyopaque, scheme: ?*const GUID, sub: ?*const GUID, setting: ?*const GUID, value: *u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
const OverlayFn = *const fn (overlay: *GUID) callconv(.winapi) u32;
extern "advapi32" fn RegGetValueW(key: ?*anyopaque, sub: ?[*:0]const u16, value: ?[*:0]const u16, flags: u32, typ: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

// =====================================================================================================
// Consultas NVMe por IOCTL_STORAGE_QUERY_PROPERTY (protocolo NVMe)
// =====================================================================================================

/// Generic NVMe protocol-specific query (log page or identify). `property` 49 = adapter, 50 = device.
/// Returns false when the driver (or a USB bridge) does not answer.
fn nvmeQuery(h: HANDLE, property: u32, data_type: u32, request_value: u32, out: []u8) bool {
    var buf: [48 + 4096]u8 align(8) = @splat(0);
    if (out.len > 4096) return false;
    std.mem.writeInt(u32, buf[0..4], property, .little); // PropertyId
    std.mem.writeInt(u32, buf[4..8], 0, .little); // PropertyStandardQuery
    std.mem.writeInt(u32, buf[8..12], 3, .little); // ProtocolTypeNvme
    std.mem.writeInt(u32, buf[12..16], data_type, .little); // 1 = Identify, 2 = LogPage
    std.mem.writeInt(u32, buf[16..20], request_value, .little);
    std.mem.writeInt(u32, buf[20..24], 0, .little);
    std.mem.writeInt(u32, buf[24..28], 40, .little); // ProtocolDataOffset
    std.mem.writeInt(u32, buf[28..32], @intCast(out.len), .little); // ProtocolDataLength
    const total: u32 = @intCast(48 + out.len);
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &buf, total, &buf, total, &ret, null) == 0) return false;
    if (std.mem.readInt(u32, buf[0..4], .little) != 48 or std.mem.readInt(u32, buf[4..8], .little) != 48) return false;
    const off = std.mem.readInt(u32, buf[8 + 16 ..][0..4], .little);
    const len = std.mem.readInt(u32, buf[8 + 20 ..][0..4], .little);
    if (off < 40 or len < out.len or 8 + @as(usize, off) + out.len > buf.len) return false;
    @memcpy(out, buf[8 + off ..][0..out.len]);
    return true;
}

/// NVMe SMART / Health Information log (page 0x02, 512 bytes).
pub fn queryHealthLog(h: HANDLE, out: *[512]u8) bool {
    return nvmeQuery(h, 50, 2, 2, out);
}

/// Thermal and activity counters of the health log that v2.x did not read (NVMe base spec, Figure "SMART /
/// Health Information Log Page"): times above the warning/critical composite temperature, the individual
/// temperature sensors and the thermal management (throttle) transitions.
pub const Thermal = struct {
    warn_temp_minutes: u32 = 0,
    crit_temp_minutes: u32 = 0,
    sensors_c: [8]?i16 = @splat(null),
    tmt1_count: u32 = 0,
    tmt2_count: u32 = 0,
    tmt1_secs: u32 = 0,
    tmt2_secs: u32 = 0,
    busy_minutes: u64 = 0,
    host_reads: u64 = 0,
    host_writes: u64 = 0,

    pub fn throttleCount(self: Thermal) u64 {
        return @as(u64, self.tmt1_count) + self.tmt2_count;
    }
};

/// Pure: 512-byte health log -> Thermal. Implausible sensor values (0 = not implemented) become null.
pub fn parseThermal(log: *const [512]u8) Thermal {
    var t = Thermal{};
    t.busy_minutes = std.mem.readInt(u64, log[96..104], .little);
    t.host_reads = std.mem.readInt(u64, log[64..72], .little);
    t.host_writes = std.mem.readInt(u64, log[80..88], .little);
    t.warn_temp_minutes = std.mem.readInt(u32, log[192..196], .little);
    t.crit_temp_minutes = std.mem.readInt(u32, log[196..200], .little);
    for (0..8) |i| {
        const k = std.mem.readInt(u16, log[200 + i * 2 ..][0..2], .little);
        t.sensors_c[i] = if (k >= 200 and k <= 400) @as(i16, @intCast(k)) - 273 else null;
    }
    t.tmt1_count = std.mem.readInt(u32, log[216..220], .little);
    t.tmt2_count = std.mem.readInt(u32, log[220..224], .little);
    t.tmt1_secs = std.mem.readInt(u32, log[224..228], .little);
    t.tmt2_secs = std.mem.readInt(u32, log[228..232], .little);
    return t;
}

/// StorageDeviceTemperatureProperty (51): Windows' generic temperature, for disks that do not answer the
/// NVMe health log. Same plausibility rule as the engine.
pub fn queryTempProperty(h: HANDLE) ?i16 {
    var q = [_]u8{0} ** 12;
    std.mem.writeInt(u32, q[0..4], 51, .little);
    var out: [512]u8 align(8) = @splat(0);
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, q.len, &out, out.len, &ret, null) == 0 or ret < 40) return null;
    if (std.mem.readInt(u16, out[12..14], .little) == 0) return null;
    const t = std.mem.readInt(i16, out[26..28], .little);
    if (t < -20 or t > 120) return null;
    return t;
}

/// Pure: composite temperature of a health log, null when implausible.
pub fn logTempC(log: *const [512]u8) ?i16 {
    const k = std.mem.readInt(u16, log[1..3], .little);
    if (k < 200 or k > 400) return null;
    return @as(i16, @intCast(k)) - 273;
}

pub const Identify = struct {
    /// 0 = the controller does not report its version (NVMe 1.0/1.1 may leave VER at 0).
    ver_major: u16 = 0,
    ver_minor: u8 = 0,
    wctemp_c: ?i16 = null,
    cctemp_c: ?i16 = null,
    volatile_cache: bool = false,
    /// Host Controlled Thermal Management supported (HCTMA). The throttle counters of the health log
    /// (bytes 216-231) only count transitions of that mechanism; without it they stay at 0.
    hctm: bool = false,
};

/// Pure: 4096-byte Identify Controller data -> the fields NVMeForge shows.
pub fn parseIdentify(id: *const [4096]u8) Identify {
    var r = Identify{};
    const ver = std.mem.readInt(u32, id[80..84], .little);
    r.ver_major = @intCast(ver >> 16);
    r.ver_minor = @intCast((ver >> 8) & 0xFF);
    const wc = std.mem.readInt(u16, id[266..268], .little);
    const cc = std.mem.readInt(u16, id[268..270], .little);
    if (wc >= 273 and wc <= 400) r.wctemp_c = @as(i16, @intCast(wc)) - 273;
    if (cc >= 273 and cc <= 400) r.cctemp_c = @as(i16, @intCast(cc)) - 273;
    r.volatile_cache = (id[525] & 1) != 0;
    r.hctm = (id[322] & 1) != 0;
    return r;
}

pub fn queryIdentify(h: HANDLE) ?Identify {
    var id: [4096]u8 = undefined;
    // Microsoft documents Identify Controller through the adapter property; some drivers answer the device one.
    if (!nvmeQuery(h, 49, 1, 1, &id) and !nvmeQuery(h, 50, 1, 1, &id)) return null;
    const r = parseIdentify(&id);
    if (r.ver_major > 9) return null; // not a plausible NVMe version: do not trust the page
    return r;
}

// =====================================================================================================
// Propiedades de Windows: TRIM y caché de escritura
// =====================================================================================================

/// StorageDeviceTrimProperty (8): does the disk accept TRIM (DEVICE_TRIM_DESCRIPTOR.TrimEnabled)?
pub fn queryTrim(h: HANDLE) ?bool {
    var q = [_]u8{0} ** 12;
    std.mem.writeInt(u32, q[0..4], 8, .little);
    var out: [16]u8 align(8) = @splat(0);
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, q.len, &out, out.len, &ret, null) == 0 or ret < 9) return null;
    return out[8] != 0;
}

pub const WriteCache = struct {
    enabled: ?bool,
    changeable: bool,
    /// "Desactivar el vaciado de caché de escritura de Windows" in Device Manager.
    flush_off: bool,
};

/// StorageDeviceWriteCacheProperty (4) -> STORAGE_WRITE_CACHE_PROPERTY.
pub fn queryWriteCache(h: HANDLE) ?WriteCache {
    var q = [_]u8{0} ** 12;
    std.mem.writeInt(u32, q[0..4], 4, .little);
    var out: [32]u8 align(8) = @splat(0);
    var ret: u32 = 0;
    if (DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, q.len, &out, out.len, &ret, null) == 0 or ret < 27) return null;
    return parseWriteCache(&out);
}

/// Pure: STORAGE_WRITE_CACHE_PROPERTY bytes -> WriteCache.
pub fn parseWriteCache(out: *const [32]u8) WriteCache {
    const en = std.mem.readInt(u32, out[12..16], .little); // 0 unknown, 1 disabled, 2 enabled
    const ch = std.mem.readInt(u32, out[16..20], .little); // 0 unknown, 1 not changeable, 2 changeable
    return .{
        .enabled = switch (en) {
            1 => false,
            2 => true,
            else => null,
        },
        .changeable = ch == 2,
        .flush_off = out[25] != 0,
    };
}

/// fsutil behavior query DisableDeleteNotify (NTFS): true = Windows sends TRIM. null = value not present.
pub fn osTrimEnabled() ?bool {
    const sub = std.unicode.utf8ToUtf16LeStringLiteral("SYSTEM\\CurrentControlSet\\Control\\FileSystem");
    const name = std.unicode.utf8ToUtf16LeStringLiteral("DisableDeleteNotification");
    var v: u32 = 0;
    var size: u32 = 4;
    const HKLM: *anyopaque = @ptrFromInt(0x80000002);
    if (RegGetValueW(HKLM, sub, name, 0x10, null, &v, &size) != 0) return null; // RRF_RT_REG_DWORD
    return v == 0;
}

// =====================================================================================================
// Enlace PCIe del controlador NVMe (SetupAPI + CfgMgr: DEVPKEY_PciDevice_*)
// =====================================================================================================

pub const PcieLink = struct { cur_gen: u8, cur_width: u8, max_gen: u8, max_width: u8 };

const GUID_DEVINTERFACE_DISK = GUID{ .d1 = 0x53f56307, .d2 = 0xb6bf, .d3 = 0x11d0, .d4 = .{ 0x94, 0xf2, 0x00, 0xa0, 0xc9, 0x1e, 0xfb, 0x8b } };
const PCI_PROPS = GUID{ .d1 = 0x3ab22e31, .d2 = 0x8264, .d3 = 0x4b4e, .d4 = .{ 0x9a, 0xf5, 0xa8, 0xd2, 0xd8, 0xe3, 0x3e, 0x62 } };

fn pciU32(inst: u32, pid: u32) ?u32 {
    const key = DEVPROPKEY{ .fmtid = PCI_PROPS, .pid = pid };
    var typ: u32 = 0;
    var v: u32 = 0;
    var size: u32 = 4;
    if (CM_Get_DevNode_PropertyW(inst, &key, &typ, &v, &size, 0) != 0 or size != 4) return null;
    return v;
}

/// Device instance of the disk interface whose STORAGE_DEVICE_NUMBER is `disk`.
fn diskDevInst(disk: u32) ?u32 {
    const set = SetupDiGetClassDevsW(&GUID_DEVINTERFACE_DISK, null, null, 0x2 | 0x10); // PRESENT | DEVICEINTERFACE
    if (set == INVALID_HANDLE_VALUE) return null;
    defer _ = SetupDiDestroyDeviceInfoList(set);
    var idx: u32 = 0;
    while (idx < 64) : (idx += 1) {
        var ifd = SP_DEVICE_INTERFACE_DATA{ .cb_size = @sizeOf(SP_DEVICE_INTERFACE_DATA), .guid = undefined, .flags = 0, .reserved = 0 };
        if (SetupDiEnumDeviceInterfaces(set, null, &GUID_DEVINTERFACE_DISK, idx, &ifd) == 0) break;
        var detail: [1024]u8 align(8) = @splat(0);
        std.mem.writeInt(u32, detail[0..4], if (@sizeOf(usize) == 8) 8 else 6, .little); // cbSize of the fixed part
        var info = SP_DEVINFO_DATA{ .cb_size = @sizeOf(SP_DEVINFO_DATA), .class_guid = undefined, .dev_inst = 0, .reserved = 0 };
        if (SetupDiGetDeviceInterfaceDetailW(set, &ifd, &detail, detail.len - 2, null, &info) == 0) continue;
        const path: [*:0]const u16 = @ptrCast(@alignCast(&detail[4]));
        const h = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        if (h == INVALID_HANDLE_VALUE) continue;
        var num: [12]u8 align(4) = undefined;
        var ret: u32 = 0;
        const ok = DeviceIoControl(h, IOCTL_STORAGE_GET_DEVICE_NUMBER, null, 0, &num, num.len, &ret, null) != 0 and ret >= 8;
        _ = CloseHandle(h);
        if (ok and std.mem.readInt(u32, num[4..8], .little) == disk) return info.dev_inst;
    }
    return null;
}

/// PCIe generation and lanes of the controller the disk hangs from. null for USB adapters, RAID/VMD layers
/// that hide the PCI device, or when Windows does not report the link.
pub fn queryPcieLink(disk: u32) ?PcieLink {
    const inst = diskDevInst(disk) orelse return null;
    var parent: u32 = 0;
    if (CM_Get_Parent(&parent, inst, 0) != 0) return null;
    var id: [256]u16 = @splat(0);
    if (CM_Get_Device_IDW(parent, &id, id.len - 1, 0) != 0) return null;
    if (!(id[0] == 'P' and id[1] == 'C' and id[2] == 'I' and id[3] == '\\')) return null;
    const cs = pciU32(parent, 9) orelse return null;
    const cw = pciU32(parent, 10) orelse return null;
    const ms = pciU32(parent, 11) orelse cs;
    const mw = pciU32(parent, 12) orelse cw;
    if (cs == 0 or cs > 7 or cw == 0 or cw > 32) return null;
    return .{ .cur_gen = @intCast(cs), .cur_width = @intCast(cw), .max_gen = @intCast(@min(ms, 7)), .max_width = @intCast(@min(mw, 32)) };
}

/// Pure: usable bandwidth of a PCIe link in MB/s (10^6), after line encoding (8b/10b for Gen1-2,
/// 128b/130b from Gen3). Packet overhead is not subtracted: real disks top out ~90-95 % of this.
pub fn pcieLinkMBs(gen: u8, width: u8) ?f64 {
    const per_lane: f64 = switch (gen) {
        1 => 250.0,
        2 => 500.0,
        3 => 984.6,
        4 => 1969.2,
        5 => 3938.5,
        6 => 7563.0,
        else => return null,
    };
    return per_lane * @as(f64, @floatFromInt(width));
}

// =====================================================================================================
// Energía: ASPM de PCI Express y modo de energía de Windows 11
// =====================================================================================================

pub const PowerCfg = struct { aspm_ac: ?u32 = null, aspm_dc: ?u32 = null, mode: []const u8 = "desconocido" };

const SUB_PCIEXPRESS = GUID{ .d1 = 0x501a4d13, .d2 = 0x42af, .d3 = 0x4429, .d4 = .{ 0x9f, 0xd1, 0xa8, 0x21, 0x8c, 0x26, 0x8e, 0x20 } };
const ASPM_SETTING = GUID{ .d1 = 0xee12f906, .d2 = 0xd277, .d3 = 0x404b, .d4 = .{ 0xb6, 0xda, 0xe5, 0xfa, 0x1a, 0x57, 0x6d, 0xf5 } };
const OVERLAY_EFFICIENCY = GUID{ .d1 = 0x961cc777, .d2 = 0x2547, .d3 = 0x4f9d, .d4 = .{ 0x81, 0x74, 0x7d, 0x86, 0x18, 0x1b, 0x8a, 0x7a } };
const OVERLAY_BETTER_W10 = GUID{ .d1 = 0x3af9b8d9, .d2 = 0x7c97, .d3 = 0x431d, .d4 = .{ 0xad, 0x78, 0x34, 0xa8, 0xbf, 0xea, 0x43, 0x9f } };
const SCHEME_BALANCED = GUID{ .d1 = 0x381b4222, .d2 = 0xf694, .d3 = 0x41f0, .d4 = .{ 0x96, 0x85, 0xff, 0x5b, 0xb2, 0x60, 0xdf, 0x2e } };
const SCHEME_HIGH = GUID{ .d1 = 0x8c5e7fda, .d2 = 0xe8bf, .d3 = 0x4a96, .d4 = .{ 0x9a, 0x85, 0xa6, 0xe2, 0x3a, 0x8c, 0x63, 0x5c } };
const SCHEME_ULTIMATE = GUID{ .d1 = 0xe9a42b02, .d2 = 0xd5df, .d3 = 0x448d, .d4 = .{ 0xaa, 0x00, 0x03, 0xf1, 0x47, 0x49, 0xeb, 0x61 } };
const OVERLAY_PERFORMANCE = GUID{ .d1 = 0xded574b5, .d2 = 0x45a0, .d3 = 0x4f42, .d4 = .{ 0x87, 0x37, 0x46, 0x34, 0x5c, 0x09, 0xc2, 0x38 } };

fn guidEql(a: GUID, b: GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
}

var g_overlay_fn: ?OverlayFn = null;
var g_overlay_resolved = std.atomic.Value(bool).init(false);

/// PowerGetEffectiveOverlayScheme is not in every Windows 10 build: resolve it once at run time so the
/// .exe still starts where it is missing (the mode is then reported as "desconocido").
fn overlayFn() ?OverlayFn {
    if (!g_overlay_resolved.load(.acquire)) {
        if (LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("powrprof.dll"))) |lib| {
            if (GetProcAddress(lib, "PowerGetEffectiveOverlayScheme")) |sym| g_overlay_fn = @ptrCast(sym);
        }
        g_overlay_resolved.store(true, .release);
    }
    return g_overlay_fn;
}

/// Read only: never changes a power setting. The Windows "power mode" slider only exists on the Balanced
/// plan; with any other plan the plan itself decides, so it is reported instead of the overlay.
pub fn queryPower() PowerCfg {
    var r = PowerCfg{};
    var scheme: ?*GUID = null;
    if (PowerGetActiveScheme(null, &scheme) != 0) return r;
    const s = scheme orelse return r;
    defer _ = LocalFree(s);
    var v: u32 = 0;
    if (PowerReadACValueIndex(null, s, &SUB_PCIEXPRESS, &ASPM_SETTING, &v) == 0 and v <= 2) r.aspm_ac = v;
    if (PowerReadDCValueIndex(null, s, &SUB_PCIEXPRESS, &ASPM_SETTING, &v) == 0 and v <= 2) r.aspm_dc = v;
    r.mode = planMode(s.*, blk: {
        const f = overlayFn() orelse break :blk null;
        var ov: GUID = std.mem.zeroes(GUID);
        break :blk if (f(&ov) == 0) ov else null;
    });
    return r;
}

/// Pure: active plan + effective overlay -> mode name for the UI.
pub fn planMode(scheme: GUID, overlay: ?GUID) []const u8 {
    if (guidEql(scheme, SCHEME_HIGH)) return "plan_alto";
    if (guidEql(scheme, SCHEME_ULTIMATE)) return "plan_maximo";
    if (!guidEql(scheme, SCHEME_BALANCED)) return "plan_otro";
    const ov = overlay orelse return "desconocido";
    if (guidEql(ov, OVERLAY_PERFORMANCE)) return "rendimiento";
    if (guidEql(ov, OVERLAY_BETTER_W10)) return "mejor";
    if (guidEql(ov, OVERLAY_EFFICIENCY)) return "eficiencia";
    if (guidEql(ov, std.mem.zeroes(GUID))) return "equilibrado";
    return "desconocido";
}

// =====================================================================================================
// Banco de pruebas (F11): 4 pruebas tipo CrystalDiskMark sobre un archivo temporal
// =====================================================================================================

pub const TestDef = struct { label: []const u8, block: u32, qd: u32, random: bool };
pub const TESTS = [_]TestDef{
    .{ .label = "SEQ1M Q8T1", .block = 1 << 20, .qd = 8, .random = false },
    .{ .label = "SEQ1M Q1T1", .block = 1 << 20, .qd = 1, .random = false },
    .{ .label = "RND4K Q32T1", .block = 4096, .qd = 32, .random = true },
    .{ .label = "RND4K Q1T1", .block = 4096, .qd = 1, .random = true },
};
const MAX_QD = 32;
const SLOT_BYTES: usize = 1 << 20;
pub const FILE_NAME = "NVMeForge-prueba.tmp";
/// Removes a temporary file left by a run cut by a power loss or a crash of Windows (DELETE_ON_CLOSE does
/// not get to run then). Only on fixed drives, only that exact file name. Call once at startup.
pub fn cleanupLeftovers() void {
    var letter: u8 = 'C';
    while (letter <= 'Z') : (letter += 1) {
        const root = [_:0]u16{ letter, ':', '\\' };
        if (GetDriveTypeW(&root) != 3) continue; // DRIVE_FIXED
        var path: [32:0]u16 = undefined;
        const tail = std.unicode.utf8ToUtf16LeStringLiteral(FILE_NAME);
        path[0] = letter;
        path[1] = ':';
        path[2] = '\\';
        @memcpy(path[3 .. 3 + tail.len], tail);
        path[3 + tail.len] = 0;
        _ = DeleteFileW(&path);
    }
}

pub const MARGIN_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// Seconds per pass (CrystalDiskMark default: 5) and pause between tests so the disk is not measured hot.
pub const PASS_SECS: u32 = 5;
pub const PAUSE_SECS: u32 = 3;

pub const Cell = struct { mbs: f64 = -1, iops: f64 = -1, lat_us: f64 = -1 };
pub const Phase = enum { idle, prep, read, write, pause, done, cancelled, failed };

pub const Snap = struct {
    phase: Phase = .idle,
    test_idx: u8 = 0,
    pass: u8 = 0,
    passes: u8 = 3,
    pass_secs: u8 = PASS_SECS,
    disk: u32 = 0,
    letter: u8 = 'C',
    file_bytes: u64 = 0,
    prep_done: u64 = 0,
    live_mbs: f64 = 0,
    read: [TESTS.len]Cell = @splat(.{}),
    write: [TESTS.len]Cell = @splat(.{}),
    temp_now: ?i16 = null,
    temp_start: ?i16 = null,
    temp_max: ?i16 = null,
    throttle_start: ?u64 = null,
    throttle_now: ?u64 = null,
    /// Minutes above the warning + critical composite temperature (health log), at start and now.
    hot_start: ?u64 = null,
    hot_now: ?u64 = null,
    on_battery: bool = false,
    started_ms: i64 = 0,
    ended_ms: i64 = 0,
    msg: [200]u8 = undefined,
    msg_len: usize = 0,

    pub fn message(self: *const Snap) []const u8 {
        return self.msg[0..self.msg_len];
    }
    pub fn throttleEvents(self: *const Snap) ?u64 {
        const a = self.throttle_start orelse return null;
        const b = self.throttle_now orelse return null;
        return if (b >= a) b - a else null;
    }
    pub fn hotMinutes(self: *const Snap) ?u64 {
        const a = self.hot_start orelse return null;
        const b = self.hot_now orelse return null;
        return if (b >= a) b - a else null;
    }
    pub fn finished(self: *const Snap) bool {
        return self.phase == .done or self.phase == .cancelled or self.phase == .failed;
    }
};

var g_mutex: std.Thread.Mutex = .{};
var g_snap: Snap = .{};
var g_cancel = std.atomic.Value(bool).init(false);
var g_monitor_stop = std.atomic.Value(bool).init(false);
/// Set by the engine: called once when a run ends (any outcome), from the bench thread, to record history
/// and release its "benchmark running" flag.
pub var on_finish: ?*const fn (snap: *const Snap) void = null;

pub fn snapshot() Snap {
    g_mutex.lock();
    defer g_mutex.unlock();
    return g_snap;
}

pub fn requestCancel() void {
    g_cancel.store(true, .seq_cst);
}

fn setMsg(comptime fmt: []const u8, args: anytype) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    const s = std.fmt.bufPrint(&g_snap.msg, fmt, args) catch g_snap.msg[0..0];
    g_snap.msg_len = s.len;
}

fn setPhase(p: Phase, test_idx: u8, pass: u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_snap.phase = p;
    g_snap.test_idx = test_idx;
    g_snap.pass = pass;
    g_snap.live_mbs = 0;
}

fn nowMs() i64 {
    return std.time.milliTimestamp();
}

fn qpc() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceCounter(&v);
    return v;
}

fn qpf() i64 {
    var v: i64 = 1;
    _ = QueryPerformanceFrequency(&v);
    return if (v > 0) v else 1;
}

pub const StartError = error{ AlreadyRunning, ThreadFailed };

pub const Params = struct {
    disk: u32,
    letter: u8,
    passes: u8,
    file_bytes: u64,
    on_battery: bool,
};

/// Starts the run in its own thread. The caller has already validated the disk, the letter (a fixed
/// volume of that disk), free space and that no clone is running.
pub fn start(p: Params) StartError!void {
    {
        g_mutex.lock();
        defer g_mutex.unlock();
        if (g_snap.phase == .prep or g_snap.phase == .read or g_snap.phase == .write or g_snap.phase == .pause) return error.AlreadyRunning;
        g_snap = .{
            .phase = .prep,
            .passes = p.passes,
            .disk = p.disk,
            .letter = p.letter,
            .file_bytes = p.file_bytes,
            .on_battery = p.on_battery,
            .started_ms = nowMs(),
        };
        g_snap.msg_len = 0;
    }
    g_cancel.store(false, .seq_cst);
    const t = std.Thread.spawn(.{}, runThread, .{p}) catch {
        g_mutex.lock();
        g_snap.phase = .failed;
        g_mutex.unlock();
        return error.ThreadFailed;
    };
    t.detach();
}

fn monitorThread(disk: u32) void {
    var path_buf: [40]u8 = undefined;
    const p8 = std.fmt.bufPrint(&path_buf, "\\\\.\\PhysicalDrive{d}", .{disk}) catch return;
    var wbuf: [40:0]u16 = undefined;
    const wl = std.unicode.utf8ToUtf16Le(&wbuf, p8) catch return;
    wbuf[wl] = 0;
    const h = CreateFileW(&wbuf, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE) return;
    defer _ = CloseHandle(h);
    while (!g_monitor_stop.load(.seq_cst)) {
        var log: [512]u8 = undefined;
        const have_log = queryHealthLog(h, &log);
        const t: ?i16 = if (have_log) logTempC(&log) else queryTempProperty(h);
        g_mutex.lock();
        if (t) |c| {
            g_snap.temp_now = c;
            if (g_snap.temp_start == null) g_snap.temp_start = c;
            if (g_snap.temp_max == null or c > g_snap.temp_max.?) g_snap.temp_max = c;
        }
        if (have_log) {
            const th = parseThermal(&log);
            const hot = @as(u64, th.warn_temp_minutes) + th.crit_temp_minutes;
            if (g_snap.throttle_start == null) g_snap.throttle_start = th.throttleCount();
            g_snap.throttle_now = th.throttleCount();
            if (g_snap.hot_start == null) g_snap.hot_start = hot;
            g_snap.hot_now = hot;
        }
        g_mutex.unlock();
        var k: u32 = 0;
        while (k < 10 and !g_monitor_stop.load(.seq_cst)) : (k += 1) Sleep(100);
    }
}

const Io = struct {
    h: HANDLE,
    port: *anyopaque,
    bufs: [*]u8,
    slots: [MAX_QD]OVERLAPPED = @splat(.{}),
    start: [MAX_QD]i64 = @splat(0),
    freq: i64,

    fn slotIndex(self: *Io, ov: *OVERLAPPED) usize {
        return (@intFromPtr(ov) - @intFromPtr(&self.slots[0])) / @sizeOf(OVERLAPPED);
    }

    /// Queues one I/O on slot i. false = the request was refused immediately (no completion will come).
    fn issue(self: *Io, i: usize, is_write: bool, offset: u64, len: u32) bool {
        self.slots[i] = .{ .offset = @truncate(offset), .offset_high = @truncate(offset >> 32) };
        self.start[i] = qpc();
        const buf = self.bufs + i * SLOT_BYTES;
        const ok = if (is_write) WriteFile(self.h, buf, len, null, &self.slots[i]) else ReadFile(self.h, buf, len, null, &self.slots[i]);
        if (ok != 0) return true; // completed at once: the completion packet is still queued to the port
        return GetLastError() == ERROR_IO_PENDING;
    }

    /// Cancels and waits for every outstanding request so buffers and the handle can be released safely.
    fn drain(self: *Io, outstanding: *u32) void {
        if (outstanding.* == 0) return;
        _ = CancelIoEx(self.h, null);
        // Never give up while a request is in flight: the kernel still owns its OVERLAPPED (on our stack)
        // and its buffer. A device that never answers keeps this thread waiting rather than freeing them.
        while (outstanding.* > 0) {
            var n: u32 = 0;
            var key: usize = 0;
            var ov: ?*OVERLAPPED = null;
            _ = GetQueuedCompletionStatus(self.port, &n, &key, &ov, 1000);
            if (ov != null) outstanding.* -= 1;
        }
    }
};

const PassError = error{ IoFailed, Cancelled };

/// Pure helper: next sequential offset inside a file of `size` bytes (wraps at the end).
pub fn nextSeq(prev: u64, block: u64, size: u64) u64 {
    const n = prev + block;
    return if (n + block > size) 0 else n;
}

/// Pure: throughput in MB/s (10^6 bytes) from bytes and QPC ticks.
pub fn mbsFrom(bytes: u64, ticks: i64, freq: i64) f64 {
    if (ticks <= 0 or freq <= 0) return 0;
    const secs = @as(f64, @floatFromInt(ticks)) / @as(f64, @floatFromInt(freq));
    return @as(f64, @floatFromInt(bytes)) / 1e6 / secs;
}

/// One timed pass: keeps `def.qd` requests in flight for `secs` seconds and measures what completed.
fn runPass(io: *Io, def: TestDef, is_write: bool, size: u64, secs: u32, rng: std.Random) PassError!Cell {
    const blocks = size / def.block;
    var outstanding: u32 = 0;
    var seq_next: u64 = 0;
    var bytes: u64 = 0;
    var ops: u64 = 0;
    var lat_ticks: i64 = 0;
    var failed = false;
    const t0 = qpc();
    const deadline = t0 + io.freq * @as(i64, secs);
    var last_live = t0;
    var t_end = t0;

    var i: usize = 0;
    while (i < def.qd) : (i += 1) {
        const off = if (def.random) rng.uintLessThan(u64, blocks) * def.block else blk: {
            const o = seq_next;
            seq_next = nextSeq(seq_next, def.block, size);
            break :blk o;
        };
        if (!io.issue(i, is_write, off, def.block)) {
            failed = true;
            break;
        }
        outstanding += 1;
    }
    while (outstanding > 0) {
        var n: u32 = 0;
        var key: usize = 0;
        var ov: ?*OVERLAPPED = null;
        const ok = GetQueuedCompletionStatus(io.port, &n, &key, &ov, 15000);
        const ovp = ov orelse { // timeout or port failure: nothing dequeued
            failed = true;
            break;
        };
        outstanding -= 1;
        const now = qpc();
        const idx = io.slotIndex(ovp);
        if (ok == 0 or n != def.block) {
            failed = true;
        } else {
            bytes += n;
            ops += 1;
            lat_ticks += now - io.start[idx];
            t_end = now;
        }
        if (now - last_live > @divTrunc(io.freq, 4)) {
            last_live = now;
            const live = mbsFrom(bytes, now - t0, io.freq);
            g_mutex.lock();
            g_snap.live_mbs = live;
            g_mutex.unlock();
        }
        if (failed or g_cancel.load(.seq_cst) or now >= deadline) continue; // stop issuing; let the rest complete
        const off = if (def.random) rng.uintLessThan(u64, blocks) * def.block else blk: {
            const o = seq_next;
            seq_next = nextSeq(seq_next, def.block, size);
            break :blk o;
        };
        if (!io.issue(idx, is_write, off, def.block)) {
            failed = true;
            continue;
        }
        outstanding += 1;
    }
    io.drain(&outstanding);
    if (failed) return error.IoFailed;
    if (g_cancel.load(.seq_cst)) return error.Cancelled;
    if (ops == 0) return error.IoFailed;
    const mbs = mbsFrom(bytes, t_end - t0, io.freq);
    const secs_f = @as(f64, @floatFromInt(t_end - t0)) / @as(f64, @floatFromInt(io.freq));
    return .{
        .mbs = mbs,
        .iops = @as(f64, @floatFromInt(ops)) / secs_f,
        .lat_us = @as(f64, @floatFromInt(lat_ticks)) / @as(f64, @floatFromInt(ops)) / @as(f64, @floatFromInt(io.freq)) * 1e6,
    };
}

/// Writes the whole file once (incompressible data) so the read tests read real, allocated data.
fn fillFile(io: *Io, size: u64) PassError!void {
    const block: u32 = 1 << 20;
    var outstanding: u32 = 0;
    var next: u64 = 0;
    var done: u64 = 0;
    var failed = false;
    var i: usize = 0;
    while (i < 8 and next < size) : (i += 1) {
        if (!io.issue(i, true, next, block)) {
            failed = true;
            break;
        }
        next += block;
        outstanding += 1;
    }
    while (outstanding > 0) {
        var n: u32 = 0;
        var key: usize = 0;
        var ov: ?*OVERLAPPED = null;
        const ok = GetQueuedCompletionStatus(io.port, &n, &key, &ov, 30000);
        const ovp = ov orelse {
            failed = true;
            break;
        };
        outstanding -= 1;
        if (ok == 0 or n != block) failed = true else done += n;
        g_mutex.lock();
        g_snap.prep_done = done;
        g_mutex.unlock();
        if (failed or g_cancel.load(.seq_cst) or next >= size) continue;
        if (!io.issue(io.slotIndex(ovp), true, next, block)) {
            failed = true;
            continue;
        }
        next += block;
        outstanding += 1;
    }
    io.drain(&outstanding);
    if (failed) return error.IoFailed;
    if (g_cancel.load(.seq_cst)) return error.Cancelled;
}

fn pauseBetween(secs: u32) bool {
    var k: u32 = 0;
    while (k < secs * 10) : (k += 1) {
        if (g_cancel.load(.seq_cst)) return false;
        Sleep(100);
    }
    return true;
}

fn runThread(p: Params) void {
    g_monitor_stop.store(false, .seq_cst);
    const mon = std.Thread.spawn(.{}, monitorThread, .{p.disk}) catch null;
    // runInner closes (and so deletes) the temporary file and frees every buffer before returning.
    const ph = runInner(p);
    g_monitor_stop.store(true, .seq_cst);
    if (mon) |m| m.join();
    g_mutex.lock();
    g_snap.phase = ph;
    g_snap.ended_ms = nowMs();
    g_snap.live_mbs = 0;
    const copy = g_snap;
    g_mutex.unlock();
    if (on_finish) |f| f(&copy);
}

fn cancelled() Phase {
    setMsg("Prueba cancelada. El archivo temporal se borró.", .{});
    return .cancelled;
}

fn runInner(p: Params) Phase {
    var path: [32:0]u16 = undefined;
    {
        const pre = [_]u16{ p.letter, ':', '\\' };
        @memcpy(path[0..3], &pre);
        const tail = std.unicode.utf8ToUtf16LeStringLiteral(FILE_NAME);
        @memcpy(path[3 .. 3 + tail.len], tail);
        path[3 + tail.len] = 0;
    }
    const flags = FILE_FLAG_NO_BUFFERING | FILE_FLAG_OVERLAPPED | FILE_FLAG_DELETE_ON_CLOSE | FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_TEMPORARY;
    const access = GENERIC_READ | GENERIC_WRITE | DELETE_ACCESS;
    var h = CreateFileW(&path, access, 0, null, CREATE_NEW, flags, null);
    if (h == INVALID_HANDLE_VALUE and GetLastError() == ERROR_FILE_EXISTS) {
        // Leftover of a run cut by a power loss (DELETE_ON_CLOSE covers crashes, not power cuts).
        _ = DeleteFileW(&path);
        h = CreateFileW(&path, access, 0, null, CREATE_NEW, flags, null);
    }
    if (h == INVALID_HANDLE_VALUE) {
        setMsg("[NVF-E042] No se pudo crear el archivo de prueba en {c}: (error {d}).", .{ p.letter, GetLastError() });
        return .failed;
    }
    defer _ = CloseHandle(h); // DELETE_ON_CLOSE: the file disappears here

    if (SetFilePointerEx(h, @intCast(p.file_bytes), null, 0) == 0 or SetEndOfFile(h) == 0) {
        setMsg("[NVF-E042] No hay espacio para el archivo de prueba de {d} MiB en {c}:.", .{ p.file_bytes >> 20, p.letter });
        return .failed;
    }
    const port = CreateIoCompletionPort(h, null, 1, 1) orelse {
        setMsg("[NVF-E043] Windows no permitió la E/S asíncrona del archivo de prueba (error {d}).", .{GetLastError()});
        return .failed;
    };
    defer _ = CloseHandle(port);
    const bufs = VirtualAlloc(null, MAX_QD * SLOT_BYTES, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE) orelse {
        setMsg("[NVF-E043] No hay memoria para los búferes de la prueba.", .{});
        return .failed;
    };
    defer _ = VirtualFree(bufs, 0, MEM_RELEASE);
    var prng = std.Random.DefaultPrng.init(@as(u64, @bitCast(qpc())));
    const rng = prng.random();
    rng.bytes(bufs[0 .. MAX_QD * SLOT_BYTES]); // incompressible data, like CrystalDiskMark's default

    var io = Io{ .h = h, .port = port, .bufs = bufs, .freq = qpf() };

    setMsg("Preparando un archivo de {d} MiB en {c}: con datos aleatorios.", .{ p.file_bytes >> 20, p.letter });
    fillFile(&io, p.file_bytes) catch |e| {
        if (e == error.Cancelled) return cancelled();
        setMsg("[NVF-E043] Falló una escritura al preparar el archivo de prueba en {c}:.", .{p.letter});
        return .failed;
    };
    _ = FlushFileBuffers(h);
    if (!pauseBetween(2)) return cancelled();

    for ([_]bool{ false, true }) |is_write| {
        for (TESTS, 0..) |def, ti| {
            var best = Cell{};
            var pi: u8 = 0;
            while (pi < p.passes) : (pi += 1) {
                setPhase(if (is_write) .write else .read, @intCast(ti), pi + 1);
                setMsg("{s} {s}, pasada {d} de {d}.", .{ if (is_write) "Escritura" else "Lectura", def.label, pi + 1, p.passes });
                const c = runPass(&io, def, is_write, p.file_bytes, PASS_SECS, rng) catch |e| {
                    if (e == error.Cancelled) return cancelled();
                    setMsg("[NVF-E043] Falló una {s} durante {s} en {c}:. Revisa el disco en el Visor de eventos.", .{ if (is_write) "escritura" else "lectura", def.label, p.letter });
                    return .failed;
                };
                if (c.mbs > best.mbs) best = c;
                g_mutex.lock();
                if (is_write) g_snap.write[ti] = best else g_snap.read[ti] = best;
                g_mutex.unlock();
            }
            const last = is_write and ti == TESTS.len - 1;
            if (!last) {
                setPhase(.pause, @intCast(ti), 0);
                if (!pauseBetween(PAUSE_SECS)) return cancelled();
            }
        }
    }
    setMsg("Prueba terminada. El archivo temporal se borró.", .{});
    return .done;
}

// =====================================================================================================
// JSON del progreso
// =====================================================================================================

fn cellJson(w: *std.Io.Writer, c: Cell) !void {
    if (c.mbs < 0) return w.writeAll("null");
    try w.print("{{\"mbs\":{d:.2},\"iops\":{d:.0},\"lat_us\":{d:.1}}}", .{ c.mbs, c.iops, c.lat_us });
}

fn optI(w: *std.Io.Writer, v: anytype) !void {
    if (v) |x| try w.print("{d}", .{x}) else try w.writeAll("null");
}

/// JSON of a snapshot. `msg` is escaped by the caller-provided escaper (shared with the engine).
pub fn snapJson(buf: []u8, s: *const Snap, escaped_msg: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeSnap(&w, s, escaped_msg) catch return "{\"phase\":\"failed\"}";
    return w.buffered();
}

fn writeSnap(w: *std.Io.Writer, s: *const Snap, escaped_msg: []const u8) !void {
    const running = !s.finished() and s.phase != .idle;
    const elapsed: i64 = if (s.started_ms == 0) 0 else (if (s.ended_ms != 0) s.ended_ms else nowMs()) - s.started_ms;
    try w.print("{{\"phase\":\"{s}\",\"running\":{s},\"test\":{d},\"pass\":{d},\"passes\":{d},\"pass_secs\":{d},\"disk\":{d},\"letter\":\"{c}:\",\"file_bytes\":{d},\"prep_done\":{d},\"live_mbs\":{d:.1},\"elapsed_ms\":{d},\"ended_ms\":{d},\"on_battery\":{s}", .{
        @tagName(s.phase), if (running) "true" else "false", s.test_idx, s.pass, s.passes, s.pass_secs, s.disk, s.letter, s.file_bytes, s.prep_done, s.live_mbs, elapsed, s.ended_ms, if (s.on_battery) "true" else "false",
    });
    try w.writeAll(",\"tests\":[");
    for (TESTS, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{t.label});
    }
    try w.writeAll("],\"read\":[");
    for (s.read, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try cellJson(w, c);
    }
    try w.writeAll("],\"write\":[");
    for (s.write, 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try cellJson(w, c);
    }
    try w.writeAll("],\"temp_c\":");
    try optI(w, s.temp_now);
    try w.writeAll(",\"temp_start_c\":");
    try optI(w, s.temp_start);
    try w.writeAll(",\"temp_max_c\":");
    try optI(w, s.temp_max);
    try w.writeAll(",\"throttle_events\":");
    try optI(w, s.throttleEvents());
    try w.writeAll(",\"hot_minutes\":");
    try optI(w, s.hotMinutes());
    try w.print(",\"message\":\"{s}\"}}", .{escaped_msg});
}

// =====================================================================================================
// Pruebas (funciones puras; no tocan discos)
// =====================================================================================================

test "parseThermal lee los contadores térmicos del log de salud" {
    var log: [512]u8 = @splat(0);
    std.mem.writeInt(u16, log[1..3], 313, .little);
    std.mem.writeInt(u64, log[96..104], 0x40, .little);
    std.mem.writeInt(u32, log[192..196], 0x0E, .little);
    std.mem.writeInt(u32, log[196..200], 1, .little);
    std.mem.writeInt(u16, log[200..202], 0x139, .little);
    std.mem.writeInt(u16, log[202..204], 0x14F, .little);
    std.mem.writeInt(u32, log[216..220], 0x12, .little);
    std.mem.writeInt(u32, log[220..224], 9, .little);
    std.mem.writeInt(u32, log[224..228], 0x283, .little);
    std.mem.writeInt(u32, log[228..232], 0x39F, .little);
    const t = parseThermal(&log);
    try std.testing.expectEqual(@as(u32, 14), t.warn_temp_minutes);
    try std.testing.expectEqual(@as(u32, 1), t.crit_temp_minutes);
    try std.testing.expectEqual(@as(?i16, 40), t.sensors_c[0]);
    try std.testing.expectEqual(@as(?i16, 62), t.sensors_c[1]);
    try std.testing.expectEqual(@as(?i16, null), t.sensors_c[2]);
    try std.testing.expectEqual(@as(u64, 27), t.throttleCount());
    try std.testing.expectEqual(@as(u32, 643), t.tmt1_secs);
    try std.testing.expectEqual(@as(u64, 64), t.busy_minutes);
    try std.testing.expectEqual(@as(?i16, 40), logTempC(&log));
}

test "parseIdentify: versión NVMe y umbrales térmicos" {
    var id: [4096]u8 = @splat(0);
    std.mem.writeInt(u32, id[80..84], 0x00020000, .little);
    std.mem.writeInt(u16, id[266..268], 355, .little);
    std.mem.writeInt(u16, id[268..270], 358, .little);
    id[525] = 1;
    id[322] = 1;
    const r = parseIdentify(&id);
    try std.testing.expect(r.hctm);
    try std.testing.expectEqual(@as(u16, 2), r.ver_major);
    try std.testing.expectEqual(@as(u8, 0), r.ver_minor);
    try std.testing.expectEqual(@as(?i16, 82), r.wctemp_c);
    try std.testing.expectEqual(@as(?i16, 85), r.cctemp_c);
    try std.testing.expect(r.volatile_cache);
}

test "parseWriteCache: caché activa y vaciado de Windows activo" {
    var out: [32]u8 = @splat(0);
    std.mem.writeInt(u32, out[12..16], 2, .little);
    std.mem.writeInt(u32, out[16..20], 2, .little);
    const w = parseWriteCache(&out);
    try std.testing.expectEqual(@as(?bool, true), w.enabled);
    try std.testing.expect(w.changeable);
    try std.testing.expect(!w.flush_off);
    out[25] = 1;
    std.mem.writeInt(u32, out[12..16], 0, .little);
    const w2 = parseWriteCache(&out);
    try std.testing.expectEqual(@as(?bool, null), w2.enabled);
    try std.testing.expect(w2.flush_off);
}

test "planMode: el modo de Windows 11 solo cuenta en el plan Equilibrado" {
    try std.testing.expectEqualStrings("plan_alto", planMode(SCHEME_HIGH, std.mem.zeroes(GUID)));
    try std.testing.expectEqualStrings("equilibrado", planMode(SCHEME_BALANCED, std.mem.zeroes(GUID)));
    try std.testing.expectEqualStrings("rendimiento", planMode(SCHEME_BALANCED, OVERLAY_PERFORMANCE));
    try std.testing.expectEqualStrings("mejor", planMode(SCHEME_BALANCED, OVERLAY_BETTER_W10));
    try std.testing.expectEqualStrings("desconocido", planMode(SCHEME_BALANCED, null));
    try std.testing.expectEqualStrings("plan_otro", planMode(OVERLAY_EFFICIENCY, null));
}

test "pcieLinkMBs y nextSeq" {
    try std.testing.expectApproxEqAbs(@as(f64, 7876.8), pcieLinkMBs(4, 4).?, 0.1);
    try std.testing.expectEqual(@as(?f64, null), pcieLinkMBs(0, 4));
    const mib: u64 = 1 << 20;
    try std.testing.expectEqual(mib, nextSeq(0, mib, 4 * mib));
    try std.testing.expectEqual(@as(u64, 0), nextSeq(3 * mib, mib, 4 * mib));
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), mbsFrom(1_000_000_000, 10_000_000, 10_000_000), 0.001);
}

test "snapJson produce JSON con celdas vacías como null" {
    var s = Snap{ .phase = .read, .disk = 0, .letter = 'C', .file_bytes = 1 << 30 };
    s.read[0] = .{ .mbs = 7038.49, .iops = 6712, .lat_us = 1190.2 };
    s.temp_now = 51;
    s.throttle_start = 27;
    s.throttle_now = 29;
    var buf: [2048]u8 = undefined;
    const j = snapJson(&buf, &s, "Lectura");
    try std.testing.expect(std.mem.indexOf(u8, j, "\"read\":[{\"mbs\":7038.49") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"throttle_events\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"write\":[null,null,null,null]") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"running\":true") != null);
}

test "todas las declaraciones compilan" {
    std.testing.refAllDecls(@This());
}
