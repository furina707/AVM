// SPDX-License-Identifier: MIT
//! C ABI implementation of `include/avm.h`.
//!
//! This module DEFINES the `avm_*` symbols with `pub export fn ... callconv(.c)`.
//! It imports `abi.zig` ONLY for its type/constant declarations (c.VmConfig,
//! c.OK, ...); it must NOT re-declare the `extern fn` prototypes in this
//! namespace, since that would collide with the exported definitions
//! ("duplicate struct member name"). Consumers link against these symbols via
//! the declarations in `abi.zig` or the C header.
//!
//! String / buffer conventions (shared with the Android JNI shim):
//!   * `avm_vm_build_argv(vm, NULL, &len)`  -> dry run, returns count, sets len.
//!   * `avm_vm_build_argv(vm, buf, &len)`  -> writes `char *` pointers; the
//!     strings are owned by the VM's arena and stay valid until destroy.
//!   * `avm_vm_describe(vm, NULL, 0)` -> bytes needed INCLUDING the NUL.
//!   * `avm_vm_describe(vm, buf, needed)` -> NUL-terminated UTF-8, returns needed.
//!   * `avm_find_qemu(out, len)` copies an absolute path and returns 0/3/9.
//!   * `int`-returning functions return a negative `avm_status` on error.

const std = @import("std");
const c = @import("abi.zig");
const cfgmod = @import("config.zig");
const vm_mod = @import("vm.zig");
const platform = @import("platform.zig");
const qa = @import("qemu_args.zig");
const Vm = vm_mod.Vm;

const VERSION: [*:0]const u8 = "0.1.0";

/// The C API keeps no global state other than this allocator. `page_allocator`
/// is thread-safe and available on every target (including Android without a
/// C runtime), so it is the right default for a library that may be called
/// from arbitrary threads.
const gpa = std.heap.page_allocator;

// ---- opaque handle helpers ------------------------------------------------

fn toOpaque(p: *Vm) *c.Vm {
    return @ptrCast(p);
}

fn fromOpaque(p: ?*c.Vm) ?*Vm {
    const raw = p orelse return null;
    return @ptrCast(@alignCast(raw));
}

/// Duplicate a Zig string into a NUL-terminated C string owned by `a`.
fn dupeZ(a: std.mem.Allocator, s: []const u8) ![*c]u8 {
    const z = try a.dupeSentinel(u8, s, 0);
    return @ptrCast(z.ptr);
}

/// Turn a start() error union into the matching avm_status code.
fn startErrStatus(err: anyerror) c.status {
    return switch (err) {
        error.AlreadyRunning => c.ERR_ALREADY_RUNNING,
        error.QemuNotFound => c.ERR_QEMU_NOT_FOUND,
        error.AccessDenied, error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => c.ERR_SPAWN_FAILED,
        error.OutOfMemory => c.ERR_OUT_OF_MEMORY,
        else => c.ERR_SPAWN_FAILED,
    };
}

// ---- trivial exports ------------------------------------------------------

pub export fn avm_version() callconv(.c) [*:0]const u8 {
    return VERSION;
}

pub export fn avm_status_string(s: c.status) callconv(.c) [*:0]const u8 {
    return switch (s) {
        c.OK => "OK",
        c.ERR_INVALID_ARGUMENT => "invalid argument",
        c.ERR_OUT_OF_MEMORY => "out of memory",
        c.ERR_QEMU_NOT_FOUND => "qemu-system-aarch64 not found (set qemu_path or AVM_QEMU)",
        c.ERR_SPAWN_FAILED => "failed to spawn QEMU",
        c.ERR_ALREADY_RUNNING => "VM is already running",
        c.ERR_NOT_RUNNING => "VM is not running",
        c.ERR_IO => "I/O error",
        c.ERR_UNSUPPORTED => "operation not supported on this platform",
        c.ERR_BUFFER_TOO_SMALL => "buffer too small",
        c.ERR_INTERNAL => "internal error",
        else => "unknown status",
    };
}

/// Free a string previously returned by AVM. Currently every string we return
/// is either static or owned by the VM arena, so this is intentionally a no-op.
pub export fn avm_string_free(s: [*c]u8) callconv(.c) void {
    _ = s;
}

/// Fill a C config with platform defaults. Always call before setting fields.
pub export fn avm_config_init(cfg: *c.VmConfig) callconv(.c) void {
    cfg.* = .{
        .smp = 1,
        .memory_mb = 1024,
        .accel = c.ACCEL_HOST,
        .boot = c.BOOT_AUTO,
        .net = .{ .mode = c.NET_USER },
    };
}

// ---- VM lifecycle ---------------------------------------------------------

pub export fn avm_vm_create(cfg: [*c]const c.VmConfig, out_vm: [*c]?*c.Vm) callconv(.c) c.status {
    if (out_vm == null) return c.ERR_INVALID_ARGUMENT;
    out_vm.* = null;
    if (cfg == null) return c.ERR_INVALID_ARGUMENT;

    // The arena owns the duplicated config (strings + disk array) and the
    // argv built later; it lives exactly as long as the VM.
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const native_cfg = cfgmod.fromC(arena.allocator(), cfg) catch return c.ERR_OUT_OF_MEMORY;

    // `arena` is MOVED into the VM by value. From this point on the VM's
    // destroy() owns its deinit — do not use `arena` again in this scope.
    const vm = Vm.create(gpa, arena, native_cfg) catch return c.ERR_OUT_OF_MEMORY;
    out_vm.* = toOpaque(vm);
    return c.OK;
}

pub export fn avm_vm_destroy(vm: ?*c.Vm) callconv(.c) void {
    if (fromOpaque(vm)) |v| v.destroy();
}

/// Set an environment variable for the QEMU child process. Used on Android to
/// pass LD_LIBRARY_PATH pointing at the app-private lib dir (the bundled QEMU
/// ELFs carry a Termux DT_RUNPATH that LD_LIBRARY_PATH overrides).
pub export fn avm_vm_set_env(vm: ?*c.Vm, key: [*c]const u8, value: [*c]const u8) callconv(.c) c.status {
    const v = fromOpaque(vm) orelse return c.ERR_INVALID_ARGUMENT;
    if (key == null) return c.ERR_INVALID_ARGUMENT;
    const k = std.mem.span(key);
    const val: []const u8 = if (value == null) "" else std.mem.span(value);
    v.setEnv(k, val) catch return c.ERR_OUT_OF_MEMORY;
    return c.OK;
}

/// Redirect QEMU stdout/stderr to a log file created/truncated on start.
pub export fn avm_vm_set_log_file(vm: ?*c.Vm, path: [*c]const u8) callconv(.c) c.status {
    const v = fromOpaque(vm) orelse return c.ERR_INVALID_ARGUMENT;
    if (path == null) return c.ERR_INVALID_ARGUMENT;
    v.setLogFile(std.mem.span(path)) catch return c.ERR_OUT_OF_MEMORY;
    return c.OK;
}

pub export fn avm_vm_start(vm: ?*c.Vm) callconv(.c) c.status {
    const v = fromOpaque(vm) orelse return c.ERR_INVALID_ARGUMENT;
    v.start() catch |err| return startErrStatus(err);
    return c.OK;
}

pub export fn avm_vm_stop(vm: ?*c.Vm, force: c_int) callconv(.c) c.status {
    const v = fromOpaque(vm) orelse return c.ERR_INVALID_ARGUMENT;
    if (!v.isRunning()) return c.ERR_NOT_RUNNING;
    // `Child.kill` is already a hard terminate/reap; `force` is accepted for
    // ABI compatibility with the header (force => SIGKILL semantics).
    _ = force;
    v.stop();
    return c.OK;
}

pub export fn avm_vm_wait(vm: ?*c.Vm, exit_code: [*c]c_int) callconv(.c) c.status {
    const v = fromOpaque(vm) orelse return c.ERR_INVALID_ARGUMENT;
    if (!v.isRunning()) return c.ERR_NOT_RUNNING;
    _ = v.wait();
    if (exit_code != null) exit_code.* = @intCast(v.last_exit_code);
    return c.OK;
}

pub export fn avm_vm_pause(vm: ?*c.Vm) callconv(.c) c.status {
    const v = fromOpaque(vm) orelse return c.ERR_INVALID_ARGUMENT;
    if (!v.isRunning()) return c.ERR_NOT_RUNNING;
    if (!v.pause()) return c.ERR_UNSUPPORTED;
    return c.OK;
}

pub export fn avm_vm_resume(vm: ?*c.Vm) callconv(.c) c.status {
    const v = fromOpaque(vm) orelse return c.ERR_INVALID_ARGUMENT;
    if (!v.isRunning()) return c.ERR_NOT_RUNNING;
    if (!v.resumeVm()) return c.ERR_UNSUPPORTED;
    return c.OK;
}

pub export fn avm_vm_state_get(vm: ?*c.Vm) callconv(.c) c.vm_state {
    const v = fromOpaque(vm) orelse return c.STATE_ERROR;
    return v.stateGet();
}

pub export fn avm_vm_is_running(vm: ?*c.Vm) callconv(.c) c_int {
    const v = fromOpaque(vm) orelse return 0;
    return if (v.isRunning()) 1 else 0;
}

pub export fn avm_vm_pid(vm: ?*c.Vm) callconv(.c) i32 {
    const v = fromOpaque(vm) orelse return 0;
    return v.pidGet();
}

// ---- argv / describe ------------------------------------------------------

/// Build the argv and expose it as C strings. On a dry run (`buf == null`)
/// only the required count is computed. The returned `char *` entries point
/// into the VM arena and MUST NOT be freed by the caller (avm_string_free is
/// a no-op); they stay valid until avm_vm_destroy.
pub export fn avm_vm_build_argv(vm: ?*c.Vm, buf: [*c][*c]u8, out_len: [*c]u32) callconv(.c) c_int {
    const v = fromOpaque(vm) orelse return -@as(c_int, @intCast(c.ERR_INVALID_ARGUMENT));
    const argv = v.buildArgv() catch return -@as(c_int, @intCast(c.ERR_OUT_OF_MEMORY));
    const count: u32 = @intCast(argv.len);
    if (out_len != null) out_len.* = count;
    if (buf == null) return @intCast(count);

    for (argv, 0..) |arg, i| {
        buf[i] = dupeZ(v.arena.allocator(), arg) catch return -@as(c_int, @intCast(c.ERR_OUT_OF_MEMORY));
    }
    return @intCast(count);
}

/// Produce a human-readable description: config summary + joined argv.
/// Dry run (`buf == null`) returns the bytes needed INCLUDING the NUL.
pub export fn avm_vm_describe(vm: ?*c.Vm, buf: [*c]u8, buf_len: u32) callconv(.c) c_int {
    const v = fromOpaque(vm) orelse return -@as(c_int, @intCast(c.ERR_INVALID_ARGUMENT));
    const text = buildDescribe(v) catch return -@as(c_int, @intCast(c.ERR_OUT_OF_MEMORY));
    const needed: u32 = @intCast(text.len + 1); // include trailing NUL
    if (buf == null) return @intCast(needed);
    if (buf_len < needed) return -@as(c_int, @intCast(c.ERR_BUFFER_TOO_SMALL));
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return @intCast(needed);
}

fn buildDescribe(v: *Vm) ![]const u8 {
    const a = v.arena.allocator();
    const argv = try v.buildArgv();
    const line = try qa.joinArgv(a, argv);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.print(a, "AVM {s}\n", .{VERSION});
    try out.print(a, "name: {s}\n", .{v.config.name});
    try out.print(a, "machine: {s}  cpu: {s}  smp: {d}  memory: {d} MiB\n", .{ v.config.machine, v.config.cpu, v.config.smp, v.config.memory_mb });
    try out.print(a, "accel: {d}  boot: {d}  state: {d}  pid: {d}\n", .{ v.config.accel, v.config.boot, v.stateGet(), v.pidGet() });
    try out.appendSlice(a, "argv:\n");
    try out.appendSlice(a, line);
    try out.append(a, '\n');
    return try out.toOwnedSlice(a);
}

// ---- QEMU discovery -------------------------------------------------------

/// Best-effort auto-detection of qemu-system-aarch64. Copies a NUL-terminated
/// path into out_path. Returns 0 (OK), 3 (not found) or 9 (buffer too small).
pub export fn avm_find_qemu(out_path: [*c]u8, out_len: u32) callconv(.c) c.status {
    if (out_path == null) return c.ERR_INVALID_ARGUMENT;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const found = platform.findQemu(gpa, threaded.io()) orelse return c.ERR_QEMU_NOT_FOUND;
    defer gpa.free(found);
    if (out_len < found.len + 1) return c.ERR_BUFFER_TOO_SMALL;
    @memcpy(out_path[0..found.len], found);
    out_path[found.len] = 0;
    return c.OK;
}
