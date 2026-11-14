# AVM Android 客户端 / AVM Android Client

一个基于 Jetpack Compose 的 AVM **控制平面** UI，通过 JNI 调用 Zig 核心库
`libavm.so`。它只负责构建 QEMU 命令行、启动/停止/查询 QEMU 进程，**本身不模拟 CPU**。

A Jetpack Compose **control-plane** UI for AVM. It calls the Zig core
`libavm.so` through a thin C JNI shim (`libavm_jni.so`). It builds QEMU command
lines and launches/stops/queries a QEMU process — it is **not an emulator**.

## 环境要求 / Requirements

- Android Studio (Ladybug 或更新) / AGP 8.5.2 / Kotlin 2.0.0 / JDK 17
- Android SDK Platform 34, NDK + CMake 3.22.1
- 一台 arm64-v8a (Android 8.0 / API 26+) 设备
- 设备上需要 `qemu-system-aarch64` 可执行文件与 `/dev/kvm`（用于 KVM 加速）

## 1. 构建 libavm.so / Build libavm.so

在 AVM 项目根目录（不是本 `android/` 目录）执行下面任一方式：

```sh
# 推荐：一步交叉编译并自动把 libavm.so 放进 jniLibs/arm64-v8a/
zig build android -Doptimize=ReleaseSafe

# 或者手动交叉编译后复制
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe
cp zig-out/lib/libavm.so android/app/src/main/jniLibs/arm64-v8a/libavm.so
```

From the AVM project root (not this `android/` dir), either:

```sh
# Recommended: cross-compile and auto-copy libavm.so into jniLibs/arm64-v8a/
zig build android -Doptimize=ReleaseSafe

# Or cross-compile and copy manually
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe
cp zig-out/lib/libavm.so android/app/src/main/jniLibs/arm64-v8a/libavm.so
```

`libavm.so` 不会被提交到仓库；缺了它，`libavm_jni.so` 无法链接。
`libavm.so` is not committed; without it the JNI shim cannot link.

## 2. 生成 Gradle Wrapper / Generate the Gradle Wrapper

本仓库只提供 `gradle/wrapper/gradle-wrapper.properties`，未提交 wrapper jar。

```sh
cd android
gradle wrapper --gradle-version 8.7 --distribution-type bin
```

Only `gradle-wrapper.properties` is committed; generate `gradlew`,
`gradlew.bat` and `gradle-wrapper.jar` locally.

## 3. 构建 APK / Build the APK

用 Android Studio 打开 `android/` 目录，或在 `android/` 下执行：

```sh
./gradlew assembleDebug
```

Open the `android/` directory in Android Studio, or run `./gradlew assembleDebug`.

CMake 会编译 `app/src/main/cpp/avm_jni.c` 为 `libavm_jni.so`，并把
`jniLibs/arm64-v8a/` 下的 `.so` 一起打包进 APK。
CMake compiles `app/src/main/cpp/avm_jni.c` into `libavm_jni.so` and packages
the `.so` files from `jniLibs/arm64-v8a/` into the APK.

## 4. 在设备上提供 QEMU / Provide QEMU on the device

把 QEMU 二进制推送到设备，例如：

```sh
adb push qemu-system-aarch64 /data/local/tmp/qemu-system-aarch64
adb shell chmod +x /data/local/tmp/qemu-system-aarch64
```

然后在应用里把 "QEMU 路径" 填为 `/data/local/tmp/qemu-system-aarch64`，
或点击 "自动查找" 让 `avm_find_qemu()` 尝试定位。

```sh
adb push qemu-system-aarch64 /data/local/tmp/qemu-system-aarch64
adb shell chmod +x /data/local/tmp/qemu-system-aarch64
```

Set the "QEMU 路径" field to `/data/local/tmp/qemu-system-aarch64`, or tap
"自动查找" to let `avm_find_qemu()` try to locate it.

## 5. 加速 / Acceleration

- KVM 加速需要设备内核支持并存在 `/dev/kvm`；否则请选择 `TCG`（软件模拟）。
- HVF / WHPX 在 Android 上不可用（仅列出供 ABI 对齐）。

- KVM acceleration requires `/dev/kvm` on the device; otherwise select `TCG`
  (software emulation).
- HVF / WHPX are not available on Android (listed only for ABI parity).

## 说明 / Notes

- 该应用是控制平面：它启动的是一个**外部 QEMU 进程**，不是内嵌模拟器。
- 所有字符串由 VM 拥有，JNI 层不会释放 `avm_vm_build_argv` 返回的各项。

- This app is a control plane: it launches an **external QEMU process**, not an
  embedded emulator.
- Strings returned by `avm_vm_build_argv` are owned by the VM; the JNI layer
  never frees them.
