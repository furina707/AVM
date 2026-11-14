// SPDX-License-Identifier: MIT
//! VM lifecycle and state machine.
//!
//! A `Vm` owns:
//!   - an `ArenaAllocator` holding its owned config (all strings/arrays),
//!   - a persistent `std.Io.Threaded` instance used for spawn/wait/kill,
//!   - a single `std.process.Child` for the running QEMU process.
//!
//! The `Threaded` instance must outlive the child and be the SAME instance
//! used for spawn + wait + kill (its vtable/userdata carry the OS handles).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("abi.zig");
const platform = @import("platform.zig");
const cfgmod = @import("config.zig");
const qa = @import("qemu_args.zig");
const Config = cfgmod.Config;

pub const Vm = struct {
    /// Stable allocator for the VM object itself (used by create/destroy).
    backing_allocator: std.mem.Allocator,
    /// Owns the config's strings, disks array and the built argv.
    arena: std.heap.ArenaAllocator,
    /// The resolved, owned configuration.
    config: Config,
    /// Threaded Io instance kept alive for the whole VM lifetime.
    threaded: std.Io.Threaded,
    /// The child QEMU process, valid only while state is running/paused.
    child: ?std.process.Child = null,
    /// Current lifecycle state (`avm_vm_state` is `c_uint` in the C ABI).
    state: c_uint = c.STATE_STOPPED,
    /// PID of the running QEMU process (0 when not running).
    pid: i32 = 0,
    /// Exit code of the last `wait()`, exposed through `avm_vm_wait`.
    last_exit_code: u8 = 0,
    /// Environment passed to the QEMU child (LD_LIBRARY_PATH etc.). Owned by
    /// the VM's arena; never used on Windows where SpawnOptions uses a block.
    envmap: ?std.process.Environ.Map = null,
    /// Optional log file whose handle is inherited by QEMU stdout/stderr.
    log_path: ?[]const u8 = null,
    log_file: ?std.Io.File = null,

    /// Create a VM from a native owned Config, taking ownership of its arena.
    /// `arena` is stored by value; its backing allocator is used for destroy.
    pub fn create(backing: std.mem.Allocator, arena: std.heap.ArenaAllocator, config: Config) !*Vm {
        const self = try backing.create(Vm);
        self.* = .{
            .backing_allocator = backing,
            .arena = arena,
            .config = config,
            .threaded = .init(backing, .{}),
        };
        return self;
    }

    pub fn destroy(self: *Vm) void {
        // If still running, terminate QEMU before tearing everything down.
        if (self.child != null) {
            self.stop();
        }
        if (self.log_file) |f| {
            f.close(self.io());
            self.log_file = null;
        }
        if (self.envmap) |*m| m.deinit();
        self.threaded.deinit();
        self.arena.deinit();
        self.backing_allocator.destroy(self);
    }

    fn io(self: *Vm) std.Io {
        return self.threaded.io();
    }

    /// Resolve the QEMU binary path to use, storing an owned copy in config.
    /// `platform.findQemu` returns an optional (`?[]u8`), NOT an error union,
    /// so there is deliberately no `try` here.
    pub fn resolveQemu(self: *Vm) void {
        if (self.config.qemu_path) |p| {
            if (p.len > 0) return; // caller supplied an explicit path
        }
        if (platform.findQemu(self.arena.allocator(), self.io())) |f| {
            self.config.qemu_path = f; // owned by the VM's arena
        }
    }

    /// Build the QEMU argv from the current config. Returns an owned slice
    /// living in the VM's arena.
    pub fn buildArgv(self: *Vm) ![]const []const u8 {
        const qemu = self.config.qemu_path orelse platform.qemuBinaryName(builtin.os.tag);
        return try qa.buildArgv(self.arena.allocator(), &self.config, qemu);
    }

    /// Set an environment variable for the QEMU child. Strings are copied
    /// into the VM arena. An empty value removes the key.
    pub fn setEnv(self: *Vm, key: []const u8, value: []const u8) !void {
        const a = self.arena.allocator();
        if (self.envmap == null) {
            self.envmap = std.process.Environ.Map.init(a);
        }
        var map = &self.envmap.?;
        if (value.len == 0) {
            _ = map.swapRemove(key);
            return;
        }
        const k = try a.dupe(u8, key);
        const v = try a.dupe(u8, value);
        try map.put(k, v);
    }

    /// Redirect QEMU stdout/stderr into a log file (created/truncated on
    /// start). The handle stays open in the parent until stop/wait.
    pub fn setLogFile(self: *Vm, path: []const u8) !void {
        if (self.log_file) |f| {
            f.close(self.io());
            self.log_file = null;
        }
        self.log_path = try self.arena.allocator().dupe(u8, path);
    }

    /// Start QEMU.
    pub fn start(self: *Vm) !void {
        if (self.child != null) return error.AlreadyRunning;

        self.resolveQemu();
        const qemu = self.config.qemu_path orelse return error.QemuNotFound;
        if (!platform.isExecutable(self.io(), qemu)) {
            return error.QemuNotFound;
        }

        const argv = try self.buildArgv();

        // Open the log file (if configured) and pass its handle to the child.
        var stdout_mode: std.process.SpawnOptions.StdIo = .inherit;
        var stderr_mode: std.process.SpawnOptions.StdIo = .inherit;
        if (self.log_path) |p| {
            const f = try std.Io.Dir.createFile(
                std.Io.Dir.cwd(),
                self.io(),
                p,
                .{ .truncate = true, .read = false },
            );
            self.log_file = f;
            stdout_mode = .{ .file = f };
            stderr_mode = .{ .file = f };
        }

        const child = std.process.spawn(self.io(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = stdout_mode,
            .stderr = stderr_mode,
            // Explicit env map (LD_LIBRARY_PATH) instead of the empty default.
            .environ_map = if (self.envmap) |*m| m else null,
        }) catch |err| {
            self.state = c.STATE_ERROR;
            if (self.log_file) |f| {
                f.close(self.io());
                self.log_file = null;
            }
            return err;
        };

        self.child = child;
        self.pid = idToPid(child.id);
        self.state = c.STATE_RUNNING;
    }

    /// Stop QEMU forcibly (kill + reap). Idempotent.
    pub fn stop(self: *Vm) void {
        if (self.child) |*child| {
            child.kill(self.io());
            self.child = null;
        }
        self.pid = 0;
        if (self.log_file) |f| {
            f.close(self.io());
            self.log_file = null;
        }
        if (self.state != c.STATE_ERROR) self.state = c.STATE_STOPPED;
    }

    /// Block until QEMU exits, then record the termination state.
    pub fn wait(self: *Vm) c_uint {
        if (self.child) |*child| {
            const term = child.wait(self.io()) catch {
                self.child = null;
                self.pid = 0;
                self.state = c.STATE_STOPPED;
                return c.STATE_STOPPED;
            };
            self.child = null;
            self.pid = 0;
            if (self.log_file) |f| {
                f.close(self.io());
                self.log_file = null;
            }
            self.last_exit_code = switch (term) {
                .exited => |code| code,
                else => 1,
            };
            self.state = if (self.last_exit_code == 0) c.STATE_STOPPED else c.STATE_ERROR;
            return self.state;
        }
        return self.state;
    }

    /// Pause QEMU (SIGSTOP on POSIX). No-op on Windows.
    pub fn pause(self: *Vm) bool {
        if (self.child == null or self.pid == 0 or builtin.os.tag == .windows) return false;
        std.posix.kill(self.pid, std.posix.SIG.STOP) catch return false;
        self.state = c.STATE_PAUSED;
        return true;
    }

    /// Resume QEMU (SIGCONT on POSIX). No-op on Windows.
    pub fn resumeVm(self: *Vm) bool {
        if (self.child == null or self.pid == 0 or builtin.os.tag == .windows) return false;
        std.posix.kill(self.pid, std.posix.SIG.CONT) catch return false;
        self.state = c.STATE_RUNNING;
        return true;
    }

    pub fn stateGet(self: *Vm) c_uint {
        return self.state;
    }

    pub fn isRunning(self: *Vm) bool {
        return self.child != null and (self.state == c.STATE_RUNNING or self.state == c.STATE_PAUSED);
    }

    pub fn pidGet(self: *Vm) i32 {
        return self.pid;
    }
};

/// Convert a `Child.Id` (pid_t on POSIX, HANDLE on Windows) to an i32 PID.
fn idToPid(id: ?std.process.Child.Id) i32 {
    if (builtin.os.tag == .windows) return 0;
    const pid = id orelse return 0;
    // pid_t is i32 on Linux/Android; intCast keeps the conversion explicit.
    return @intCast(pid);
}

test "state machine starts stopped" {
    const arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var config = Config{};
    cfgmod.initDefaults(&config);
    // `arena` is moved into the VM by value; `vm.destroy()` owns its deinit
    // from here on, so there must be no `defer arena.deinit()` in this scope.
    const vm = try Vm.create(std.testing.allocator, arena, config);
    defer vm.destroy();
    try std.testing.expectEqual(c.STATE_STOPPED, vm.stateGet());
    try std.testing.expect(!vm.isRunning());
    try std.testing.expectEqual(@as(i32, 0), vm.pidGet());
}
