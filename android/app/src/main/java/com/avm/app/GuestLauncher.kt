package com.avm.app

import android.content.Context
import java.io.File

/**
 * Wires the bundled default guest runtime to the Zig C ABI.
 *
 * Flow (all on the phone, no compilation):
 *   1. RuntimeManager extracts runtime.tar.xz (QEMU + 69 .so + Alpine kernel
 *      + initramfs) into the app's private filesDir and chmod +x QEMU.
 *   2. We create a VM whose config points at that QEMU binary and boots the
 *      bundled kernel/initramfs in direct-kernel mode.
 *   3. LD_LIBRARY_PATH is passed through avm_vm_set_env so the bionic loader
 *      finds our libs instead of the ELFs' baked-in Termux RUNPATH.
 *   4. QEMU stdout/stderr are redirected to a log file in filesDir so the UI
 *      can show boot progress; serial console is exposed on a TCP port for a
 *      VNC/serial client, and a VNC display is enabled.
 *
 * The VM handle is owned here and destroyed on stop().
 */
object GuestLauncher {

    @Volatile
    private var handle: Long = 0L
    @Volatile
    private var logFile: File? = null
    @Volatile
    private var runtime: RuntimeManager.Runtime? = null

    data class Result(val ok: Boolean, val message: String)

    fun isRunning(): Boolean = handle != 0L && AvmBridge.nativeIsRunning(handle) != 0

    /** Prepare (extract) the runtime. Safe to call repeatedly. */
    fun prepare(context: Context): Result {
        val r = RuntimeManager.ensure(context.applicationContext)
            ?: return Result(false, "运行时缺失：请用 CI 构建的 APK（含 runtime.tar.xz）")
        runtime = r
        val kvm = if (RuntimeManager.hasKvm()) "KVM 可用" else "KVM 不可用 → 使用 TCG 软件模拟（较慢）"
        return Result(true, "运行时就绪：${r.libDir.listFiles()?.size ?: 0} 个库，$kvm")
    }

    /**
     * Create + start the default guest. Returns quickly; QEMU keeps running
     * as a child process managed by the Zig core.
     */
    fun start(context: Context, smp: Int, memoryMb: Long): Result {
        if (handle != 0L) return Result(false, "已有 VM 在运行，请先停止")

        val r = RuntimeManager.ensure(context.applicationContext)
            ?: return Result(false, "运行时缺失：请用 CI 构建的 APK（含 runtime.tar.xz）")
        runtime = r

        val accel = if (RuntimeManager.hasKvm()) AvmBridge.AVM_ACCEL_KVM else AvmBridge.AVM_ACCEL_TCG
        val log = File(context.filesDir, "qemu.log")
        logFile = log

        // Direct-kernel boot of the bundled Alpine aarch64 netboot image.
        // -nographic + serial over TCP lets a VNC/serial client attach; VNC on
        // display :0 gives a graphical console too. QMP socket is optional.
        val serialPort = 4444
        val extra = buildString {
            append("-serial tcp::").append(serialPort).append(",server,nowait ")
            append("-vnc :0 ")
            append("-monitor none ")
            append("-qmp unix:").append(File(context.filesDir, "qmp.sock").absolutePath)
            append(",server,nowait")
        }

        val h = AvmBridge.nativeCreate(
            name = "default-alpine",
            qemuPath = r.qemu.absolutePath,
            machine = "virt",
            cpu = if (accel == AvmBridge.AVM_ACCEL_TCG) "max" else "host",
            smp = smp,
            memoryMb = memoryMb,
            accel = accel,
            boot = AvmBridge.AVM_BOOT_DIRECT_KERNEL,
            kernel = r.kernel.absolutePath,
            initrd = r.initramfs.absolutePath,
            cmdline = "console=ttyAMA0 earlycon=pl011,0x9000000 panic=-1",
            diskPath = "",
            cdrom = "",
            display = "none",
            extraArgs = extra,
        )
        if (h == 0L) {
            return Result(false, "创建 VM 失败：${AvmBridge.nativeStatusString(AvmBridge.AVM_ERR_INVALID_ARGUMENT)}")
        }
        handle = h

        // LD_LIBRARY_PATH overrides the Termux DT_RUNPATH baked into the ELFs.
        AvmBridge.nativeSetEnv(h, "LD_LIBRARY_PATH", r.envLibPath)
        AvmBridge.nativeSetEnv(h, "TMPDIR", context.cacheDir.absolutePath)
        AvmBridge.nativeSetEnv(h, "QEMU_AUDIO_DRV", "none")
        AvmBridge.nativeSetEnv(h, "HOME", context.filesDir.absolutePath)
        AvmBridge.nativeSetLogFile(h, log.absolutePath)

        val st = AvmBridge.nativeStart(h)
        if (st != AvmBridge.AVM_OK) {
            destroy()
            return Result(false, "启动失败：${AvmBridge.nativeStatusString(st)}（详见 qemu.log）")
        }
        return Result(
            true,
            "客户机已启动：accel=${if (accel == AvmBridge.AVM_ACCEL_KVM) "KVM" else "TCG"}, " +
                "smp=$smp, mem=${memoryMb}MB；串口 tcp::$serialPort, VNC :0",
        )
    }

    fun status(): String {
        val h = handle
        if (h == 0L) return "未创建"
        val state = AvmBridge.nativeState(h)
        val running = AvmBridge.nativeIsRunning(h)
        val pid = AvmBridge.nativePid(h)
        return "state=$state running=$running pid=$pid"
    }

    /** Read the tail of the QEMU log (up to [maxLines] lines). */
    fun readLog(maxLines: Int = 40): String {
        val f = logFile ?: return ""
        if (!f.isFile) return ""
        return try {
            val lines = f.readLines()
            lines.takeLast(maxLines).joinToString("\n")
        } catch (t: Throwable) {
            "读取日志失败: ${t.message}"
        }
    }

    fun stop() {
        val h = handle
        if (h != 0L) {
            AvmBridge.nativeStop(h)
            destroy()
        }
    }

    private fun destroy() {
        val h = handle
        if (h != 0L) {
            AvmBridge.nativeDestroy(h)
            handle = 0L
        }
    }
}
