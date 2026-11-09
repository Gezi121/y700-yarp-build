"""Apply the TB322FC startup contract to the pinned upstream recovery source.

Exact anchors and a final marker check make source drift a build failure.
"""
from pathlib import Path
import sys


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Expected one source anchor, found {text.count(old)}: {old[:90]!r}")
    return text.replace(old, new, 1)

SUPER_WAIT_HAL = (
    '  if (const auto module = BootControlClient::WaitForService()) {\n'
    '    super_device = fs_mgr_get_super_partition_name(module->GetCurrentSlot());\n'
    '  } else {\n'
    '    // No boot control HAL is available.\n'
    '    LOGINFO("Boot control HAL unavailable, using static super partition path\\n");\n'
    '  }\n'
)

# ProcessFstab asks for the super partition name before it mounts anything, and
# BootControlClient::WaitForService() has no timeout. Recovery does not import
# /vendor/etc/init, so the vendor boot HAL (class early_hal) is never registered
# and startup stopped dead at "Processing /etc/recovery.fstab" until the service
# was started by hand. Name the partition from the boot slot instead, which is
# what fs_mgr_get_super_partition_name() derives the name from anyway.
SUPER_WAIT_HAL_REPLACEMENT = (
    '  // TB322FC: name super from the boot slot, not the boot HAL.\n'
    '  const std::string named_super = android::base::GetProperty("ro.boot.super_partition", "");\n'
    '  const std::string slot_suffix = android::base::GetProperty("ro.boot.slot_suffix", "");\n'
    '  if (!named_super.empty()) {\n'
    '    super_device = named_super;\n'
    '  } else if (!slot_suffix.empty() &&\n'
    '             access(GetByNamePath("super" + slot_suffix).c_str(), F_OK) == 0) {\n'
    '    super_device = "super" + slot_suffix;\n'
    '  } else {\n'
    '    LOGINFO("No boot control HAL; using the static super partition path\\n");\n'
    '  }\n'
)


def patch_super_partition(text):
    if "// TB322FC: name super from the boot slot" in text:
        return text
    return replace_once(text, SUPER_WAIT_HAL, SUPER_WAIT_HAL_REPLACEMENT)


def patch(root):
    path = root / "bootable/recovery/partitionmanager.cpp"
    text = patch_super_partition(path.read_text(encoding="utf-8"))
    marker = "// TB322FC: SPU readiness contract v1"
    if marker in text:
        if "// TB322FC: defer early DE calls" not in (root / "bootable/recovery/partition.cpp").read_text(encoding="utf-8"):
            raise RuntimeError("Incomplete previous patch: early DE guard is missing")
        if "// TB322FC: inspect the selected user" not in (root / "system/vold/Decrypt.cpp").read_text(encoding="utf-8"):
            raise RuntimeError("Incomplete previous patch: per-user SP dispatch is missing")
        # The super-partition fix above may be newer than the rest of the set.
        path.write_text(text, encoding="utf-8", newline="\n")
        print("SPU startup contract already installed")
        return
    # Replace the whole small function: this also removes the old PATCH 5,
    # which incorrectly passed arbitrary text as a GUI2 translation key.
    start = text.index("void TWPartitionManager::DecryptData() {")
    end = text.index("\nvoid TWPartitionManager::SetupSettingsStoragePartition", start)
    old = text[start:end]
    new = (Path(__file__).with_name("decrypt-data.cpp.in")).read_text(encoding="utf-8")
    text = text[:start] + new.rstrip() + "\n" + text[end:]
    # Mount cleanup is already complete at DecryptData; module probing is in
    # ProcessFstab, before SetupFstabPartitions. No wait in either earlier hook.
    if "KernelModuleLoader::LoadVendorModules();" not in text or '"twrp.storage.ready", "1"' not in text:
        raise RuntimeError("Upstream startup no longer guarantees module loading/mount cleanup")
    # Manual GUI attempts must also recover metadata first after a preparation
    # failure, rather than treating a locked FBE partition as legacy FDE.
    anchor = "  SetCryptoState();\n\n  // is_fbe_ survives DE failure even when the UI flag has been cleared."
    text = replace_once(text, anchor,
        '  if (access("/system/bin/fox_spu_bringup.sh", F_OK) == 0) {\n'
        '    TWPartition* locked = FindPartitionByPath("/data");\n'
        '    if (locked && !locked->key_directory_.empty() &&\n'
        '        (!locked->is_fbe_ ||\n'
        '         !android::base::GetBoolProperty("twrp.spu.ready", false))) {\n'
        '      DecryptData();\n'
        '      if (!locked->is_fbe_ ||\n'
        '          !android::base::GetBoolProperty("twrp.spu.ready", false)) return -1;\n'
        '    }\n'
        '  }\n\n' + anchor)
    if old.count("fscrypt_mount_metadata_encrypted") != 1:
        raise RuntimeError("Unexpected upstream metadata path")
    # A surviving device-mapper mapping can make PartitionPostProcessing call
    # DecryptFbeDe BEFORE DecryptData. Never enter secure calls through that
    # earlier path while the readiness contract has not completed.
    part_path = root / "bootable/recovery/partition.cpp"
    part = part_path.read_text(encoding="utf-8")
    part = replace_once(part,
        "bool TWPartition::DecryptFbeDe() {\n",
        'bool TWPartition::DecryptFbeDe() {\n'
        '  // TB322FC: defer early DE calls until secure services are ready.\n'
        '  if (access("/system/bin/fox_spu_bringup.sh", F_OK) == 0 &&\n'
        '      !android::base::GetBoolProperty("twrp.spu.ready", false)) {\n'
        '    is_decrypted_ = false;\n'
        '    DataManager::SetValue(TW_IS_DECRYPTED, 0);\n'
        '    DataManager::SetValue(TW_IS_ENCRYPTED, 1);\n'
        '    return false;\n'
        '  }\n')
    # Upstream selected the synthetic-password path for ALL users using user
    # zero's directory. Test this user's protector directory instead, so mixed
    # legacy/SP multiuser storage is dispatched to the correct existing path.
    vold_path = root / "system/vold/Decrypt.cpp"
    vold = vold_path.read_text(encoding="utf-8")
    vold = replace_once(vold,
        '    if (stat("/data/system_de/0/spblob", &st) == 0) {\n',
        '    // TB322FC: inspect the selected user, not user zero.\n'
        '    const std::string user_spblob =\n'
        '            "/data/system_de/" + std::to_string(user_id) + "/spblob";\n'
        '    if (stat(user_spblob.c_str(), &st) == 0) {\n')
    vold_path.write_text(vold, encoding="utf-8", newline="\n")
    part_path.write_text(part, encoding="utf-8", newline="\n")
    path.write_text(text, encoding="utf-8", newline="\n")
    # Only the user-triggered slot switch may still ask for the boot HAL.
    if "// TB322FC: name super from the boot slot" not in text:
        raise RuntimeError("Super partition naming fix is missing")
    if text.count("BootControlClient::WaitForService") != 1:
        raise RuntimeError("Startup still waits for the boot HAL")
    print("Installed SPU startup contract and manual metadata retry")


if __name__ == "__main__":
    patch(Path(sys.argv[1]))
