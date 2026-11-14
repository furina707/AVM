// SPDX-License-Identifier: MIT
//! AVM build graph (Zig 0.17).
//!
//! Artifacts (installed into zig-out/ by default):
//!   * bin/avm            — command line interface
//!   * lib/libavm_static.a — static C ABI library (avm_static.lib on Windows)
//!   * lib/libavm.so      — shared C ABI library (dll on Windows, dylib on macOS)
//!   * include/avm.h      — public C header
//!
//! Cross-compilation relies on the standard -Dtarget option:
//!   zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe   # arm64 Linux
//!   zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe # Android .so
//!
//! Steps:
//!   zig build            — build + install everything
//!   zig build test       — run the unit/integration test suite
//!   zig build run -- ... — build and run the CLI with passthrough args
//!   zig build android    — cross-compile arm64 libavm.so for the Compose app
//!                          and copy it into android/app/src/main/jniLibs/

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `link_libc` must be chosen per target: Zig cannot provide libc for the
    // Android target, and Windows reads its environment from the PEB instead.
    // Linux (gnu/musl) and macOS link libc so `getEnv` can use `getenv` for
    // PATH-based QEMU discovery; Android falls back to known directories.
    const t = target.result;
    const want_libc: bool = switch (t.os.tag) {
        .linux => t.abi != .android,
        .macos => true,
        else => false,
    };

    // ---- C ABI libraries --------------------------------------------------
    // Each Compile needs its own root Module. c_api.zig pulls in the rest of
    // the core (abi/config/platform/qemu_args/vm) through relative imports.

    // NOTE: the static library is named `avm_static` rather than `avm` on
    // purpose. On Windows a shared library produces an *import* library named
    // `avm.lib`, which would collide with a same-named static `avm.lib` in
    // zig-out/lib (last writer wins). POSIX keeps libavm_static.a + libavm.so.
    const static_lib = b.addLibrary(.{
        .name = "avm_static",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = want_libc,
        }),
    });

    const shared_lib = b.addLibrary(.{
        .name = "avm",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = want_libc,
            .pic = true,
        }),
    });

    b.installArtifact(static_lib);
    b.installArtifact(shared_lib);

    // ---- public header ----------------------------------------------------
    const install_header = b.addInstallFileWithDir(
        b.path("include/avm.h"),
        .header,
        "avm.h",
    );
    b.getInstallStep().dependOn(&install_header.step);

    // ---- CLI --------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "avm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = want_libc,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Build and run the avm CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // ---- tests ------------------------------------------------------------
    // src/tests.zig explicitly imports every module so that all `test` blocks
    // (and the C ABI round-trip integration test) are discovered and linked.
    const test_step = b.step("test", "Run unit + C ABI integration tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = want_libc,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // ---- Android convenience step -----------------------------------------
    // Builds a dedicated arm64-v8a shared library (always, regardless of the
    // host target) and copies it into the Compose app's jniLibs directory.
    // `UpdateSourceFiles` is the intended API for writing a generated artifact
    // back into the source tree; it is opt-in (only runs for `zig build android`).
    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });
    const android_lib = b.addLibrary(.{
        .name = "avm",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = android_target,
            .optimize = optimize,
            .link_libc = false, // Zig cannot provide libc for the Android target
            .pic = true,
        }),
    });
    const android_step = b.step("android", "Build arm64-v8a libavm.so into the Android app");
    const update = b.addUpdateSourceFiles();
    update.addCopyFileToSource(
        android_lib.getEmittedBin(),
        "android/app/src/main/jniLibs/arm64-v8a/libavm.so",
    );
    android_step.dependOn(&update.step);
}
