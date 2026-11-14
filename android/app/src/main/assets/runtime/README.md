# Default guest runtime

This directory is populated by CI (`scripts/prepare-runtime.py`) with
`runtime.tar.xz` containing:

- `qemu-system-aarch64` — prebuilt Android/bionic QEMU (from Termux recipes,
  cloned with `git clone --depth 1`)
- `lib/*.so` — the recursive `DT_NEEDED` shared-library closure
- `vmlinuz-lts` + `initramfs-lts` — a minimal bootable Alpine aarch64 guest

The app extracts this tarball into its private `filesDir` on first launch and
runs QEMU directly (with `LD_LIBRARY_PATH` overriding the ELFs' baked-in
Termux `DT_RUNPATH`). Nothing is compiled on the phone.

`runtime.tar.xz` is a build artifact and is **not** committed. A locally built
APK without it will simply report "运行时缺失" in the UI.
