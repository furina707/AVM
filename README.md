# AVM

一个基于 **QEMU** 的 arm64 (AArch64) 虚拟机控制平面，支持 KVM 硬件加速，
可编译为 Android APK 在手机上使用，也可作为命令行工具/静态库运行在
arm64 Linux 上。主要功能是**运行任意操作系统**。

- **核心：Zig**（纯 Zig 实现，无 C 编译器依赖，交叉编译不需要 NDK）
- **界面：Jetpack Compose**（Android 客户端，Kotlin）
- **ABI：稳定的 C ABI**（`include/avm.h`），可被 JNI / C / C++ / Python ctypes 调用

> ⚠️ **重要**：AVM 本身**不模拟 CPU，也不附带 QEMU 二进制**。它是一个薄薄的
> 「控制平面」：根据配置生成 `qemu-system-aarch64` 命令行、启动/停止/查询该
> 外部进程、上报虚拟机状态。你必须自行提供 `qemu-system-aarch64`（以及 UEFI
> 固件、磁盘镜像、ISO 等）。详见下方「QEMU 依赖」。

---

## 目录结构

```
AVM/
├── include/avm.h              # 公共 C ABI 头文件（权威定义）
├── src/
│   ├── abi.zig                # C ABI 的 Zig 声明（类型/常量/extern 声明）
│   ├── platform.zig           # 平台检测、QEMU 可执行文件自动发现
│   ├── config.zig             # 原生配置模型（拥有所有字符串）
│   ├── qemu_args.zig          # QEMU 命令行构建器
│   ├── vm.zig                 # VM 生命周期 / 状态机 / 进程管理
│   ├── c_api.zig              # C ABI 实现（pub export fn ...）
│   ├── main.zig               # avm 命令行工具
│   └── tests.zig              # 单元测试 + C ABI 集成测试
├── build.zig / build.zig.zon  # Zig 0.17 构建图
├── android/                   # Jetpack Compose 客户端（Gradle + JNI shim）
│   ├── app/src/main/java/.../MainActivity.kt   # Compose UI
│   ├── app/src/main/java/.../AvmBridge.kt      # Kotlin external 声明
│   ├── app/src/main/cpp/avm_jni.c             # C JNI 桥
│   ├── app/src/main/cpp/CMakeLists.txt         # 链接预编译 libavm.so
│   └── app/src/main/jniLibs/arm64-v8a/        # libavm.so 放置处
└── README.md / LICENSE
```

数据流：`Compose UI (Kotlin) → JNI shim (C) → C ABI → Zig 核心 → QEMU 进程`

---

## 环境要求

| 用途 | 要求 |
| --- | --- |
| 构建核心 / CLI / 库 | **Zig 0.17.0**（本项目按此版本 API 编写） |
| 构建 Android APK | Android Studio / AGP 8.5.2 / Kotlin 2.0.0 / JDK 17 / SDK 34 / NDK + CMake 3.22.1 |
| 运行虚拟机 | `qemu-system-aarch64`、目标系统镜像/ISO、UEFI 固件（可选） |
| KVM 加速 | Linux/Android：可用的 `/dev/kvm`；macOS：HVF；Windows：WHPX；否则回退 TCG 软件模拟 |

> Zig 可以直接交叉编译出 `aarch64-linux-android` 的 `.so`，**无需 Android NDK**；
> NDK/CMake 仅用于编译那个很小的 C JNI 桥和打 APK。

---

## 快速开始（本机）

```sh
zig build                 # 构建并安装到 zig-out/
zig build test            # 运行单元测试 + C ABI 集成测试
./zig-out/bin/avm --help  # 查看 CLI 用法
```

产物（`zig-out/`）：

| 文件 | 说明 |
| --- | --- |
| `bin/avm` | 命令行工具 |
| `lib/libavm.so`（Windows 为 `bin/avm.dll` + `lib/avm.lib`） | 共享 C ABI 库 |
| `lib/libavm_static.a`（Windows 为 `avm_static.lib`） | 静态 C ABI 库 |
| `include/avm.h` | 公共头文件 |

### CLI 示例

```sh
# 打印将要执行的 QEMU 命令行（不启动）
./zig-out/bin/avm build-argv \
    --qemu /usr/bin/qemu-system-aarch64 \
    --smp 4 --memory 2048 --accel kvm \
    --disk root.qcow2 --cdrom installer.iso \
    --hostfwd tcp::2222-:22

# 启动并等待 QEMU 退出（前台）
./zig-out/bin/avm start --qemu /usr/bin/qemu-system-aarch64 \
    --kernel Image --initrd initrd.gz --cmdline "console=ttyAMA0"

# 自动查找 QEMU / 查看版本
./zig-out/bin/avm find-qemu
./zig-out/bin/avm version
```

完整选项：`avm help`。可用 `AVM_QEMU` 环境变量或 `--qemu` 指定二进制路径。

---

## 交叉编译

```sh
# arm64 Linux（静态可执行文件 + .so + .a）
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe \
    --prefix zig-out/linux-arm64

# Android arm64-v8a
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe \
    --prefix zig-out/android
# 产物：zig-out/android/lib/libavm.so

# 一步到位：交叉编译并自动把 .so 放进 Compose 应用的 jniLibs
zig build android -Doptimize=ReleaseSafe
```

`zig build android` 使用 `UpdateSourceFiles` 把生成的 `libavm.so` 写入
`android/app/src/main/jniLibs/arm64-v8a/`，随后即可用 Android Studio / Gradle
打 APK。详见 [`android/README.md`](android/README.md)。

> 注意：Android 目标**不能**链接 libc（Zig 无法为该目标提供 libc），构建图已
> 自动处理；此时环境变量查找会回退到 `qemu_path` 配置 + 已知目录。

---

## Android / Compose 客户端

`android/` 是一个完整的、可构建的 Gradle 工程（Kotlin + Jetpack Compose +
Material3）。UI 提供：配置表单（名称、QEMU 路径、machine、CPU、SMP、内存、
加速器、启动方式、kernel/initrd/cmdline、磁盘、ISO、display、额外参数）、
创建/启动/停止/刷新状态/查看命令行按钮、状态卡片与日志。

```sh
zig build android -Doptimize=ReleaseSafe     # 1) 生成 libavm.so 并放入 jniLibs
cd android
gradle wrapper --gradle-version 8.7          # 2) 首次生成 wrapper
./gradlew assembleDebug                     # 3) 打 APK
```

C JNI 桥（`avm_jni.c`）只做参数编组：`avm_vm_create` 返回句柄，以 `jlong`
在 Kotlin 与 C 之间传递；`avm_vm_build_argv` / `avm_vm_describe` 采用
「先 dry-run 取大小、再分配填充」的两阶段调用。所有业务逻辑都在 Zig 里。

---

## C ABI 速览

头文件：[`include/avm.h`](include/avm.h)。版本 `0.1.0`。

```c
avm_vm_config cfg;
avm_config_init(&cfg);                 // 必须先调用，填入平台默认值
cfg.smp = 4; cfg.memory_mb = 2048;
cfg.accel = AVM_ACCEL_KVM;

avm_vm *vm = NULL;
if (avm_vm_create(&cfg, &vm) != AVM_OK) { /* 错误处理 */ }

avm_vm_start(vm);
avm_vm_state_get(vm);                  // AVM_STATE_RUNNING
avm_vm_stop(vm, 0);
avm_vm_destroy(vm);                    // 释放句柄（并终止仍在运行的 QEMU）
```

主要函数：`avm_version`、`avm_status_string`、`avm_config_init`、
`avm_vm_create/destroy/start/stop/wait/pause/resume`、`avm_vm_state_get`、
`avm_vm_is_running`、`avm_vm_pid`、`avm_vm_build_argv`、`avm_vm_describe`、
`avm_find_qemu`、`avm_string_free`。

字符串/缓冲区约定（JNI 与 C 调用方共用）：

- `avm_vm_build_argv(vm, NULL, &len)`：dry-run，返回参数个数并设置 `len`；
  再以 `char *buf[len]` 调用填充。返回的字符串**由 VM 的 arena 拥有**，直到
  `avm_vm_destroy` 有效，**不要 free**（`avm_string_free` 是 no-op）。
- `avm_vm_describe(vm, NULL, 0)`：返回所需字节数（**含结尾 NUL**）；
  再以该大小分配并调用，得到 NUL 结尾的 UTF-8 文本。
- `int` 返回值的函数出错时返回**负的 avm_status**。

---

## QEMU 依赖

AVM 生成的命令行面向 AArch64 `virt` 机器，典型形态：

```
qemu-system-aarch64 -machine virt,accel=kvm,gic-version=3 -cpu host \
  -smp 4 -m 2048M -drive file=root.qcow2,format=qcow2,if=virtio,cache=none \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-pci,netdev=net0 \
  -display none -device virtio-gpu-pci -device qemu-xhci -device usb-kbd \
  -device usb-tablet -rtc base=utc -nodefaults -no-reboot
```

你需要自行准备：

- `qemu-system-aarch64`（Linux 发行版包、`qemu` 源码编译，或交叉编译到 Android）；
- 虚拟机磁盘（qcow2/raw）、安装 ISO、内核/Initrd（直接内核启动时）；
- UEFI 固件 `QEMU_EFI.fd`（`--bios`，用于启动 Windows/通用 UEFI 系统）；
- 设备上的 `/dev/kvm`（KVM 加速），否则用 `--accel tcg`。

---

## 已验证 / 限制

已在 Windows (x86_64) 上用 Zig 0.17.0 验证：

- `zig build` 产出 CLI + 静态/共享库 + 头文件；`zig build test` 全部通过；
- C ABI 端到端测试（create / build_argv / describe / state / destroy / find_qemu）；
- `aarch64-linux-musl`、`aarch64-linux-android` 交叉编译产出真实 ARM aarch64
  ELF；Android `.so` 导出全部 17 个 `avm_*` 全局符号；
- `zig build android` 自动把 `.so` 放入 jniLibs。

**当前环境限制**：本机没有 Java / Gradle / Android SDK / NDK / QEMU，因此
**没有实际打 APK，也没有启动过真实客户机**；Android 源码为静态核对（JNI
名称/类型一一对应、Compose 代码完整）。在有 Android 工具链的机器上按
`android/README.md` 即可构建。

---

## 许可证

[MIT](LICENSE)
