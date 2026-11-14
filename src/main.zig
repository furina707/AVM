// SPDX-License-Identifier: MIT
//! `avm` command line interface.
//!
//! AVM is a control plane around an external `qemu-system-aarch64` binary.
//! This CLI builds/inspects QEMU command lines and can launch a VM in the
//! foreground (waiting for QEMU to exit). It never emulates a CPU by itself.
//!
//! Build:  zig build -Doptimize=ReleaseSafe
//! Run:    ./zig-out/bin/avm --help

const std = @import("std");
const c = @import("abi.zig");
const qa = @import("qemu_args.zig");
const cfgmod = @import("config.zig");
const platform = @import("platform.zig");
const builtin = @import("builtin");

const HELP =
    \\AVM 0.1.0 — AArch64 QEMU control plane (Zig core)
    \\
    \\Usage:
    \\  avm <command> [options]
    \\
    \\Commands:
    \\  version              Print library + host info
    \\  find-qemu            Locate qemu-system-aarch64 (PATH / AVM_QEMU / known dirs)
    \\  build-argv [opts]    Print the QEMU command line that would be launched
    \\  start [opts]         Launch QEMU and wait until it exits
    \\  help                 Show this message
    \\
    \\Options (for build-argv / start):
    \\  --qemu <path>        QEMU binary (default: auto-detect)
    \\  --name <str>         VM name (default: avm-vm)
    \\  --machine <str>      Machine model (default: virt)
    \\  --cpu <str>          CPU model (default: host, or max with TCG)
    \\  --smp <n>            vCPU count (default: 1)
    \\  --memory <n>         RAM in MiB (default: 1024)
    \\  --accel <str>        host|kvm|hvf|whpx|tcg (default: host)
    \\  --boot <str>         auto|uefi|kernel|bios (default: auto)
    \\  --kernel <path>      Direct kernel image
    \\  --initrd <path>      Initial ramdisk
    \\  --cmdline <str>      Guest kernel command line
    \\  --disk <path>        Attach a qcow2 disk (repeatable, virtio-blk)
    \\  --cdrom <path>       Attach ISO install media
    \\  --display <str>      none|gtk|sdl|vnc=:1 (default: none)
    \\  --vnc                Expose VNC on :0
    \\  --bios <path>        UEFI firmware (QEMU_EFI.fd)
    \\  --vars <path>        pflash VARS store
    \\  --qmp <path>         QMP unix socket path
    \\  --extra <str>        Whitespace-split extra QEMU args
    \\  --net <str>          none|user|tap (default: user)
    \\  --hostfwd <str>      e.g. tcp::2222-:22 (user-mode port forward)
    \\
    \\Environment:
    \\  AVM_QEMU             Override the QEMU binary path used by find-qemu
    \\
    \\NOTE: QEMU is NOT bundled. Provide qemu-system-aarch64 yourself.
    \\
;

const Common = struct {
    cfg: cfgmod.Config = .{},
    qemu_override: ?[]const u8 = null,
    disks: std.ArrayList(cfgmod.Disk) = .empty,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("avm: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn parseAccel(s: []const u8) c.accel {
    if (std.ascii.eqlIgnoreCase(s, "host")) return c.ACCEL_HOST;
    if (std.ascii.eqlIgnoreCase(s, "kvm")) return c.ACCEL_KVM;
    if (std.ascii.eqlIgnoreCase(s, "hvf")) return c.ACCEL_HVF;
    if (std.ascii.eqlIgnoreCase(s, "whpx")) return c.ACCEL_WHPX;
    if (std.ascii.eqlIgnoreCase(s, "tcg")) return c.ACCEL_TCG;
    fail("unknown accel '{s}' (use host|kvm|hvf|whpx|tcg)", .{s});
}

fn parseBoot(s: []const u8) c.boot {
    if (std.ascii.eqlIgnoreCase(s, "auto")) return c.BOOT_AUTO;
    if (std.ascii.eqlIgnoreCase(s, "uefi")) return c.BOOT_UEFI;
    if (std.ascii.eqlIgnoreCase(s, "kernel") or std.ascii.eqlIgnoreCase(s, "direct")) return c.BOOT_DIRECT_KERNEL;
    if (std.ascii.eqlIgnoreCase(s, "bios")) return c.BOOT_BIOS;
    fail("unknown boot '{s}' (use auto|uefi|kernel|bios)", .{s});
}

fn parseNet(s: []const u8) c.net_mode {
    if (std.ascii.eqlIgnoreCase(s, "none")) return c.NET_NONE;
    if (std.ascii.eqlIgnoreCase(s, "user")) return c.NET_USER;
    if (std.ascii.eqlIgnoreCase(s, "tap")) return c.NET_TAP;
    fail("unknown net '{s}' (use none|user|tap)", .{s});
}

fn parseU32(s: []const u8, what: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 10) catch fail("invalid {s} '{s}'", .{ what, s });
}

fn parseU64(s: []const u8, what: []const u8) u64 {
    return std.fmt.parseInt(u64, s, 10) catch fail("invalid {s} '{s}'", .{ what, s });
}

fn needValue(args: []const [:0]const u8, i: *usize, flag: []const u8) []const u8 {
    if (i.* + 1 >= args.len) fail("missing value for {s}", .{flag});
    i.* += 1;
    return args[i.*];
}

/// Parse the option tail into a native Config. Disks accumulate in `com.disks`.
fn parseOptions(a: std.mem.Allocator, com: *Common, args: []const [:0]const u8, start: usize) void {
    var i = start;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--qemu")) {
            com.qemu_override = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--name")) {
            com.cfg.name = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--machine")) {
            com.cfg.machine = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--cpu")) {
            com.cfg.cpu = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--smp")) {
            com.cfg.smp = parseU32(needValue(args, &i, arg), "smp");
        } else if (std.mem.eql(u8, arg, "--memory")) {
            com.cfg.memory_mb = parseU64(needValue(args, &i, arg), "memory");
        } else if (std.mem.eql(u8, arg, "--accel")) {
            com.cfg.accel = parseAccel(needValue(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--boot")) {
            com.cfg.boot = parseBoot(needValue(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            com.cfg.kernel = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--initrd")) {
            com.cfg.initrd = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--cmdline")) {
            com.cfg.cmdline = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--disk")) {
            const p = needValue(args, &i, arg);
            com.disks.append(a, .{ .path = p }) catch fail("out of memory", .{});
        } else if (std.mem.eql(u8, arg, "--cdrom")) {
            com.cfg.cdrom = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--display")) {
            com.cfg.display = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--vnc")) {
            com.cfg.vnc = true;
        } else if (std.mem.eql(u8, arg, "--bios")) {
            com.cfg.firmware.bios = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--vars")) {
            com.cfg.firmware.vars = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--qmp")) {
            com.cfg.qmp_socket = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--extra")) {
            com.cfg.extra_args = needValue(args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--net")) {
            com.cfg.net.mode = parseNet(needValue(args, &i, arg));
        } else if (std.mem.eql(u8, arg, "--hostfwd")) {
            com.cfg.net.hostfwd = needValue(args, &i, arg);
        } else {
            fail("unknown option '{s}' (try 'avm help')", .{arg});
        }
    }
    com.cfg.disks = com.disks.items;
}

fn resolveQemu(io: std.Io, a: std.mem.Allocator, override: ?[]const u8) ?[]u8 {
    if (override) |p| {
        if (!platform.isExecutable(io, p)) return null;
        return a.dupe(u8, p) catch null;
    }
    return platform.findQemu(a, io);
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);

    var stdout_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &w.interface;

    if (args.len < 2 or std.mem.eql(u8, args[1], "help") or
        std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))
    {
        try stdout.writeAll(HELP);
        try stdout.flush();
        return;
    }

    const cmd: []const u8 = args[1];

    if (std.mem.eql(u8, cmd, "version")) {
        try stdout.print("AVM {s}\n", .{c.VERSION_STRING});
        try stdout.print("host os: {s}  abi: {s}\n", .{ @tagName(builtin.os.tag), @tagName(builtin.abi) });
        try stdout.print("default accel: {d}  qemu binary: {s}\n", .{ platform.defaultAccel(), platform.qemuBinaryName(builtin.os.tag) });
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, cmd, "find-qemu")) {
        const found = resolveQemu(io, a, null);
        if (found) |p| {
            try stdout.print("{s}\n", .{p});
            try stdout.flush();
        } else {
            fail("qemu-system-aarch64 not found (set AVM_QEMU or use --qemu)", .{});
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "build-argv") or std.mem.eql(u8, cmd, "start")) {
        var com = Common{};
        cfgmod.initDefaults(&com.cfg);
        parseOptions(a, &com, args, 2);

        const qemu = resolveQemu(io, a, com.qemu_override) orelse
            fail("qemu-system-aarch64 not found (set AVM_QEMU or use --qemu)", .{});
        const argv = qa.buildArgv(a, &com.cfg, qemu) catch fail("failed to build argv", .{});
        const line = qa.joinArgv(a, argv) catch fail("failed to join argv", .{});

        if (std.mem.eql(u8, cmd, "build-argv")) {
            try stdout.print("{s}\n", .{line});
            try stdout.flush();
            return;
        }

        // start: spawn in the foreground and wait for QEMU to exit.
        try stdout.print("avm: launching: {s}\n", .{line});
        try stdout.flush();
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            fail("failed to spawn QEMU: {s}", .{@errorName(err)});
        };
        const term = child.wait(io) catch |err| {
            fail("failed to wait for QEMU: {s}", .{@errorName(err)});
        };
        const code: u8 = switch (term) {
            .exited => |x| x,
            else => 1,
        };
        if (code != 0) std.process.exit(code);
        return;
    }

    fail("unknown command '{s}' (try 'avm help')", .{cmd});
}
