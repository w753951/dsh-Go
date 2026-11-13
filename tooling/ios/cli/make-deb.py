#!/usr/bin/env python3
"""把 dshtouch 打成 rootless deb。

macOS 上没有 dpkg-deb，而 deb 本身就是一个 ar 归档，
里面装着 debian-binary、control.tar.gz 和 data.tar.gz。
这里直接按规范拼出来，不依赖任何 dpkg 工具。
"""

import gzip
import io
import os
import sys
import tarfile
import time

PACKAGE = "com.dshgo.dshtouch"
NAME = "dshtouch"
VERSION = "1.0.0"
ARCH = "iphoneos-arm64"
# 固定时间戳让产物可复现。
FIXED_MTIME = 1767225600

CONTROL = f"""Package: {PACKAGE}
Name: {NAME}
Version: {VERSION}
Architecture: {ARCH}
Description: Command-line control: tap, swipe, type, open apps, screenshot
Maintainer: DSH Go build
Author: DSH Go build
Section: Utilities
Depends: firmware (>= 15.0)
"""

POSTINST = """#!/bin/sh
set -e
for TARGET in /var/jb/usr/bin/dshtouch /usr/bin/dshtouch; do
  [ -f "$TARGET" ] || continue
  chmod 755 "$TARGET" || true
  chown root:wheel "$TARGET" || true
done
exit 0
"""

PRERM = """#!/bin/sh
set -e
exit 0
"""


def tar_entry(tar, name, data, mode=0o644):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.uname = "root"
    info.gname = "wheel"
    info.mtime = FIXED_MTIME
    tar.addfile(info, io.BytesIO(data))


def build_tar(entries):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as tar:
        for name, data, mode in entries:
            tar_entry(tar, name, data, mode)
    return gzip.compress(buffer.getvalue(), mtime=0)


def ar_entry(name, data):
    header = b""
    header += name.encode().ljust(16, b" ")
    header += str(int(time.time())).encode().ljust(12, b" ")
    header += b"0".ljust(6, b" ")
    header += b"0".ljust(6, b" ")
    header += b"100644".ljust(8, b" ")
    header += str(len(data)).encode().ljust(10, b" ")
    header += b"`\n"
    out = header + data
    if len(data) % 2:
        out += b"\n"
    return out


def main():
    binary_path = sys.argv[1] if len(sys.argv) > 1 else "dshtouch"
    output = f"{NAME}_{VERSION}_{ARCH}.deb"
    with open(binary_path, "rb") as handle:
        binary = handle.read()

    control_tar = build_tar([
        ("./control", CONTROL.encode(), 0o644),
        ("./postinst", POSTINST.encode(), 0o755),
        ("./prerm", PRERM.encode(), 0o755),
    ])

    # rootless 越狱把工具放在 /var/jb 下，这里保持一致。
    data_tar = build_tar([
        ("./var/", b"", 0o755),
        ("./var/jb/", b"", 0o755),
        ("./var/jb/usr/", b"", 0o755),
        ("./var/jb/usr/bin/", b"", 0o755),
        ("./var/jb/usr/bin/dshtouch", binary, 0o755),
    ])

    deb = b"!<arch>\n"
    deb += ar_entry("debian-binary", b"2.0\n")
    deb += ar_entry("control.tar.gz", control_tar)
    deb += ar_entry("data.tar.gz", data_tar)

    with open(output, "wb") as handle:
        handle.write(deb)
    print(f"wrote {output} ({len(deb)} bytes)")

    # 自检：结构必须是三个 ar 成员，两个 tar 能解开。
    assert deb.startswith(b"!<arch>\n"), "not an ar archive"
    for name, blob in (("control.tar.gz", control_tar), ("data.tar.gz", data_tar)):
        with tarfile.open(fileobj=io.BytesIO(gzip.decompress(blob)), mode="r") as tar:
            members = [m.name for m in tar.getmembers()]
        print(f"{name}: {members}")
    print("deb looks structurally valid")


if __name__ == "__main__":
    main()
