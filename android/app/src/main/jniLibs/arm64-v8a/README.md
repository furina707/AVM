# arm64-v8a prebuilt library

Place the Zig-built `libavm.so` here:

```
# from the AVM project root — recommended one-step build + copy
zig build android -Doptimize=ReleaseSafe

# or cross-compile and copy manually
zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe
cp zig-out/lib/libavm.so android/app/src/main/jniLibs/arm64-v8a/libavm.so
```

`libavm_jni.so` (built by CMake from `src/main/cpp/avm_jni.c`) links against
this prebuilt `libavm.so` via the IMPORTED target in `CMakeLists.txt`.
Android Studio / Gradle then packages both `.so` files into the APK.

**No `.so` file is committed to this repository.** The build will fail to link
`libavm_jni.so` until you supply `libavm.so` in this directory.
