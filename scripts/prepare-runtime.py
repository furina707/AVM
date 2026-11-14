#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
Prepare the default guest runtime for the Android APK.

This is the DEFAULT build path (run by GitHub Actions, never on the phone):
  1. `git clone --depth 1` the Termux package recipes (source of the QEMU
     binaries and their dependency metadata).
  2. Fetch the Termux apt Packages index for aarch64 (git-pinned recipe version
     is used where available; the index is the authoritative binary source).
  3. Download qemu-system-aarch64-headless plus its full transitive .deb
     closure, extract qemu-system-aarch64 and the recursive set of DT_NEEDED
     shared libraries, stripping the Termux RUNPATH by relying on
     LD_LIBRARY_PATH at runtime (all these ELFs use DT_RUNPATH, tag 29, which
     LD_LIBRARY_PATH overrides).
  4. Fetch a minimal bootable aarch64 guest: Alpine netboot kernel + initramfs.
  5. Write everything into android/app/src/main/assets/runtime/ so Gradle packs
     it into the APK.

Nothing here needs to be compiled on the device. The resulting files are
plain Android/bionic ELF binaries that the app executes directly.

Usage:
    python3 scripts/prepare-runtime.py --out android/app/src/main/assets/runtime
"""

from __future__ import annotations

import argparse
import gzip
import io
import lzma
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

TERMUX_APT = "https://packages.termux.dev/apt/termux-main"
TERMUX_PACKAGES_GIT = "https://github.com/termux/termux-packages.git"
ALPINE = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/netboot"

# bionic provides these; they must NOT be bundled.
BIONIC_LIBS = {"libdl.so", "libc.so", "libm.so", "libz.so", "liblog.so"}

QEMU_PKG = "qemu-system-aarch64-headless"


def log(msg: str) -> None:
    print(f"[runtime] {msg}", flush=True)


def http_get(url: str, timeout: int = 240) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "AVM-runtime-builder/1.0"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001
            if attempt == 2:
                raise
            log(f"  retry {url} ({e})")
    raise RuntimeError("unreachable")


def deb_data(raw: bytes) -> bytes:
    """Extract data.tar.* payload from an ar archive (.deb)."""
    assert raw[:8] == b"!<arch>\n", "not a .deb (ar) archive"
    off = 8
    while off + 60 <= len(raw):
        hdr = raw[off : off + 60]
        name = hdr[0:16].decode("ascii").strip()
        size = int(hdr[48:58].decode("ascii").strip())
        body = raw[off + 60 : off + 60 + size]
        off += 60 + size + (size % 2)
        if name.startswith("data.tar"):
            if body[:6] == b"\xfd7zXZ\x00":
                return lzma.decompress(body)
            if body[:2] == b"\x1f\x8b":
                return gzip.decompress(body)
            return body  # uncompressed tar
    raise RuntimeError("no data.tar in .deb")


def tar_entries(raw: bytes):
    """Yield (name, typeflag, linkname, data) from a tar byte string."""
    off = 0
    while off + 512 <= len(raw):
        h = raw[off : off + 512]
        name = h[0:100].split(b"\0")[0].decode(errors="replace")
        if not name:
            break
        size = int((h[124:136].rstrip(b"\0 ").decode() or "0"), 8)
        typ = h[156:157]
        link = h[157:257].split(b"\0")[0].decode(errors="replace")
        yield name, typ, link, raw[off + 512 : off + 512 + size]
        off += 512 + ((size + 511) // 512) * 512


def elf_dyn(data: bytes) -> tuple[list[str], list[str]]:
    """Return (DT_NEEDED list, DT_RPATH/DT_RUNPATH list) of an ELF."""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return [], []
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    shnum = struct.unpack_from("<H", data, 0x3C)[0]

    def sh(i):
        return struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)

    def cstr(tab: bytes, o: int) -> str:
        e = tab.find(b"\0", o)
        return tab[o:e].decode(errors="replace")

    needed: list[str] = []
    paths: list[str] = []
    for i in range(shnum):
        s = sh(i)
        if s[1] != 6:  # SHT_DYNAMIC
            continue
        link = sh(s[6])
        strtab = data[link[4] : link[4] + link[5]]
        dyn = data[s[4] : s[4] + s[5]]
        for j in range(0, len(dyn), 16):
            tag, val = struct.unpack_from("<QQ", dyn, j)
            if tag == 1:
                needed.append(cstr(strtab, val))
            elif tag in (15, 29):
                paths.append(cstr(strtab, val))
            if tag == 0:
                break
    return needed, paths


def clone_recipes(dest: str) -> None:
    """git clone --depth 1 the Termux package recipes (source of truth)."""
    if os.path.isdir(os.path.join(dest, ".git")):
        log("termux-packages already cloned; pulling depth 1")
        subprocess.run(["git", "-C", dest, "pull", "--ff-only", "--depth", "1"], check=True)
        return
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    log(f"git clone --depth 1 {TERMUX_PACKAGES_GIT}")
    subprocess.run(
        ["git", "clone", "--depth", "1", "--filter=blob:none", "--sparse", TERMUX_PACKAGES_GIT, dest],
        check=True,
    )
    subprocess.run(["git", "-C", dest, "sparse-checkout", "set", "packages/qemu-system-x86-64-headless"], check=True)
    recipe = os.path.join(dest, "packages/qemu-system-x86-64-headless/build.sh")
    if not os.path.isfile(recipe):
        raise RuntimeError("QEMU recipe missing after clone")
    txt = open(recipe, encoding="utf-8").read()
    m = re.search(r'TERMUX_PKG_VERSION="1:(.+)"', txt)
    log(f"recipe QEMU version: {m.group(1) if m else 'unknown'}; recipe pulled (depth 1)")


def parse_index(index_gz: bytes) -> tuple[dict[str, str], dict[str, list[str]]]:
    txt = gzip.decompress(index_gz).decode("utf-8", errors="replace")
    files: dict[str, str] = {}
    deps: dict[str, list[str]] = {}
    for block in txt.split("\n\n"):
        n = re.search(r"^Package: (.+)$", block, re.M)
        if not n:
            continue
        name = n.group(1)
        f = re.search(r"^Filename: (.+)$", block, re.M)
        d = re.search(r"^Depends: (.+)$", block, re.M)
        if f:
            files[name] = f.group(1).strip()
        deps[name] = (
            [x.strip().split(" ")[0].split("(")[0] for x in d.group(1).split(",")] if d else []
        )
    return files, deps


def closure(root: str, deps: dict[str, list[str]]) -> set[str]:
    seen: set[str] = set()
    stack = [root]
    while stack:
        x = stack.pop()
        if x in seen:
            continue
        seen.add(x)
        for y in deps.get(x, []):
            if y not in seen:
                stack.append(y)
    return seen


def download_debs(pkgs: set[str], files: dict[str, str], work: str) -> list[str]:
    os.makedirs(work, exist_ok=True)
    urls = []
    for p in sorted(pkgs):
        if p not in files:
            raise RuntimeError(f"no Filename for package {p}")
        # ':' in versions must be percent-encoded for the HTTP path.
        urls.append((p, TERMUX_APT + "/" + files[p].replace(":", "%3A")))
    out_paths = []

    def fetch(item):
        p, url = item
        out = os.path.join(work, f"{abs(hash(p)) & 0xffffffff:08x}.deb")
        if not (os.path.isfile(out) and os.path.getsize(out) > 0):
            data = http_get(url)
            with open(out, "wb") as f:
                f.write(data)
        return out

    with ThreadPoolExecutor(max_workers=8) as ex:
        futs = {ex.submit(fetch, it): it[0] for it in urls}
        for fut in as_completed(futs):
            out_paths.append(fut.result())
    log(f"downloaded {len(out_paths)} .debs")
    return out_paths


def collect_libs(deb_paths: list[str]) -> tuple[dict[str, bytes], bytes]:
    real: dict[str, bytes] = {}
    links: dict[str, str] = {}
    qemu_bin: bytes | None = None
    for p in deb_paths:
        for nm, typ, link, data in tar_entries(deb_data(open(p, "rb").read())):
            base = os.path.basename(nm)
            if nm.endswith("bin/qemu-system-aarch64") and typ == b"0":
                qemu_bin = data
            if ".so" not in base:
                continue
            if typ == b"2":
                links[base] = os.path.basename(link)
            elif typ == b"0":
                real.setdefault(base, data)
    if qemu_bin is None:
        raise RuntimeError("qemu-system-aarch64 binary not found in debs")
    so = dict(real)
    for alias, target in links.items():
        if alias not in so and target in real:
            so[alias] = real[target]
    return so, qemu_bin


def resolve_bundle(so: dict[str, bytes], qemu_bin: bytes) -> list[str]:
    root_needed, _ = elf_dyn(qemu_bin)
    log(f"qemu DT_NEEDED: {len(root_needed)} entries")
    seen: set[str] = set()
    unresolved: set[str] = set()
    stack = list(root_needed)
    while stack:
        n = stack.pop()
        if n in seen or n in BIONIC_LIBS:
            continue
        if n not in so:
            unresolved.add(n)
            continue
        seen.add(n)
        for m in elf_dyn(so[n])[0]:
            if m not in seen and m not in BIONIC_LIBS:
                stack.append(m)
    if unresolved:
        raise RuntimeError(f"unresolved shared libraries: {sorted(unresolved)}")
    log(f"resolved {len(seen)} shared objects to bundle")
    return sorted(seen)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="android/app/src/main/assets/runtime")
    ap.add_argument("--work", default=".runtime-work")
    ap.add_argument("--skip-git", action="store_true", help="skip the depth-1 recipe clone")
    args = ap.parse_args()

    os.makedirs(args.work, exist_ok=True)
    if not args.skip_git:
        clone_recipes(os.path.join(args.work, "termux-packages"))

    log("fetching Termux apt Packages index (aarch64)")
    index = http_get(f"{TERMUX_APT}/dists/stable/main/binary-aarch64/Packages.gz")
    files, deps = parse_index(index)
    pkgs = closure(QEMU_PKG, deps)
    log(f"transitive dependency closure: {len(pkgs)} packages")

    deb_paths = download_debs(pkgs, files, os.path.join(args.work, "debs"))
    so, qemu_bin = collect_libs(deb_paths)
    bundle = resolve_bundle(so, qemu_bin)

    # All of these ELFs carry DT_RUNPATH (tag 29), which LD_LIBRARY_PATH
    # overrides. If any carried DT_RPATH (tag 15) instead, our app-private
    # lib dir would be ignored and the Termux path would win -> abort early.
    def has_rpath(data: bytes) -> bool:
        shoff = struct.unpack_from("<Q", data, 0x28)[0]
        shentsize = struct.unpack_from("<H", data, 0x3A)[0]
        shnum = struct.unpack_from("<H", data, 0x3C)[0]
        for i in range(shnum):
            s = struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize)
            if s[1] != 6:
                continue
            dyn = data[s[4] : s[4] + s[5]]
            for j in range(0, len(dyn), 16):
                tag = struct.unpack_from("<Q", dyn, j)[0]
                if tag == 15:
                    return True
                if tag == 0:
                    break
        return False

    offenders = [n for n in bundle if has_rpath(so[n])]
    if offenders or has_rpath(qemu_bin):
        raise RuntimeError(f"DT_RPATH found (LD_LIBRARY_PATH would be ignored): {offenders}")
    log("all bundled ELFs use DT_RUNPATH; app LD_LIBRARY_PATH will override it")

    out = args.out
    os.makedirs(out, exist_ok=True)

    # Pack the whole runtime into a single xz-compressed tar. Gradle/aapt do
    # NOT compress .so/ELF assets well (and APK entries are stored per-file),
    # so a pre-compressed tarball is both smaller in the APK and faster to
    # unpack on first launch. The app extracts it into its private filesDir.
    import tarfile

    staged = os.path.join(args.work, "staged")
    if os.path.isdir(staged):
        shutil.rmtree(staged)
    libdir = os.path.join(staged, "lib")
    os.makedirs(libdir, exist_ok=True)
    with open(os.path.join(staged, "qemu-system-aarch64"), "wb") as f:
        f.write(qemu_bin)
    for name in bundle:
        with open(os.path.join(libdir, name), "wb") as f:
            f.write(so[name])

    log("fetching default guest (Alpine aarch64 netboot kernel + initramfs)")
    for f_name in ("vmlinuz-lts", "initramfs-lts"):
        data = http_get(f"{ALPINE}/{f_name}")
        with open(os.path.join(staged, f_name), "wb") as fh:
            fh.write(data)
        log(f"  {f_name}: {len(data) / 1e6:.1f} MB")

    manifest = "AVM default guest runtime\n"
    manifest += f"source: {TERMUX_PACKAGES_GIT} (depth 1) + {TERMUX_APT}\n"
    manifest += f"qemu: {QEMU_PKG}\n"
    manifest += f"libs: {len(bundle)}\n"
    manifest += "".join(f"  {n}\n" for n in bundle)
    with open(os.path.join(staged, "MANIFEST.txt"), "w", encoding="utf-8") as f:
        f.write(manifest)

    tar_path = os.path.join(out, "runtime.tar.xz")
    log(f"packing {tar_path}")
    with tarfile.open(tar_path, "w:xz", preset=6, format=tarfile.USTAR_FORMAT) as tar:
        # Explicit directory entries first, then regular files. USTAR has a
        # 100-byte name limit; all our paths are short ("lib/<soname>").
        for root, dirs, fnames in os.walk(staged):
            dirs.sort()
            for d in dirs:
                full = os.path.join(root, d)
                tar.add(full, arcname=os.path.relpath(full, staged), recursive=False)
            for fn in sorted(fnames):
                full = os.path.join(root, fn)
                tar.add(full, arcname=os.path.relpath(full, staged), recursive=False)

    packed = os.path.getsize(tar_path)
    log(f"runtime packed: {len(bundle)} libs + qemu + kernel + initramfs, tar.xz = {packed / 1e6:.1f} MB at {tar_path}")
    with open(os.path.join(out, "MANIFEST.txt"), "w", encoding="utf-8") as f:
        f.write(manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
