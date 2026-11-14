// SPDX-License-Identifier: MIT
//! AVM test suite.
//!
//! This is the root of the `zig build test` binary. It forces every core
//! module into the compilation (so their `test` blocks are discovered) and
//! adds integration tests that exercise the exported C ABI end to end.
//! No QEMU binary is required: the tests only build/inspect command lines and
//! manage VM handles, they never launch a real guest.

const std = @import("std");
const c = @import("abi.zig");
const cfgmod = @import("config.zig");
const qa = @import("qemu_args.zig");
const platform = @import("platform.zig");

// Pull the whole module graph in. c_api.zig defines the exported `avm_*`
// symbols that the `extern fn` declarations in abi.zig resolve against at
// link time; importing it here is what makes those definitions part of this
// test binary.
test {
    _ = @import("c_api.zig");
    _ = @import("vm.zig");
    _ = @import("qemu_args.zig");
    _ = @import("config.zig");
    _ = @import("platform.zig");
    _ = @import("abi.zig");
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

test "config defaults are applied without clobbering other fields" {
    var cfg = cfgmod.Config{};
    cfg.name = "kept-name";
    cfg.smp = 8;
    cfgmod.initDefaults(&cfg);

    try std.testing.expectEqualStrings("kept-name", cfg.name);
    try std.testing.expectEqual(@as(u32, 8), cfg.smp);
    try std.testing.expectEqualStrings("virt", cfg.machine);
    try std.testing.expectEqual(@as(u64, 1024), cfg.memory_mb);
    // HOST (0) must be resolved to a concrete accelerator for this platform.
    try std.testing.expect(cfg.accel != c.ACCEL_HOST);
    try std.testing.expect(cfg.cpu.len > 0);
    try std.testing.expect(cfg.disks.len == 0);
}

// ---------------------------------------------------------------------------
// argv builder
// ---------------------------------------------------------------------------

test "buildArgv emits core machine flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = cfgmod.Config{};
    cfgmod.initDefaults(&cfg);
    cfg.accel = c.ACCEL_TCG; // deterministic: forces "-cpu max"

    const argv = try qa.buildArgv(a, &cfg, "qemu-system-aarch64");
    try std.testing.expect(argv.len > 10);
    try std.testing.expectEqualStrings("qemu-system-aarch64", argv[0]);

    const line = try qa.joinArgv(a, argv);
    try std.testing.expect(std.mem.indexOf(u8, line, "-machine virt,accel=tcg,gic-version=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-cpu max") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-smp 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-m 1024M") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-nodefaults") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-no-reboot") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-boot order=c") != null);
}

test "buildArgv emits disks, cdrom, boot order and disabled net" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const disks = [_]cfgmod.Disk{
        .{ .path = "disk.qcow2" },
        .{ .path = "data.raw", .format = c.DISK_RAW, .read_only = true },
    };
    var cfg = cfgmod.Config{};
    cfgmod.initDefaults(&cfg);
    cfg.disks = &disks;
    cfg.cdrom = "install.iso";
    cfg.net.mode = c.NET_NONE;

    const argv = try qa.buildArgv(a, &cfg, "qemu");
    const line = try qa.joinArgv(a, argv);
    try std.testing.expect(std.mem.indexOf(u8, line, "file=disk.qcow2,format=qcow2,if=virtio,cache=none") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "file=data.raw,format=raw,if=virtio,cache=none,readonly=on") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-cdrom install.iso") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-boot order=dc") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-nic none") != null);
}

test "buildArgv direct kernel boot suppresses -boot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = cfgmod.Config{};
    cfgmod.initDefaults(&cfg);
    cfg.kernel = "Image";
    cfg.initrd = "initrd.gz";
    cfg.cmdline = "console=ttyAMA0 root=/dev/vda";

    const argv = try qa.buildArgv(a, &cfg, "qemu");
    const line = try qa.joinArgv(a, argv);
    try std.testing.expect(std.mem.indexOf(u8, line, "-kernel Image") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-initrd initrd.gz") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "console=ttyAMA0 root=/dev/vda") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-boot order=") == null);
}

test "buildArgv passes through extra args and user-mode port forward" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var cfg = cfgmod.Config{};
    cfgmod.initDefaults(&cfg);
    cfg.extra_args = "-serial stdio -d guest_errors";
    cfg.net.hostfwd = "tcp::2222-:22";
    cfg.display = "gtk";

    const argv = try qa.buildArgv(a, &cfg, "qemu");
    const line = try qa.joinArgv(a, argv);
    try std.testing.expect(std.mem.indexOf(u8, line, "user,id=net0,hostfwd=tcp::2222-:22") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-serial stdio -d guest_errors") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "-display gtk") != null);
    // extra_args are appended before the common peripherals
    const serial = std.mem.indexOf(u8, line, "-serial stdio").?;
    const gpu = std.mem.indexOf(u8, line, "virtio-gpu-pci").?;
    try std.testing.expect(serial < gpu);
}

test "joinArgv quotes arguments containing spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const line = try qa.joinArgv(arena.allocator(), &.{ "qemu", "-append", "root=/dev/vda console=tty0", "plain" });
    try std.testing.expectEqualStrings("qemu -append \"root=/dev/vda console=tty0\" plain", line);
}

// ---------------------------------------------------------------------------
// C config conversion
// ---------------------------------------------------------------------------

test "fromC copies fields, applies zero-value defaults and ignores empty strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const disks = [_]c.Disk{.{ .path = "disk.qcow2", .format = c.DISK_QCOW2, .iface = c.DISK_IFACE_VIRTIO }};
    var cc = c.VmConfig{};
    cc.name = "vm1";
    cc.cpu = ""; // empty must be treated as absent
    cc.kernel = "";
    cc.smp = 0; // 0 => default 1
    cc.memory_mb = 0; // 0 => default 1024
    cc.disks = &disks;
    cc.disk_count = 1;
    cc.net.mode = c.NET_USER;

    const cfg = try cfgmod.fromC(a, &cc);
    try std.testing.expectEqualStrings("vm1", cfg.name);
    try std.testing.expectEqual(@as(u32, 1), cfg.smp);
    try std.testing.expectEqual(@as(u64, 1024), cfg.memory_mb);
    try std.testing.expect(cfg.kernel == null);
    try std.testing.expect(cfg.initrd == null);
    try std.testing.expect(cfg.cpu.len > 0); // platform default, not ""
    try std.testing.expectEqual(@as(usize, 1), cfg.disks.len);
    try std.testing.expectEqualStrings("disk.qcow2", cfg.disks[0].path);
}

// ---------------------------------------------------------------------------
// Platform helpers
// ---------------------------------------------------------------------------

test "platform helpers return sane values" {
    try std.testing.expect(platform.qemuBinaryName(.linux).len > 0);
    try std.testing.expect(platform.qemuBinaryName(.windows).len > 0);
    try std.testing.expect(platform.defaultAccel() != 0);
    try std.testing.expect(platform.defaultCpu(c.ACCEL_TCG).len > 0);
    try std.testing.expect(platform.candidateDirs().len >= 0);
    try std.testing.expect(platform.looksLikeUefi("QEMU_EFI.fd"));
    try std.testing.expect(!platform.looksLikeUefi("vmlinuz"));
}

// ---------------------------------------------------------------------------
// C ABI integration (extern declarations in abi.zig -> exports in c_api.zig)
// ---------------------------------------------------------------------------

test "C ABI status strings, version and config init" {
    try std.testing.expectEqualStrings("0.1.0", std.mem.span(c.avm_version()));
    try std.testing.expectEqualStrings("OK", std.mem.span(c.avm_status_string(c.OK)));
    const s = std.mem.span(c.avm_status_string(c.ERR_QEMU_NOT_FOUND));
    try std.testing.expect(s.len > 0);
    try std.testing.expect(!std.mem.eql(u8, s, "unknown status"));

    var cc: c.VmConfig = undefined;
    c.avm_config_init(&cc);
    try std.testing.expectEqual(@as(u32, 1), cc.smp);
    try std.testing.expectEqual(@as(u64, 1024), cc.memory_mb);
    try std.testing.expectEqual(c.ACCEL_HOST, cc.accel);
    try std.testing.expectEqual(c.BOOT_AUTO, cc.boot);
    try std.testing.expectEqual(c.NET_USER, cc.net.mode);
}

test "C ABI create / build_argv / describe / state / destroy round trip" {
    const a = std.testing.allocator;

    const disks = [_]c.Disk{.{ .path = "disk.qcow2" }};
    var cc: c.VmConfig = undefined;
    c.avm_config_init(&cc);
    cc.name = "test-vm";
    cc.disks = &disks;
    cc.disk_count = 1;
    cc.cdrom = "install.iso";

    var vm: ?*c.Vm = null;
    try std.testing.expectEqual(c.OK, c.avm_vm_create(&cc, &vm));
    try std.testing.expect(vm != null);
    defer c.avm_vm_destroy(vm);

    // build_argv: dry run then real call; the count must agree.
    var len: u32 = 0;
    const n = c.avm_vm_build_argv(vm, null, &len);
    try std.testing.expect(n > 10);
    try std.testing.expectEqual(n, @as(c_int, @intCast(len)));

    const buf = try a.alloc([*c]u8, len);
    defer a.free(buf);
    const n2 = c.avm_vm_build_argv(vm, @ptrCast(buf.ptr), &len);
    try std.testing.expectEqual(n, n2);
    try std.testing.expectEqualStrings("qemu-system-aarch64", std.mem.span(buf[0])[0.."qemu-system-aarch64".len]);
    // Every entry must be NUL-terminated and non-empty.
    for (buf[0..@intCast(n2)]) |p| {
        try std.testing.expect(std.mem.span(p).len > 0);
    }

    // describe: dry run returns bytes INCLUDING NUL; real call NUL-terminates.
    const need = c.avm_vm_describe(vm, null, 0);
    try std.testing.expect(need > 10);
    const dbuf = try a.alloc(u8, @intCast(need));
    defer a.free(dbuf);
    const got = c.avm_vm_describe(vm, @ptrCast(dbuf.ptr), @intCast(need));
    try std.testing.expectEqual(need, got);
    try std.testing.expectEqual(@as(u8, 0), dbuf[@intCast(need - 1)]);
    const text = std.mem.sliceTo(dbuf, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "name: test-vm") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "argv:") != null);
    // A too-small buffer must be rejected instead of overflowing.
    try std.testing.expectEqual(
        -@as(c_int, @intCast(c.ERR_BUFFER_TOO_SMALL)),
        c.avm_vm_describe(vm, @ptrCast(dbuf.ptr), 4),
    );

    // A freshly created VM is stopped and has no PID.
    try std.testing.expectEqual(c.STATE_STOPPED, c.avm_vm_state_get(vm));
    try std.testing.expectEqual(@as(c_int, 0), c.avm_vm_is_running(vm));
    try std.testing.expectEqual(@as(i32, 0), c.avm_vm_pid(vm));
}

test "C ABI rejects NULL handles and reports find_qemu status" {
    try std.testing.expectEqual(c.ERR_INVALID_ARGUMENT, c.avm_vm_start(null));
    try std.testing.expectEqual(c.ERR_INVALID_ARGUMENT, c.avm_vm_stop(null, 0));
    try std.testing.expectEqual(c.STATE_ERROR, c.avm_vm_state_get(null));
    try std.testing.expectEqual(@as(c_int, 0), c.avm_vm_is_running(null));
    try std.testing.expectEqual(@as(i32, 0), c.avm_vm_pid(null));
    try std.testing.expect(c.avm_vm_build_argv(null, null, null) < 0);
    try std.testing.expect(c.avm_vm_describe(null, null, 0) < 0);

    var path: [4096]u8 = undefined;
    const st = c.avm_find_qemu(&path, path.len);
    // Either QEMU is installed (OK) or it is not (NOT_FOUND); never a crash.
    try std.testing.expect(st == c.OK or st == c.ERR_QEMU_NOT_FOUND or st == c.ERR_BUFFER_TOO_SMALL);
    if (st == c.OK) try std.testing.expect(std.mem.sliceTo(&path, 0).len > 0);

    // avm_string_free is a documented no-op.
    c.avm_string_free(null);
}
