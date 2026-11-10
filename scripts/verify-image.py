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
    # gui2 branding lives in the gui2 shared library since the recovery-tip
    # link type change (libgui2.so), no longer in the main executable. Scan
    # the executable plus every staged shared library for the markers.
    scanned = {executable: binary}
    for lib in sorted(root.rglob("libgui2*.so")):
        scanned[lib] = lib.read_bytes()
    require(scanned, "No staged recovery binaries to scan")
    all_blobs = b"\n".join(scanned.values())
    require(b"Yet Another Recovery Project" in all_blobs,
            "YARP language resources are missing (scanned: "
            + ", ".join(str(p.relative_to(root)) for p in scanned) + ")")
    require(b"gui2" in all_blobs.lower(), "GUI2 runtime markers are missing")
    spu_script = (root / "system/bin/fox_spu_bringup.sh").read_text(encoding="utf-8")
    require("ctl.restart recovery" not in spu_script, "SPU script still restarts recovery")
    require("logcat -c" not in "\n".join(
        line for line in spu_script.splitlines() if not line.lstrip().startswith("#")),
        "SPU script destroys diagnostic logs")
    require("twrp.spu.macchiato" in spu_script,
            "SPU script lost the V4.1 macchiato rejection handling")
    require("macchiato=" in spu_script,
            "SPU script no longer reports the macchiato state in the ready/failure log")
    require(b"Preparing secure storage; see /tmp/fox_spu.log" in binary,
            "Recovery is missing the SPU readiness patch")
    require(b"Metadata key unlock failed; see recovery.log and fox_spu.log" in all_blobs,
            "Recovery is missing raw on-screen decrypt errors")
    require(b"No boot control HAL; using the static super partition path" in binary,
            "Recovery is missing the super partition naming fix")
    require(b"Boot control HAL unavailable, using static super partition path" not in binary,
            "Recovery still waits for the vendor boot HAL before fstab")
    probe = root / "system/bin/fox_spu_check"
    require(probe.is_file(), "Missing SPU AIDL publication checker")
    probe_bytes = probe.read_bytes()
    require(probe_bytes[:4] == b"\x7fELF" and
            struct.unpack_from("<H", probe_bytes, 18)[0] == 183,
            "SPU publication checker is not AArch64 ELF")
    for rel in ("system/bin/fox_spu_bringup.sh", "system/bin/fox_crypto_select.sh", "vendor/bin/prepdecrypt.sh"):
        require(b"\r" not in (root / rel).read_bytes(), f"CRLF shell script in ramdisk: {rel}")
    init_rc = (root / "init.recovery.qcom.rc").read_text(encoding="utf-8")
    require("fox_clear_bcb" not in init_rc and "ctl.restart recovery" not in init_rc,
            "Unsafe background BCB/recovery control remains in init")
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
        "spu_readiness_contract": True,
        "super_partition_naming": "boot slot properties",
        "spu_aidl_publication_checker": True,
        "automatic_recovery_restart": False,
        "validation_scope": "Build and static checks only; on-device boot and decryption are untested."
    }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
