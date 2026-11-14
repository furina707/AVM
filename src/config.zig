//! Native (pure Zig) configuration model.
//!
//! The C ABI (`abi.VmConfig`) is converted into this struct at the boundary;
//! all strings here are owned, NUL-free slices allocated from the VM's arena,
//! so the rest of the code never deals with `[*c]` pointers.

const std = @import("std");
const c = @import("abi.zig");

pub const Disk = struct {
    path: []const u8,
    format: c.disk_format = c.DISK_QCOW2,
    iface: c.disk_iface = c.DISK_IFACE_VIRTIO,
    read_only: bool = false,
};

pub const Net = struct {
    mode: c.net_mode = c.NET_USER,
    hostfwd: ?[]const u8 = null,
    mac: ?[]const u8 = null,
    ifname: ?[]const u8 = null,
};

pub const Firmware = struct {
    bios: ?[]const u8 = null,
    vars: ?[]const u8 = null,
};

pub const Config = struct {
    name: []const u8 = "avm-vm",
    qemu_path: ?[]const u8 = null,
    machine: []const u8 = "virt",
    cpu: []const u8 = "host",
    smp: u32 = 1,
    memory_mb: u64 = 1024,
    accel: c.accel = c.ACCEL_HOST,
    boot: c.boot = c.BOOT_AUTO,

    kernel: ?[]const u8 = null,
    initrd: ?[]const u8 = null,
    cmdline: ?[]const u8 = null,

    disks: []const Disk = &.{},
    cdrom: ?[]const u8 = null,
    net: Net = .{},
    firmware: Firmware = .{},

    display: ?[]const u8 = null,
    vnc: bool = false,
    extra_args: ?[]const u8 = null,
    qmp_socket: ?[]const u8 = null,
};

/// Duplicate a C string into an owned slice. NULL **and empty strings** are
/// both treated as "absent": the JNI shim (and many C callers) pass `""` for
/// unused optional fields, and treating that as a real value would emit broken
/// QEMU flags such as `-cpu ""` or `-kernel ""`.
fn dupeOpt(allocator: std.mem.Allocator, p: [*c]const u8) !?[]const u8 {
    if (p == null) return null;
    const s = std.mem.span(p);
    if (s.len == 0) return null;
    return try allocator.dupe(u8, s);
}

/// Apply the two platform-dependent defaults (accelerator and CPU model) to
/// `dst` WITHOUT clobbering any other field the caller may have set. The rest
/// of the fields already carry sensible defaults from their declarations.
pub fn initDefaults(dst: *Config) void {
    dst.accel = @import("platform.zig").defaultAccel();
    dst.cpu = @import("platform.zig").defaultCpu(dst.accel);
}

/// Convert a C `VmConfig` into an owned native `Config`. Every string and the
/// disk array are duplicated from `allocator`.
pub fn fromC(allocator: std.mem.Allocator, src: [*c]const c.VmConfig) !Config {
    const s = &src[0];
    var out = Config{};
    initDefaults(&out);

    if (try dupeOpt(allocator, s.name)) |v| out.name = v;
    if (try dupeOpt(allocator, s.qemu_path)) |v| out.qemu_path = v;
    if (try dupeOpt(allocator, s.machine)) |v| out.machine = v;
    if (try dupeOpt(allocator, s.cpu)) |v| out.cpu = v;

    out.smp = if (s.smp == 0) 1 else s.smp;
    out.memory_mb = if (s.memory_mb == 0) 1024 else s.memory_mb;
    out.accel = s.accel;
    out.boot = s.boot;

    out.kernel = try dupeOpt(allocator, s.kernel);
    out.initrd = try dupeOpt(allocator, s.initrd);
    out.cmdline = try dupeOpt(allocator, s.cmdline);
    out.cdrom = try dupeOpt(allocator, s.cdrom);
    out.display = try dupeOpt(allocator, s.display);
    out.extra_args = try dupeOpt(allocator, s.extra_args);
    out.qmp_socket = try dupeOpt(allocator, s.qmp_socket);
    out.vnc = s.vnc != 0;

    out.net = .{
        .mode = s.net.mode,
        .hostfwd = try dupeOpt(allocator, s.net.hostfwd),
        .mac = try dupeOpt(allocator, s.net.mac),
        .ifname = try dupeOpt(allocator, s.net.ifname),
    };
    out.firmware = .{
        .bios = try dupeOpt(allocator, s.firmware.bios),
        .vars = try dupeOpt(allocator, s.firmware.vars),
    };

    if (s.disk_count > 0 and s.disks != null) {
        const n: usize = @intCast(s.disk_count);
        const arr = try allocator.alloc(Disk, n);
        for (0..n) |i| {
            const d = s.disks[i];
            arr[i] = .{
                .path = try allocator.dupe(u8, std.mem.span(d.path)),
                .format = d.format,
                .iface = d.iface,
                .read_only = d.read_only != 0,
            };
        }
        out.disks = arr;
    }

    return out;
}
