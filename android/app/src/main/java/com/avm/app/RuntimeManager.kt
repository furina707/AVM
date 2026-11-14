package com.avm.app

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import org.tukaani.xz.XZInputStream

/**
 * Unpacks and owns the default guest runtime shipped in the APK assets.
 *
 * The runtime tarball is produced by `scripts/prepare-runtime.py` during CI:
 * a git depth-1 clone of the Termux recipes plus the prebuilt, bionic-linked
 * qemu-system-aarch64, its recursive DT_NEEDED .so closure, and a minimal
 * Alpine aarch64 netboot kernel + initramfs. Nothing is compiled on the phone.
 *
 * Layout after extraction (all under context.filesDir/runtime):
 *   qemu-system-aarch64      (executable, PIE, interp /system/bin/linker64)
 *   lib/<soname>           (LD_LIBRARY_PATH target; overrides Termux RUNPATH)
 *   vmlinuz-lts              (default guest kernel)
 *   initramfs-lts            (default guest initramfs)
 *   MANIFEST.txt
 */
object RuntimeManager {

    // Kotlin source cannot contain a literal NUL escape (the Unicode
    // preprocessor turns it into a real NUL byte). Use Char(0) instead.
    private val NUL: Char = Char(0)

    private const val ASSET = "runtime/runtime.tar.xz"
    private const val DIR = "runtime"
    private const val MARKER = ".ready"

    @Volatile
    private var cached: Runtime? = null
    private val extracting = AtomicBoolean(false)

    data class Runtime(
        val dir: File,
        val qemu: File,
        val libDir: File,
        val kernel: File,
        val initramfs: File,
        val manifest: String,
    ) {
        val envLibPath: String get() = libDir.absolutePath
    }

    /** True when /dev/kvm exists AND is readable/writable by this process. */
    fun hasKvm(): Boolean {
        val f = File("/dev/kvm")
        return try {
            f.exists() && f.canRead() && f.canWrite()
        } catch (t: Throwable) {
            false
        }
    }

    /**
     * Ensure the runtime is extracted. Returns null if the asset is missing
     * (e.g. a locally-built APK without running prepare-runtime.py).
     * Extraction is idempotent and guarded by a marker file.
     */
    fun ensure(context: Context, force: Boolean = false): Runtime? {
        cached?.let { if (!force) return it }
        val outDir = File(context.filesDir, DIR)
        val marker = File(outDir, MARKER)

        if (!force && marker.isFile) {
            val r = buildRuntime(outDir)
            if (r != null) {
                cached = r
                return r
            }
        }

        // Simple single-flight guard; callers are on the main/IO scope.
        if (!extracting.compareAndSet(false, true)) {
            // Another thread is extracting; do a short bounded wait.
            repeat(40) {
                if (marker.isFile) return buildRuntime(outDir).also { cached = it }
                Thread.sleep(100)
            }
            return null
        }
        try {
            if (outDir.exists()) outDir.deleteRecursively()
            outDir.mkdirs()

            context.assets.open(ASSET).use { input ->
                XZInputStream(input).use { xz ->
                    extractTar(xz, outDir)
                }
            }

            val qemu = File(outDir, "qemu-system-aarch64")
            if (!qemu.isFile) return null
            qemu.setExecutable(true, false)
            File(outDir, "lib").listFiles()?.forEach { it.setReadable(true, false) }

            marker.writeText("ok")
            val r = buildRuntime(outDir)
            cached = r
            return r
        } catch (t: Throwable) {
            return null
        } finally {
            extracting.set(false)
        }
    }

    private fun buildRuntime(dir: File): Runtime? {
        val qemu = File(dir, "qemu-system-aarch64")
        val kernel = File(dir, "vmlinuz-lts")
        val initramfs = File(dir, "initramfs-lts")
        val libs = File(dir, "lib")
        if (!qemu.isFile || !kernel.isFile || !initramfs.isFile || !libs.isDirectory) return null
        if (!qemu.canExecute()) qemu.setExecutable(true, false)
        val manifest = File(dir, "MANIFEST.txt").takeIf { it.isFile }?.readText() ?: ""
        return Runtime(dir, qemu, libs, kernel, initramfs, manifest)
    }

    /** Minimal tar extractor (GNU/ustar), enough for our own tar.xz. */
    private fun extractTar(input: java.io.InputStream, dest: File) {
        val buf = ByteArray(512)
        var longName: String? = null
        while (true) {
            var read = 0
            while (read < 512) {
                val n = input.read(buf, read, 512 - read)
                if (n < 0) {
                    if (read == 0) return
                    break
                }
                read += n
            }
            if (read < 512) return
            // Two zero blocks mark end of archive.
            if (buf.all { it == 0.toByte() }) return

            val name = String(buf, 0, 100).trimEnd(NUL, ' ')
            val sizeStr = String(buf, 124, 12).trimEnd(NUL, ' ').trim()
            val size = sizeStr.toLongOrNull(8) ?: 0L
            val type = buf[156]
            val link = String(buf, 157, 100).trimEnd(NUL, ' ')
            val prefix = String(buf, 345, 155).trimEnd(NUL, ' ')
            val effective = longName ?: (if (prefix.isNotEmpty()) "$prefix/$name" else name)
            longName = null

            val target = File(dest, effective)
            // Guard against path traversal.
            if (!target.canonicalPath.startsWith(dest.canonicalPath + File.separator)) {
                skip(input, size)
                continue
            }

            when (type) {
                '5'.code.toByte() -> { // directory
                    target.mkdirs()
                    skip(input, size)
                }
                'L'.code.toByte() -> { // GNU long name
                    val data = readFully(input, size)
                    longName = String(data).trimEnd(NUL)
                    skip(input, padding(size))
                }
                'x'.code.toByte(), 'g'.code.toByte(), 'K'.code.toByte() -> {
                    // PAX / GNU metadata headers: ignore, but consume payload.
                    skip(input, size + padding(size))
                }
                '0'.code.toByte(), 0.toByte() -> { // regular file
                    target.parentFile?.mkdirs()
                    FileOutputStream(target).use { out ->
                        var remaining = size
                        val chunk = ByteArray(64 * 1024)
                        while (remaining > 0) {
                            val n = input.read(chunk, 0, minOf(chunk.size.toLong(), remaining).toInt())
                            if (n < 0) break
                            out.write(chunk, 0, n)
                            remaining -= n
                        }
                    }
                    skip(input, padding(size))
                }
                else -> {
                    // symlink/hardlink/char devices etc.: not expected in our
                    // own tarball; consume and ignore.
                    skip(input, size + padding(size))
                }
            }
        }
    }

    private fun skip(input: java.io.InputStream, n: Long) {
        var remaining = n
        val b = ByteArray(8192)
        while (remaining > 0) {
            val r = input.read(b, 0, minOf(b.size.toLong(), remaining).toInt())
            if (r < 0) return
            remaining -= r
        }
    }

    private fun readFully(input: java.io.InputStream, n: Long): ByteArray {
        val out = java.io.ByteArrayOutputStream(n.toInt())
        var remaining = n
        val b = ByteArray(8192)
        while (remaining > 0) {
            val r = input.read(b, 0, minOf(b.size.toLong(), remaining).toInt())
            if (r < 0) break
            out.write(b, 0, r)
            remaining -= r
        }
        return out.toByteArray()
    }

    private fun padding(size: Long): Long = ((512 - (size % 512)) % 512)
}
