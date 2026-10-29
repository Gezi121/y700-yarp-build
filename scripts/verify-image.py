"""Check the built recovery container and its staged YARP runtime resources."""

import hashlib
import json
from pathlib import Path
import struct
import sys


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    product = Path(sys.argv[1])
    image = product / "recovery.img"
    data = image.read_bytes()
    require(len(data) >= 4096, "Recovery image is truncated")
    require(data[:8] == b"ANDROID!", "Missing Android boot image magic")
    kernel_size, ramdisk_size, os_version, header_size = struct.unpack_from("<4I", data, 8)
    header_version = struct.unpack_from("<I", data, 40)[0]
    require(header_version == 4, f"Unexpected boot header version: {header_version}")
    require(header_size == 1584, f"Unexpected v4 header size: {header_size}")
    require(kernel_size == 0, "Recovery is expected to be ramdisk-only")
    require(0 < ramdisk_size <= len(data) - 4096, "Invalid ramdisk size")
    require(len(data) <= 104857600, "Recovery exceeds the 100 MiB partition size")
    require(data[4096:4100] in (b"\x02\x21\x4c\x18", b"\x04\x22\x4d\x18"),
            "Expected an LZ4-compressed recovery ramdisk")

    root = product / "recovery/root"
    candidates = [root / "system/bin/recovery", root / "sbin/recovery"]
    executable = next((candidate for candidate in candidates if candidate.is_file()), None)
    require(executable is not None, "Missing staged recovery executable")
    binary = executable.read_bytes()
    require(binary[:4] == b"\x7fELF" and len(binary) > 20, "Recovery is not an ELF executable")
    require(struct.unpack_from("<H", binary, 18)[0] == 183, "Recovery is not AArch64")
    require(b"Yet Another Recovery Project" in binary, "YARP language resources are missing")
    require(b"gui2" in binary.lower(), "GUI2 runtime markers are missing")
    fonts = ["wqy-microhei.ttf", "DroidSansMono.ttf"]
    for font in fonts:
        path = root / "twres/fonts" / font
        require(path.is_file() and path.stat().st_size > 0, f"Missing GUI2 font: {font}")
    report = {
        "sha256": hashlib.sha256(data).hexdigest(),
        "image_bytes": len(data), "header_version": header_version,
        "header_size": header_size, "kernel_bytes": kernel_size,
        "ramdisk_bytes": ramdisk_size, "ramdisk_compression": "lz4",
        "encoded_os_version": os_version,
        "recovery_architecture": "aarch64", "yarp_resources": True,
        "gui2_fonts": fonts,
        "validation_scope": "Build and static checks only; on-device boot and decryption are untested."
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
