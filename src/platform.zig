//! Platform detection and QEMU executable auto-discovery.
//!
//! AVM is a *control plane*: it builds QEMU command lines and manages the
//! QEMU process. The QEMU binary itself is external and is NOT shipped by
//! this repository (see README "QEMU 依赖").

const std = @import("std");
const builtin = @import("builtin");

pub const Host = enum {
    linux,
    android,
    macos,
    windows,
    other,

    pub fn current() Host {
        return switch (builtin.os.tag) {
            .linux => if (builtin.abi == .android) .android else .linux,
            .macos => .macos,
            .windows => .windows,
            else => .other,
        };
    }
};

pub const QemuFlavor = enum { linux_gnu, linux_musl, android, macos, windows, unknown };

/// Return the canonical QEMU binary name for a target OS.
pub fn qemuBinaryName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => "qemu-system-aarch64.exe",
        else => "qemu-system-aarch64",
    };
}

/// Best-effort accelerator choice for the running host.
pub fn defaultAccel() c_uint {
    return switch (Host.current()) {
        .linux, .android => 1, // AVM_ACCEL_KVM
        .macos => 2, // AVM_ACCEL_HVF
        .windows => 3, // AVM_ACCEL_WHPX
        .other => 4, // AVM_ACCEL_TCG
    };
}

/// Default CPU model: "host" when hardware acceleration is available,
/// "max" when falling back to software TCG.
pub fn defaultCpu(accel: c_uint) []const u8 {
    return if (accel == 4) "max" else "host";
}

/// Candidate directories where a bundled/external QEMU may live.
const linux_candidates = [_][]const u8{
    "/usr/bin",
    "/usr/local/bin",
    "/usr/lib/qemu",
    "/opt/qemu/bin",
};
const android_candidates = [_][]const u8{
    "/data/local/tmp",
    "/system/bin",
    "/data/data/com.avm.app/files",
    "/data/user/0/com.avm.app/files",
};
const macos_candidates = [_][]const u8{
    "/opt/homebrew/bin",
    "/usr/local/bin",
};
const windows_candidates = [_][]const u8{
    "C:\\Program Files\\qemu",
    "C:\\qemu",
};

/// Return a list of directories to search for QEMU, in priority order.
pub fn candidateDirs() []const []const u8 {
    return switch (Host.current()) {
        .linux => &linux_candidates,
        .android => &android_candidates,
        .macos => &macos_candidates,
        .windows => &windows_candidates,
        .other => &.{},
    };
}

/// Check whether a path is an executable file. Uses std.Io.Dir.access on
/// `.cwd()` which accepts both relative and absolute paths (the Absolute
/// helper asserts on relative paths, which would panic on PATH entries).
pub fn isExecutable(io: std.Io, path: []const u8) bool {
    std.Io.Dir.access(std.Io.Dir.cwd(), io, path, .{ .execute = true, .read = true }) catch return false;
    return true;
}

/// Look up an environment variable from the process environment block.
/// Returns null when missing. Caller owns returned slice.
///
/// Portability note: `std.process.Environ.Block` differs by target — on
/// Windows it is a `GlobalBlock` (`.global`, reads the PEB), while on POSIX
/// it is a `PosixBlock` (`.slice`). We therefore branch on `builtin` instead
/// of assuming a single representation.
///   * Windows  -> read the PEB block directly (no libc required).
///   * POSIX+libc (Linux CLI, musl/gnu) -> `getenv` via `std.c`.
///   * Freestanding / Android `.so` (no C runtime linked) -> return null and
///     let `findQemu` fall back to configured paths + `candidateDirs()`.
pub fn getEnv(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    if (builtin.os.tag == .windows) {
        const env: std.process.Environ = .{ .block = .global };
        var map = env.createMap(allocator) catch return null;
        defer map.deinit();
        const v = map.get(key) orelse return null;
        return allocator.dupe(u8, v) catch null;
    } else if (builtin.link_libc) {
        const k = allocator.dupeSentinel(u8, key, 0) catch return null;
        defer allocator.free(k);
        const v = std.c.getenv(k) orelse return null;
        return allocator.dupe(u8, std.mem.span(v)) catch null;
    } else {
        return null;
    }
}

/// Find `qemu-system-aarch64` on PATH or in known install directories.
/// Returns an owned absolute/relative path string, or null.
pub fn findQemu(allocator: std.mem.Allocator, io: std.Io) ?[]u8 {
    const name = qemuBinaryName(builtin.os.tag);

    // 1) Explicit override.
    if (getEnv(allocator, "AVM_QEMU")) |p| {
        if (isExecutable(io, p)) return p;
        allocator.free(p);
    }

    // 2) PATH search.
    if (getEnv(allocator, "PATH")) |path| {
        defer allocator.free(path);
        const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
        var it = std.mem.tokenizeScalar(u8, path, sep);
        while (it.next()) |dir| {
            const full = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
            if (isExecutable(io, full)) return full;
            allocator.free(full);
        }
    }

    // 3) Known install directories.
    for (candidateDirs()) |dir| {
        const full = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
        if (isExecutable(io, full)) return full;
        allocator.free(full);
    }

    return null;
}

/// Guess whether a firmware file is UEFI (EDK2) based on its name.
pub fn looksLikeUefi(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "QEMU_EFI") != null or
        std.mem.indexOf(u8, path, "efi") != null or
        std.mem.endsWith(u8, path, ".fd");
}
