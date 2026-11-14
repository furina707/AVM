package com.avm.app

/**
 * Thin Kotlin facade over the C JNI shim (libavm_jni.so).
 * The shim links the prebuilt Zig core library libavm.so.
 */
object AvmBridge {

    init {
        System.loadLibrary("avm_jni")
    }

    // ---- Status codes (avm_status) ----
    const val AVM_OK = 0
    const val AVM_ERR_INVALID_ARGUMENT = 1
    const val AVM_ERR_OUT_OF_MEMORY = 2
    const val AVM_ERR_QEMU_NOT_FOUND = 3
    const val AVM_ERR_SPAWN_FAILED = 4
    const val AVM_ERR_ALREADY_RUNNING = 5
    const val AVM_ERR_NOT_RUNNING = 6
    const val AVM_ERR_IO = 7
    const val AVM_ERR_UNSUPPORTED = 8
    const val AVM_ERR_BUFFER_TOO_SMALL = 9
    const val AVM_ERR_INTERNAL = 127

    // ---- VM state (avm_vm_state) ----
    const val AVM_STATE_STOPPED = 0
    const val AVM_STATE_STARTING = 1
    const val AVM_STATE_RUNNING = 2
    const val AVM_STATE_PAUSED = 3
    const val AVM_STATE_STOPPING = 4
    const val AVM_STATE_ERROR = 5

    // ---- Accelerator (avm_accel) ----
    const val AVM_ACCEL_HOST = 0
    const val AVM_ACCEL_KVM = 1
    const val AVM_ACCEL_HVF = 2
    const val AVM_ACCEL_WHPX = 3
    const val AVM_ACCEL_TCG = 4

    // ---- Boot strategy (avm_boot) ----
    const val AVM_BOOT_AUTO = 0
    const val AVM_BOOT_UEFI = 1
    const val AVM_BOOT_DIRECT_KERNEL = 2
    const val AVM_BOOT_BIOS = 3

    external fun nativeVersion(): String
    external fun nativeStatusString(status: Int): String
    external fun nativeFindQemu(): String
    external fun nativeCreate(
        name: String,
        qemuPath: String,
        machine: String,
        cpu: String,
        smp: Int,
        memoryMb: Long,
        accel: Int,
        boot: Int,
        kernel: String,
        initrd: String,
        cmdline: String,
        diskPath: String,
        cdrom: String,
        display: String,
        extraArgs: String
    ): Long
    external fun nativeDestroy(handle: Long)
    external fun nativeBuildArgv(handle: Long): String
    external fun nativeDescribe(handle: Long): String
    external fun nativeStart(handle: Long): Int
    external fun nativeStop(handle: Long): Int
    external fun nativeState(handle: Long): Int
    external fun nativeIsRunning(handle: Long): Int
    external fun nativePid(handle: Long): Int
}
