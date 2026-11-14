//! QEMU command-line builder for AArch64 `virt` machines.
//!
//! Produces a `[]const []const u8` argv suitable for `std.process.spawn`.
//! Everything is allocated from a caller-owned arena so the resulting argv
//! stays valid for the lifetime of that arena.

const std = @import("std");
const c = @import("abi.zig");
const Config = @import("config.zig").Config;
const Disk = @import("config.zig").Disk;
const platform = @import("platform.zig");

fn push(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.append(allocator, s);
}

fn fmt(allocator: std.mem.Allocator, comptime f: []const u8, args: anytype) ![]const u8 {
    return try std.fmt.allocPrint(allocator, f, args);
}

fn accelName(a: c.accel) []const u8 {
    return switch (a) {
        c.ACCEL_KVM => "kvm",
        c.ACCEL_HVF => "hvf",
        c.ACCEL_WHPX => "whpx",
        c.ACCEL_TCG => "tcg",
        else => "tcg", // HOST resolves below
    };
}

fn resolvedAccel(cfg: *const Config) c.accel {
    if (cfg.accel == c.ACCEL_HOST) return platform.defaultAccel();
    return cfg.accel;
}

fn diskFormatName(f: c.disk_format) []const u8 {
    return if (f == c.DISK_RAW) "raw" else "qcow2";
}

/// Build the netdev string (without the leading `-netdev`), e.g.
/// `user,id=net0,hostfwd=tcp::2222-:22`.
fn netdevStr(allocator: std.mem.Allocator, cfg: *const Config) !?[]const u8 {
    const net = cfg.net;
    return switch (net.mode) {
        c.NET_NONE => null,
        c.NET_USER => blk: {
            if (net.hostfwd) |hf| {
                break :blk try fmt(allocator, "user,id=net0,hostfwd={s}", .{hf});
            }
            break :blk try allocator.dupe(u8, "user,id=net0");
        },
        c.NET_TAP => blk: {
            if (net.ifname) |ifn| {
                break :blk try fmt(allocator, "tap,id=net0,ifname={s},script=no,downscript=no", .{ifn});
            }
            break :blk try allocator.dupe(u8, "tap,id=net0,script=no,downscript=no");
        },
        else => null,
    };
}

/// Build the guest NIC device string (without `-device`).
fn netDeviceStr(allocator: std.mem.Allocator, cfg: *const Config) ![]const u8 {
    if (cfg.net.mac) |mac| {
        return try fmt(allocator, "virtio-net-pci,netdev=net0,mac={s}", .{mac});
    }
    return try allocator.dupe(u8, "virtio-net-pci,netdev=net0");
}

/// Build one `-drive` argument for a disk.
fn driveArg(allocator: std.mem.Allocator, d: Disk) ![]const u8 {
    const ro = if (d.read_only) ",readonly=on" else "";
    // virtio: self-contained `-drive if=virtio`. nvme: expose a `if=none`
    // block node with a stable id and attach it via a separate `-device`.
    if (d.iface == c.DISK_IFACE_VIRTIO) {
        return try fmt(allocator, "file={s},format={s},if=virtio,cache=none{s}", .{ d.path, diskFormatName(d.format), ro });
    }
    return try fmt(allocator, "file={s},format={s},if=none,id=nvme0{s}", .{ d.path, diskFormatName(d.format), ro });
}

/// Build a full argv. `qemu` is the resolved QEMU executable path.
/// The returned slice and every string inside are allocated from `allocator`.
pub fn buildArgv(allocator: std.mem.Allocator, cfg: *const Config, qemu: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    try push(&list, allocator, qemu);

    // --- machine / accel / cpu / memory ----------------------------------
    const a = resolvedAccel(cfg);
    const accel_str = accelName(a);
    try push(&list, allocator, "-machine");
    try push(&list, allocator, try fmt(allocator, "{s},accel={s},gic-version=3", .{ cfg.machine, accel_str }));
    try push(&list, allocator, "-cpu");
    const cpu = if (std.mem.eql(u8, cfg.cpu, "host") and a == c.ACCEL_TCG)
        "max"
    else
        cfg.cpu;
    try push(&list, allocator, cpu);
    try push(&list, allocator, "-smp");
    try push(&list, allocator, try fmt(allocator, "{d}", .{cfg.smp}));
    try push(&list, allocator, "-m");
    try push(&list, allocator, try fmt(allocator, "{d}M", .{cfg.memory_mb}));

    // --- firmware / boot --------------------------------------------------
    // BOOT_UEFI alone adds no flag; it only has meaning together with an
    // explicit `-bios` firmware path (supplied via cfg.firmware.bios).
    if (cfg.firmware.bios) |bios| {
        try push(&list, allocator, "-bios");
        try push(&list, allocator, bios);
    }
    if (cfg.firmware.vars) |vars| {
        try push(&list, allocator, "-drive");
        try push(&list, allocator, try fmt(allocator, "file={s},if=pflash,format=raw,unit=1", .{vars}));
    }

    const direct_kernel = cfg.kernel != null;
    if (direct_kernel) {
        try push(&list, allocator, "-kernel");
        try push(&list, allocator, cfg.kernel.?);
        if (cfg.initrd) |initrd| {
            try push(&list, allocator, "-initrd");
            try push(&list, allocator, initrd);
        }
        if (cfg.cmdline) |cmd| {
            try push(&list, allocator, "-append");
            try push(&list, allocator, cmd);
        }
    } else {
        // BOOT_AUTO with no explicit firmware still boots via QEMU's built-in
        // boot ROM / -bios when provided; add boot order for CD installs.
        try push(&list, allocator, "-boot");
        try push(&list, allocator, if (cfg.cdrom != null) "order=dc" else "order=c");
    }

    // --- disks ------------------------------------------------------------
    for (cfg.disks) |d| {
        try push(&list, allocator, "-drive");
        try push(&list, allocator, try driveArg(allocator, d));
        if (d.iface == c.DISK_IFACE_NVME) {
            try push(&list, allocator, "-device");
            try push(&list, allocator, "nvme,drive=nvme0,serial=AVM0001");
        }
    }
    if (cfg.cdrom) |iso| {
        try push(&list, allocator, "-cdrom");
        try push(&list, allocator, iso);
    }

    // --- network ----------------------------------------------------------
    if (try netdevStr(allocator, cfg)) |nd| {
        try push(&list, allocator, "-netdev");
        try push(&list, allocator, nd);
        try push(&list, allocator, "-device");
        try push(&list, allocator, try netDeviceStr(allocator, cfg));
    } else {
        try push(&list, allocator, "-nic");
        try push(&list, allocator, "none");
    }

    // --- display ----------------------------------------------------------
    if (cfg.display) |disp| {
        try push(&list, allocator, "-display");
        try push(&list, allocator, disp);
    } else if (cfg.vnc) {
        try push(&list, allocator, "-vnc");
        try push(&list, allocator, ":0");
    } else {
        try push(&list, allocator, "-display");
        try push(&list, allocator, "none");
    }

    // --- QMP / monitor ----------------------------------------------------
    if (cfg.qmp_socket) |sock| {
        try push(&list, allocator, "-qmp");
        try push(&list, allocator, try fmt(allocator, "unix:{s},server,nowait", .{sock}));
    }

    // --- extra args (whitespace split) ------------------------------------
    if (cfg.extra_args) |extra| {
        var it = std.mem.tokenizeAny(u8, extra, " \t\r\n");
        while (it.next()) |tok| try push(&list, allocator, tok);
    }

    // --- common aarch64 virt peripherals ---------------------------------
    try push(&list, allocator, "-device");
    try push(&list, allocator, "virtio-gpu-pci");
    try push(&list, allocator, "-device");
    try push(&list, allocator, "qemu-xhci");
    try push(&list, allocator, "-device");
    try push(&list, allocator, "usb-kbd");
    try push(&list, allocator, "-device");
    try push(&list, allocator, "usb-tablet");
    try push(&list, allocator, "-rtc");
    try push(&list, allocator, "base=utc");
    try push(&list, allocator, "-nodefaults");
    try push(&list, allocator, "-no-reboot");

    return try list.toOwnedSlice(allocator);
}

/// Join an argv into a single human-readable command line (for describe/CLI).
pub fn joinArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, i| {
        if (i != 0) try out.append(allocator, ' ');
        const need_quotes = std.mem.indexOfAny(u8, arg, " \t\"") != null;
        if (need_quotes) try out.append(allocator, '"');
        try out.appendSlice(allocator, arg);
        if (need_quotes) try out.append(allocator, '"');
    }
    return try out.toOwnedSlice(allocator);
}
