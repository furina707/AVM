/**
 * AVM — public C ABI.
 *
 * AVM is a thin, embeddable control plane around an external QEMU binary.
 * The Zig implementation builds QEMU command lines, launches/stops QEMU,
 * and reports VM state. It does NOT emulate a CPU by itself.
 *
 * Header is C11-clean (no C++ extensions required) and intentionally uses
 * only fixed-width integer types, C strings and opaque handles so that it can
 * be consumed from JNI, C, C++, Python ctypes, etc.
 */
#ifndef AVM_H
#define AVM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(AVM_SHARED)
#  define AVM_API __declspec(dllexport)
#elif defined(__GNUC__) && defined(AVM_SHARED)
#  define AVM_API __attribute__((visibility("default")))
#else
#  define AVM_API
#endif

/* Version triplet. Bump on every ABI change. */
#define AVM_VERSION_MAJOR 0
#define AVM_VERSION_MINOR 1
#define AVM_VERSION_PATCH 0
#define AVM_VERSION_STRING "0.1.0"

/* Status codes returned by every fallible API. */
typedef enum avm_status {
    AVM_OK = 0,
    AVM_ERR_INVALID_ARGUMENT = 1,
    AVM_ERR_OUT_OF_MEMORY = 2,
    AVM_ERR_QEMU_NOT_FOUND = 3,
    AVM_ERR_SPAWN_FAILED = 4,
    AVM_ERR_ALREADY_RUNNING = 5,
    AVM_ERR_NOT_RUNNING = 6,
    AVM_ERR_IO = 7,
    AVM_ERR_UNSUPPORTED = 8,
    AVM_ERR_BUFFER_TOO_SMALL = 9,
    AVM_ERR_INTERNAL = 127
} avm_status;

/* Lifecycle of a single VM instance. */
typedef enum avm_vm_state {
    AVM_STATE_STOPPED = 0,
    AVM_STATE_STARTING = 1,
    AVM_STATE_RUNNING = 2,
    AVM_STATE_PAUSED = 3,
    AVM_STATE_STOPPING = 4,
    AVM_STATE_ERROR = 5
} avm_vm_state;

/* Accelerator selection. HOST = let AVM pick the best available. */
typedef enum avm_accel {
    AVM_ACCEL_HOST = 0, /* KVM on linux, HVF on mac, WHPX on windows */
    AVM_ACCEL_KVM = 1,
    AVM_ACCEL_HVF = 2,
    AVM_ACCEL_WHPX = 3,
    AVM_ACCEL_TCG = 4 /* software emulation, always available */
} avm_accel;

/* Firmware / boot strategy. */
typedef enum avm_boot {
    AVM_BOOT_AUTO = 0,
    AVM_BOOT_UEFI = 1,  /* -bios QEMU_EFI.fd */
    AVM_BOOT_DIRECT_KERNEL = 2, /* -kernel/-initrd/-append */
    AVM_BOOT_BIOS = 3
} avm_boot;

/* Disk attachment. */
typedef enum avm_disk_format {
    AVM_DISK_QCOW2 = 0,
    AVM_DISK_RAW = 1
} avm_disk_format;

typedef enum avm_disk_iface {
    AVM_DISK_IFACE_VIRTIO = 0, /* virtio-blk-pci (fast, recommended) */
    AVM_DISK_IFACE_NVME = 1
} avm_disk_iface;

typedef struct avm_disk {
    const char *path;            /* required, NUL-terminated UTF-8 */
    avm_disk_format format;
    avm_disk_iface iface;
    int read_only;               /* 0 = rw, nonzero = ro */
} avm_disk;

/* Host <-> guest network. */
typedef enum avm_net_mode {
    AVM_NET_NONE = 0,
    AVM_NET_USER = 1,            /* SLIRP user-mode networking */
    AVM_NET_TAP = 2
} avm_net_mode;

typedef struct avm_net {
    avm_net_mode mode;
    const char *hostfwd;         /* e.g. "tcp::2222-:22"; NULL = none */
    const char *mac;             /* optional guest MAC; NULL = auto */
    const char *ifname;          /* TAP interface name; NULL = auto */
} avm_net;

/* Firmware files (UEFI, optional). */
typedef struct avm_firmware {
    const char *bios;            /* QEMU_EFI.fd path; NULL = auto-detect */
    const char *vars;            /* pflash variable store; NULL = none */
} avm_firmware;

/* Full VM description. Strings are copied into the VM during avm_vm_create. */
typedef struct avm_vm_config {
    const char *name;            /* human readable id */
    const char *qemu_path;       /* NULL = auto-detect: qemu-system-aarch64 */
    const char *machine;         /* NULL = "virt" */
    const char *cpu;             /* NULL = "host" (KVM) / "max" (TCG) */
    uint32_t smp;                /* 0 = 1 */
    uint64_t memory_mb;          /* 0 = 1024 */
    avm_accel accel;
    avm_boot boot;

    const char *kernel;          /* direct-kernel boot */
    const char *initrd;
    const char *cmdline;         /* guest kernel cmdline */

    const avm_disk *disks;       /* array or NULL */
    uint32_t disk_count;

    const char *cdrom;           /* ISO / install media; NULL = none */
    avm_net net;
    avm_firmware firmware;

    /* Display: "none", "gtk", "sdl", "cocoa", "vnc=:1", "spice" ... */
    const char *display;
    int vnc;                     /* convenience: expose VNC on :0 */
    const char *extra_args;      /* whitespace-split extra QEMU args */

    /* QMP / monitor control socket. NULL = auto temp path. */
    const char *qmp_socket;
} avm_vm_config;

/* Opaque VM handle. */
typedef struct avm_vm avm_vm;

/* Human readable status text (never NULL, static storage). */
AVM_API const char *avm_status_string(avm_status status);
AVM_API const char *avm_version(void);

/* Fill cfg with platform defaults. Always call before setting fields. */
AVM_API void avm_config_init(avm_vm_config *cfg);

AVM_API avm_status avm_vm_create(const avm_vm_config *cfg, avm_vm **out_vm);
AVM_API void avm_vm_destroy(avm_vm *vm);

/* Set an environment variable for the QEMU child process (e.g.
 * "LD_LIBRARY_PATH"). Must be called before avm_vm_start. Passing an empty
 * value removes the variable. The VM copies both strings. Returns AVM_OK,
 * AVM_ERR_INVALID_ARGUMENT or AVM_ERR_OUT_OF_MEMORY. */
AVM_API avm_status avm_vm_set_env(avm_vm *vm, const char *key, const char *value);

/* Redirect QEMU stdout/stderr to a log file (created/truncated) instead of
 * the parent's descriptors. Useful on Android where inherited stdout is
 * discarded. Call before avm_vm_start. NULL disables redirection. */
AVM_API avm_status avm_vm_set_log_file(avm_vm *vm, const char *path);

/* Returns number of argv entries (excluding NULL) written to buf, or
 * negative avm_status on error. If buf/out_len is NULL the call only
 * computes the required count (dry run). */
AVM_API int avm_vm_build_argv(avm_vm *vm, char **buf, uint32_t *out_len);

/* Launch QEMU (non-blocking). Requires qemu_path to be executable. */
AVM_API avm_status avm_vm_start(avm_vm *vm);
AVM_API avm_status avm_vm_stop(avm_vm *vm, int force);  /* force = SIGKILL */
AVM_API avm_status avm_vm_wait(avm_vm *vm, int *exit_code);
AVM_API avm_status avm_vm_pause(avm_vm *vm);
AVM_API avm_status avm_vm_resume(avm_vm *vm);

AVM_API avm_vm_state avm_vm_state_get(avm_vm *vm);
AVM_API int avm_vm_is_running(avm_vm *vm);
AVM_API int32_t avm_vm_pid(avm_vm *vm);

/* Copy a human-readable description (argv, config summary) into buf.
 * Returns bytes needed on success (may exceed buf_len), or negative
 * avm_status on error. buf==NULL => compute length only. */
AVM_API int avm_vm_describe(avm_vm *vm, char *buf, uint32_t buf_len);

/* Best-effort auto-detection of qemu-system-aarch64 on PATH / known dirs.
 * Returns 0 on success and copies an absolute path into out_path. */
AVM_API avm_status avm_find_qemu(char *out_path, uint32_t out_len);

/* Free a string previously allocated and returned by AVM (future use). */
AVM_API void avm_string_free(char *s);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* AVM_H */
