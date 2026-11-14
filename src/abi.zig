//! Hand-written C ABI declarations matching `include/avm.h`.
//!
//! Layouts were verified with `zig translate-c include/avm.h` for both
//! x86_64-windows and aarch64-linux-android: all enums are `c_uint`, all
//! structs are `extern struct`, all C strings are `[*c]const u8`.
//! Keeping this translation in-tree (instead of `@cImport`) makes the library
//! cross-compilable without a C compiler in the loop.

pub const VERSION_MAJOR: c_int = 0;
pub const VERSION_MINOR: c_int = 1;
pub const VERSION_PATCH: c_int = 0;
pub const VERSION_STRING: [*:0]const u8 = "0.1.0";

// ---- enums (C ABI => unsigned int) ---------------------------------------

pub const status = c_uint;
pub const OK: status = 0;
pub const ERR_INVALID_ARGUMENT: status = 1;
pub const ERR_OUT_OF_MEMORY: status = 2;
pub const ERR_QEMU_NOT_FOUND: status = 3;
pub const ERR_SPAWN_FAILED: status = 4;
pub const ERR_ALREADY_RUNNING: status = 5;
pub const ERR_NOT_RUNNING: status = 6;
pub const ERR_IO: status = 7;
pub const ERR_UNSUPPORTED: status = 8;
pub const ERR_BUFFER_TOO_SMALL: status = 9;
pub const ERR_INTERNAL: status = 127;

pub const vm_state = c_uint;
pub const STATE_STOPPED: vm_state = 0;
pub const STATE_STARTING: vm_state = 1;
pub const STATE_RUNNING: vm_state = 2;
pub const STATE_PAUSED: vm_state = 3;
pub const STATE_STOPPING: vm_state = 4;
pub const STATE_ERROR: vm_state = 5;

pub const accel = c_uint;
pub const ACCEL_HOST: accel = 0;
pub const ACCEL_KVM: accel = 1;
pub const ACCEL_HVF: accel = 2;
pub const ACCEL_WHPX: accel = 3;
pub const ACCEL_TCG: accel = 4;

pub const boot = c_uint;
pub const BOOT_AUTO: boot = 0;
pub const BOOT_UEFI: boot = 1;
pub const BOOT_DIRECT_KERNEL: boot = 2;
pub const BOOT_BIOS: boot = 3;

pub const disk_format = c_uint;
pub const DISK_QCOW2: disk_format = 0;
pub const DISK_RAW: disk_format = 1;

pub const disk_iface = c_uint;
pub const DISK_IFACE_VIRTIO: disk_iface = 0;
pub const DISK_IFACE_NVME: disk_iface = 1;

pub const net_mode = c_uint;
pub const NET_NONE: net_mode = 0;
pub const NET_USER: net_mode = 1;
pub const NET_TAP: net_mode = 2;

// ---- structs --------------------------------------------------------------

pub const Disk = extern struct {
    path: [*c]const u8 = null,
    format: disk_format = 0,
    iface: disk_iface = 0,
    read_only: c_int = 0,
};

pub const Net = extern struct {
    mode: net_mode = 0,
    hostfwd: [*c]const u8 = null,
    mac: [*c]const u8 = null,
    ifname: [*c]const u8 = null,
};

pub const Firmware = extern struct {
    bios: [*c]const u8 = null,
    vars: [*c]const u8 = null,
};

pub const VmConfig = extern struct {
    name: [*c]const u8 = null,
    qemu_path: [*c]const u8 = null,
    machine: [*c]const u8 = null,
    cpu: [*c]const u8 = null,
    smp: u32 = 0,
    memory_mb: u64 = 0,
    accel: accel = 0,
    boot: boot = 0,
    kernel: [*c]const u8 = null,
    initrd: [*c]const u8 = null,
    cmdline: [*c]const u8 = null,
    disks: [*c]const Disk = null,
    disk_count: u32 = 0,
    cdrom: [*c]const u8 = null,
    net: Net = .{},
    firmware: Firmware = .{},
    display: [*c]const u8 = null,
    vnc: c_int = 0,
    extra_args: [*c]const u8 = null,
    qmp_socket: [*c]const u8 = null,
};

pub const Vm = opaque {};

// ---- exported C functions -------------------------------------------------

pub extern fn avm_status_string(s: status) [*:0]const u8;
pub extern fn avm_version() [*:0]const u8;
pub extern fn avm_config_init(cfg: *VmConfig) void;
pub extern fn avm_vm_create(cfg: [*c]const VmConfig, out_vm: [*c]?*Vm) status;
pub extern fn avm_vm_destroy(vm: ?*Vm) void;
pub extern fn avm_vm_build_argv(vm: ?*Vm, buf: [*c][*c]u8, out_len: [*c]u32) c_int;
pub extern fn avm_vm_start(vm: ?*Vm) status;
pub extern fn avm_vm_stop(vm: ?*Vm, force: c_int) status;
pub extern fn avm_vm_wait(vm: ?*Vm, exit_code: [*c]c_int) status;
pub extern fn avm_vm_pause(vm: ?*Vm) status;
pub extern fn avm_vm_resume(vm: ?*Vm) status;
pub extern fn avm_vm_state_get(vm: ?*Vm) vm_state;
pub extern fn avm_vm_is_running(vm: ?*Vm) c_int;
pub extern fn avm_vm_pid(vm: ?*Vm) i32;
pub extern fn avm_vm_describe(vm: ?*Vm, buf: [*c]u8, buf_len: u32) c_int;
pub extern fn avm_find_qemu(out_path: [*c]u8, out_len: u32) status;
pub extern fn avm_string_free(s: [*c]u8) void;
