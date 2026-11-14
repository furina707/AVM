# AVM

[![Build Android APK](https://github.com/furina707/AVM/actions/workflows/build-apk.yml/badge.svg)](https://github.com/furina707/AVM/actions/workflows/build-apk.yml)

一个基于 **QEMU** 的 arm64 (AArch64) 虚拟机控制平面，支持 KVM 硬件加速，
可编译为 Android APK 在手机上使用，也可作为命令行工具/静态库运行在
arm64 Linux 上。主要功能是**运行任意操作系统**。

- **核心：Zig**（纯 Zig 实现，无 C 编译器依赖，交叉编译不需要 NDK）
- **界面：Jetpack Compose**（Android 客户端，Kotlin）
- **ABI：稳定的 C ABI**（`include/avm.h`），可被 JNI / C / C++ / Python ctypes 调用

AVM 是「控制平面 + 默认运行时」：Zig 核心生成 `qemu-system-aarch64` 命令行并
启动/停止/查询该进程；**CI 默认把一套可直接在 Android 上运行的 QEMU 运行时
连同最小可启动的 Alpine aarch64 客户机一起打进 APK**，手机端一键启动，不需要
Termux、不需要在手机上编译。你也可以替换成自己的 QEMU / 磁盘镜像 / ISO。
详见下方「默认客户机运行时」与「QEMU 依赖」。

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
├── scripts/prepare-runtime.py # CI：git depth1 + 预编译 QEMU 运行时打包
├── build.zig / build.zig.zon  # Zig 0.17 构建图
├── android/                   # Jetpack Compose 客户端（Gradle + JNI shim）
│   ├── app/src/main/java/.../MainActivity.kt   # Compose UI
│   ├── app/src/main/java/.../AvmBridge.kt      # Kotlin external 声明
│   ├── app/src/main/java/.../RuntimeManager.kt # 解压/管理内置 QEMU 运行时
│   ├── app/src/main/java/.../GuestLauncher.kt  # 一键启动默认客户机
│   ├── app/src/main/cpp/avm_jni.c             # C JNI 桥
│   ├── app/src/main/cpp/CMakeLists.txt         # 链接预编译 libavm.so
│   ├── app/src/main/jniLibs/arm64-v8a/        # libavm.so 放置处
│   └── app/src/main/assets/runtime/            # runtime.tar.xz（CI 生成）
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

### GitHub Actions 自动构建 / 手机预览

每次 push 到 `main` 都会由 [build-apk.yml](.github/workflows/build-apk.yml)
自动从源码构建 `arm64-v8a` debug APK：CI 用 Zig 交叉编译 `libavm.so` → 用
CMake 编 JNI 桥 → Gradle 打 APK，并上传为名为 `AVM-<sha>-arm64-v8a-debug.apk`
的 artifact（保留 30 天，需登录 GitHub 才能下载）。

**手机上看界面（最简单）**：在 Actions 的 run 页面下载 APK → 传到手机 →
点击安装（需允许「安装未知应用」）→ 打开即可看到 Compose 控制面板。
也可以直接 `adb install app-debug.apk`。

**真正启动客户机（默认路径）**：CI 会用
[`scripts/prepare-runtime.py`](scripts/prepare-runtime.py) 从源码准备运行时 ——
`git clone --depth 1` Termux 的 QEMU 配方、解析完整依赖闭包、抽取
`qemu-system-aarch64` 与其递归 `DT_NEEDED` 的 69 个 `.so`，再下载 Alpine
aarch64 netboot 内核 + initramfs，打包成单个 `runtime.tar.xz`（约 57 MB）放进
APK 的 assets。手机**不编译任何东西**：App 首次启动把 tar.xz 解压到私有目录、
`chmod +x`，通过 `avm_vm_set_env` 设置 `LD_LIBRARY_PATH`（覆盖 ELF 里烘焙的
Termux `DT_RUNPATH`），把 QEMU stdout/stderr 重定向到 `qemu.log`，然后直接
`Runtime.exec` 启动客户机。

在 UI 里点「一键启动客户机」即可：有 `/dev/kvm` 走 KVM 加速，没有则自动回退
TCG 软件模拟；串口在 `tcp://127.0.0.1:4444`，VNC 在 `:0`，启动日志实时显示
在状态卡片里。

> 默认的 Alpine 只加载内核 + initramfs（无持久磁盘）；要装完整系统，把磁盘
> 路径、ISO、UEFI 固件等填进表单并用手动「创建VM / 启动」即可（见「QEMU 依赖」）。

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

**本地（Windows x86_64, Zig 0.17.0）**：

- `zig build` 产出 CLI + 静态/共享库 + 头文件；`zig build test` 13/13 通过；
- C ABI 端到端测试（create / build_argv / describe / state / destroy / find_qemu）；
- `aarch64-linux-musl`、`aarch64-linux-android` 交叉编译产出真实 ARM aarch64
  ELF；Android `.so` 导出全部 17 个 `avm_*` 全局符号、无 libc 依赖；
- `zig build android` 自动把 `.so` 放入 jniLibs。

**GitHub Actions（ubuntu-latest）**：

- 从源码完整构建并上传 `arm64-v8a` debug APK；APK 内含
  `lib/arm64-v8a/libavm.so` + `libavm_jni.so`、`classes.dex`、`resources.arsc`，
  以及 `assets/runtime/runtime.tar.xz`（QEMU + 69 个依赖库 + Alpine 内核/initramfs）；
- CI 依次跑 `zig build test` → `zig build android` →
  `scripts/prepare-runtime.py`（git depth1 + 预编译运行时）→ `gradle assembleDebug`。

**最终 APK 已校验**（run `43621397656`，66 MB）：

- `lib/arm64-v8a/libavm.so` + `libavm_jni.so`；
- `assets/runtime/runtime.tar.xz`（56.8 MB，74 个条目）：`qemu-system-aarch64`、
  `vmlinuz-lts`、`initramfs-lts`、69 个依赖 `.so`；
- `classes.dex` / `resources.arsc`。

**仍然的限制**：本机没有连接安卓设备，因此**没有在真机上点过「一键启动」**；
CI 只能验证 APK 打包正确、QEMU 运行时文件齐备（ELF 架构、DT_NEEDED 全部解析、
DT_RUNPATH 可被 LD_LIBRARY_PATH 覆盖）。真机启动还取决于设备内核是否开放
`/dev/kvm`（KVM）以及 SELinux 是否允许 App 执行私有目录内的 ELF；无 KVM 时
自动回退 TCG。若启动失败，`qemu.log` 会在 UI 里显示具体原因。

---

## 许可证

[MIT](LICENSE)
