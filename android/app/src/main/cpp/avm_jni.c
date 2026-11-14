/*
 * AVM JNI shim — bridges com.avm.app.AvmBridge to the Zig core libavm.so.
 * Plain C only. The VM owns all strings returned by the C ABI; never free them.
 */
#include <jni.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "avm.h"

/* ---- Small helper for jstring -> const char* with guaranteed release ---- */
typedef struct {
    JNIEnv *env;
    jstring js;
    const char *chars;
    int owned;
} utf_ref;

static const char *utf_get(utf_ref *r, JNIEnv *env, jstring s) {
    r->env = env;
    r->js = s;
    r->owned = 0;
    if (s != NULL) {
        const char *c = (*env)->GetStringUTFChars(env, s, NULL);
        if (c != NULL) {
            r->chars = c;
            r->owned = 1;
            return c;
        }
    }
    r->chars = "";
    return "";
}

static void utf_release(utf_ref *r) {
    if (r->owned) {
        (*r->env)->ReleaseStringUTFChars(r->env, r->js, r->chars);
        r->owned = 0;
    }
}

static jstring jstr(JNIEnv *env, const char *s) {
    return (*env)->NewStringUTF(env, s ? s : "");
}

static avm_vm *vm_of(jlong handle) {
    return (avm_vm *)(intptr_t)handle;
}

/* ---- 1. nativeVersion(): String ---- */
JNIEXPORT jstring JNICALL
Java_com_avm_app_AvmBridge_nativeVersion(JNIEnv *env, jclass clazz) {
    (void)clazz;
    return jstr(env, avm_version());
}

/* ---- 2. nativeStatusString(Int): String ---- */
JNIEXPORT jstring JNICALL
Java_com_avm_app_AvmBridge_nativeStatusString(JNIEnv *env, jclass clazz, jint status) {
    (void)clazz;
    return jstr(env, avm_status_string((avm_status)status));
}

/* ---- 3. nativeFindQemu(): String ---- */
JNIEXPORT jstring JNICALL
Java_com_avm_app_AvmBridge_nativeFindQemu(JNIEnv *env, jclass clazz) {
    (void)clazz;
    char path[4096];
    path[0] = '\0';
    avm_status st = avm_find_qemu(path, (uint32_t)sizeof(path));
    if (st != AVM_OK) {
        return jstr(env, avm_status_string(st));
    }
    return jstr(env, path);
}

/* ---- 4. nativeCreate(...): Long ---- */
JNIEXPORT jlong JNICALL
Java_com_avm_app_AvmBridge_nativeCreate(
        JNIEnv *env, jclass clazz,
        jstring jName, jstring jQemuPath, jstring jMachine, jstring jCpu,
        jint jSmp, jlong jMemoryMb, jint jAccel, jint jBoot,
        jstring jKernel, jstring jInitrd, jstring jCmdline,
        jstring jDiskPath, jstring jCdrom, jstring jDisplay, jstring jExtraArgs) {
    (void)clazz;

    utf_ref sName, sQemuPath, sMachine, sCpu, sKernel, sInitrd,
            sCmdline, sDiskPath, sCdrom, sDisplay, sExtraArgs;
    const char *name       = utf_get(&sName, env, jName);
    const char *qemuPath   = utf_get(&sQemuPath, env, jQemuPath);
    const char *machine    = utf_get(&sMachine, env, jMachine);
    const char *cpu        = utf_get(&sCpu, env, jCpu);
    const char *kernel     = utf_get(&sKernel, env, jKernel);
    const char *initrd     = utf_get(&sInitrd, env, jInitrd);
    const char *cmdline    = utf_get(&sCmdline, env, jCmdline);
    const char *diskPath   = utf_get(&sDiskPath, env, jDiskPath);
    const char *cdrom      = utf_get(&sCdrom, env, jCdrom);
    const char *display    = utf_get(&sDisplay, env, jDisplay);
    const char *extraArgs  = utf_get(&sExtraArgs, env, jExtraArgs);

    avm_vm_config cfg;
    avm_config_init(&cfg);
    cfg.name      = name;
    cfg.qemu_path = qemuPath;
    cfg.machine   = machine;
    cfg.cpu       = cpu;
    cfg.smp       = (uint32_t)jSmp;
    cfg.memory_mb = (uint64_t)jMemoryMb;
    cfg.accel     = (avm_accel)jAccel;
    cfg.boot      = (avm_boot)jBoot;
    cfg.kernel    = kernel;
    cfg.initrd    = initrd;
    cfg.cmdline   = cmdline;
    cfg.cdrom     = cdrom;
    cfg.display   = display;
    cfg.extra_args = extraArgs;

    avm_disk disks[1];
    if (diskPath[0] != '\0') {
        disks[0].path = diskPath;
        disks[0].format = AVM_DISK_QCOW2;
        disks[0].iface = AVM_DISK_IFACE_VIRTIO;
        disks[0].read_only = 0;
        cfg.disks = disks;
        cfg.disk_count = 1;
    }

    avm_vm *vm = NULL;
    if (avm_vm_create(&cfg, &vm) != AVM_OK) {
        vm = NULL;
    }

    utf_release(&sName);
    utf_release(&sQemuPath);
    utf_release(&sMachine);
    utf_release(&sCpu);
    utf_release(&sKernel);
    utf_release(&sInitrd);
    utf_release(&sCmdline);
    utf_release(&sDiskPath);
    utf_release(&sCdrom);
    utf_release(&sDisplay);
    utf_release(&sExtraArgs);

    return (jlong)(intptr_t)vm;
}

/* ---- 5. nativeDestroy(Long) ---- */
JNIEXPORT void JNICALL
Java_com_avm_app_AvmBridge_nativeDestroy(JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm != NULL) {
        avm_vm_destroy(vm);
    }
}

/* ---- 5b. nativeSetEnv(Long, String, String): Int ---- */
JNIEXPORT jint JNICALL
Java_com_avm_app_AvmBridge_nativeSetEnv(JNIEnv *env, jclass clazz, jlong handle,
                                        jstring jKey, jstring jValue) {
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return (jint)AVM_ERR_INVALID_ARGUMENT;
    utf_ref k, v;
    const char *key = utf_get(&k, env, jKey);
    const char *value = utf_get(&v, env, jValue);
    avm_status st = avm_vm_set_env(vm, key, value);
    utf_release(&k);
    utf_release(&v);
    return (jint)st;
}

/* ---- 5c. nativeSetLogFile(Long, String): Int ---- */
JNIEXPORT jint JNICALL
Java_com_avm_app_AvmBridge_nativeSetLogFile(JNIEnv *env, jclass clazz, jlong handle,
                                            jstring jPath) {
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return (jint)AVM_ERR_INVALID_ARGUMENT;
    utf_ref p;
    const char *path = utf_get(&p, env, jPath);
    avm_status st = avm_vm_set_log_file(vm, path);
    utf_release(&p);
    return (jint)st;
}

/* ---- 6. nativeBuildArgv(Long): String ----
 * Dry run to size, real call to fill. VM owns buf[i]; do NOT free the strings.
 */
JNIEXPORT jstring JNICALL
Java_com_avm_app_AvmBridge_nativeBuildArgv(JNIEnv *env, jclass clazz, jlong handle) {
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return jstr(env, "");

    uint32_t len = 0;
    int count = avm_vm_build_argv(vm, NULL, &len);
    if (count < 0) return jstr(env, avm_status_string((avm_status)(-count)));
    if (count == 0) return jstr(env, "");

    char **buf = (char **)malloc(sizeof(char *) * (size_t)count);
    if (buf == NULL) return jstr(env, avm_status_string(AVM_ERR_OUT_OF_MEMORY));

    uint32_t out_len = (uint32_t)count;
    int written = avm_vm_build_argv(vm, buf, &out_len);
    if (written <= 0) {
        free(buf);
        if (written < 0) return jstr(env, avm_status_string((avm_status)(-written)));
        return jstr(env, "");
    }

    size_t total = (size_t)(written - 1); /* spaces between args */
    for (int i = 0; i < written; ++i) {
        total += strlen(buf[i] ? buf[i] : "");
    }
    char *joined = (char *)malloc(total + 1);
    if (joined == NULL) {
        free(buf);
        return jstr(env, avm_status_string(AVM_ERR_OUT_OF_MEMORY));
    }

    size_t pos = 0;
    for (int i = 0; i < written; ++i) {
        if (i > 0) joined[pos++] = ' ';
        const char *arg = buf[i] ? buf[i] : "";
        size_t n = strlen(arg);
        memcpy(joined + pos, arg, n);
        pos += n;
    }
    joined[pos] = '\0';

    jstring result = jstr(env, joined);
    free(joined);
    free(buf); /* only the array; buf[i] strings belong to the VM */
    return result;
}

/* ---- 7. nativeDescribe(Long): String ----
 * Dry run returns bytes needed INCLUDING the NUL terminator.
 */
JNIEXPORT jstring JNICALL
Java_com_avm_app_AvmBridge_nativeDescribe(JNIEnv *env, jclass clazz, jlong handle) {
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return jstr(env, "");

    int needed = avm_vm_describe(vm, NULL, 0);
    if (needed < 0) return jstr(env, avm_status_string((avm_status)(-needed)));
    if (needed == 0) return jstr(env, "");

    char *buf = (char *)malloc((size_t)needed);
    if (buf == NULL) return jstr(env, avm_status_string(AVM_ERR_OUT_OF_MEMORY));
    buf[0] = '\0';

    int got = avm_vm_describe(vm, buf, (uint32_t)needed);
    if (got < 0) {
        free(buf);
        return jstr(env, avm_status_string((avm_status)(-got)));
    }
    buf[needed - 1] = '\0'; /* ensure NUL-terminated */

    jstring result = jstr(env, buf);
    free(buf);
    return result;
}

/* ---- 8. nativeStart(Long): Int ---- */
JNIEXPORT jint JNICALL
Java_com_avm_app_AvmBridge_nativeStart(JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return (jint)AVM_ERR_INVALID_ARGUMENT;
    return (jint)avm_vm_start(vm);
}

/* ---- 9. nativeStop(Long): Int (graceful; Kotlin has no force arg) ---- */
JNIEXPORT jint JNICALL
Java_com_avm_app_AvmBridge_nativeStop(JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return (jint)AVM_ERR_INVALID_ARGUMENT;
    return (jint)avm_vm_stop(vm, 0);
}

/* ---- 10. nativeState(Long): Int ---- */
JNIEXPORT jint JNICALL
Java_com_avm_app_AvmBridge_nativeState(JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return (jint)AVM_STATE_ERROR;
    return (jint)avm_vm_state_get(vm);
}

/* ---- 11. nativeIsRunning(Long): Int ---- */
JNIEXPORT jint JNICALL
Java_com_avm_app_AvmBridge_nativeIsRunning(JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return 0;
    return (jint)avm_vm_is_running(vm);
}

/* ---- 12. nativePid(Long): Int ---- */
JNIEXPORT jint JNICALL
Java_com_avm_app_AvmBridge_nativePid(JNIEnv *env, jclass clazz, jlong handle) {
    (void)env;
    (void)clazz;
    avm_vm *vm = vm_of(handle);
    if (vm == NULL) return 0;
    return (jint)avm_vm_pid(vm);
}
