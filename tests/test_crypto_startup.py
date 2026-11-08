"""Run the real device scripts in a disposable Linux chroot with mocked hardware.

Usage (root; mksh and busybox-static installed):
  python3 tests/test_crypto_startup.py /path/to/device/tree
No Android device or real block device is accessed.
"""
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

DEVICE = Path(sys.argv.pop(1)).resolve()

MOCK = r'''#!/system/bin/sh
cmd=${0##*/}
prop() { cat "/props/$1" 2>/dev/null; }
case "$cmd" in
 getprop) prop "$1" ;;
 resetprop) echo "$2" > "/props/$1" ;;
 setprop)
   echo "$*" >> /calls
   case "$1" in
     ctl.start)
       if [ "$2" = vendor.spdaemon ] && [ "$(prop init.svc.vendor.spdaemon)" != running ]; then
         count=$(cat /spdaemon_count); echo $((count + 1)) > /spdaemon_count
       fi
       echo running > "/props/init.svc.$2" ;;
     ctl.stop) echo stopped > "/props/init.svc.$2" ;;
     *) echo "$2" > "/props/$1" ;;
   esac ;;
 sleep)
   n=$(cut -d. -f1 /proc/uptime); echo "$((n + 1)).00 0.00" > /proc/uptime ;;
 mount)
   for last do :; done
   case "$last" in
     /firmware) dev=/dev/block/by-name/modem_b; type=vfat ;;
     /persist)
       [ -f /fail_persist ] && exit 1
       dev=/dev/block/by-name/persist; type=ext4 ;;
     /mnt/vendor/persist) dev=/dev/block/by-name/persist; type=ext4 ;;
     /mnt/vendor/spunvm) dev=/dev/block/by-name/spunvm; type=vfat ;;
     /tmp/fox-vendor-probe|/tmp/fox-keymint-props/vendor)
       cp /stock-vendor.prop "$last/build.prop"
       dev=/dev/block/mapper/vendor_b; type=erofs ;;
     /tmp/fox-keymint-props/system)
       mkdir -p "$last/system"; cp /stock-system.prop "$last/system/build.prop"
       dev=/dev/block/mapper/system_b; type=erofs ;;
     *) exit 1 ;;
   esac
   echo "$dev $last $type rw 0 0" >> /proc/mounts ;;
 umount)
   awk -v dst="$1" '$2 != dst' /proc/mounts > /tmp/mounts
   cat /tmp/mounts > /proc/mounts ;;
 pidof) echo "$(($(cat /spdaemon_count) + 400))" ;;
 logcat)
   echo "logcat $*" >> /calls
   [ -f /fail_spdaemon ] && { echo 'going to sleep for a day'; exit 0; }
   [ -f /retry_spdaemon ] && [ "$(cat /spdaemon_count)" = 1 ] && { echo 'going to sleep for a day'; exit 0; }
   echo 'SP Apps were loaded successfully' ;;
 fox_spu_check)
   if [ -f /fail_interfaces ]; then echo 'missing: android.hardware.weaver.IWeaver/default'; exit 1; fi ;;
esac
'''


class Startup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="yarp-crypto-test-")
        self.root = Path(self.tmp.name)
        for name in ["bin", "system/bin", "vendor/bin/hw", "dev/block/by-name",
                     "dev/block/mapper", "dev/dma_heap", "proc", "props", "tmp",
                     "firmware/image", "mnt/vendor", "persist"]:
            (self.root / name).mkdir(parents=True, exist_ok=True)
        shutil.copy2("/usr/bin/busybox", self.root / "bin/busybox")
        shutil.copy2("/bin/mksh", self.root / "system/bin/sh")
        for line in subprocess.check_output(["ldd", "/bin/mksh"], text=True).splitlines():
            for token in line.split():
                if token.startswith("/") and Path(token).is_file():
                    dst = self.root / token.lstrip("/")
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(token, dst)
        for cmd in ["awk", "cat", "cut", "mkdir", "rmdir", "chmod", "chown",
                    "readlink", "grep", "ln", "cp"]:
            (self.root / "bin" / cmd).symlink_to("busybox")
        for cmd in ["getprop", "setprop", "resetprop", "sleep", "mount", "umount",
                    "pidof", "logcat"]:
            self.write("bin/" + cmd, MOCK, executable=True)
        self.write("system/bin/fox_spu_check", MOCK, executable=True)
        for name in ["fox_spu_bringup.sh", "fox_crypto_select.sh"]:
            shutil.copy2(DEVICE / "recovery/root/system/bin" / name, self.root / "system/bin" / name)
        shutil.copy2(DEVICE / "recovery/root/vendor/bin/prepdecrypt.sh", self.root / "vendor/bin/prepdecrypt.sh")
        for name in ["spdaemon", "sec_nvm", "hw/android.hardware.security.keymint-service-qti",
                     "hw/android.hardware.security.keymint-service-spu-qti",
                     "hw/android.hardware.weaver-service-spu-qti",
                     "hw/android.hardware.gatekeeper-service-spu-qti",
                     "hw/android.hardware.gatekeeper-service-qti"]:
            self.write("vendor/bin/" + name, "payload")
        self.write("proc/uptime", "10.00 0.00\n")
        self.write("proc/mounts", "")
        self.write("spdaemon_count", "0")
        self.write("stock-vendor.prop", "vendor.gatekeeper.is_security_level_spu=1\nro.vendor.build.security_patch=2026-06-01\n")
        self.write("stock-system.prop", "ro.build.version.release=17\nro.build.version.security_patch=2026-10-01\n")
        for name in ["macch1p.sig", "spu_rpmb.mbn"]:
            self.write("firmware/image/" + name, "firmware")
        for name in ["by-name/modem_b", "by-name/modem_a", "by-name/persist",
                     "by-name/spunvm", "mapper/vendor_b", "mapper/system_b"]:
            os.mknod(self.root / "dev/block" / name, stat.S_IFBLK | 0o600, os.makedev(240, 1))
        for name in ["spcom", "sp_kernel", "null"]:
            os.mknod(self.root / "dev" / name, stat.S_IFCHR | 0o666, os.makedev(1, 3))
        for key, val in {"twrp.storage.ready": "1", "twrp.modules.loaded": "true",
                         "ro.boot.slot_suffix": "_b", "ro.twrp.fastbootd": "0",
                         "vendor.gatekeeper.is_security_level_spu": "1",
                         "ro.build.version.release": "99.87.36",
                         "ro.build.version.security_patch": "2099-12-31",
                         "ro.vendor.build.security_patch": "2099-12-31"}.items():
            self.prop(key, val)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, text, executable=False):
        path = self.root / name
        path.write_text(text)
        if executable:
            path.chmod(0o755)

    def prop(self, key, value):
        self.write("props/" + key, value)

    def run_script(self, script="fox_spu_bringup.sh", success=True):
        result = subprocess.run(["/usr/sbin/chroot", str(self.root), "/system/bin/sh", "/system/bin/" + script],
                                env={"PATH": "/bin:/system/bin"}, capture_output=True, text=True, timeout=10)
        log = (self.root / "tmp/fox_spu.log").read_text() if (self.root / "tmp/fox_spu.log").exists() else result.stdout
        self.assertEqual(result.returncode == 0, success, log + result.stderr)
        calls = (self.root / "calls").read_text() if (self.root / "calls").exists() else ""
        self.assertNotIn("ctl.restart", calls)
        self.assertNotIn("logcat -c", calls)
        return log, calls

    def test_active_b_slot_success(self):
        _, calls = self.run_script()
        self.assertEqual((self.root / "props/twrp.spu.ready").read_text().strip(), "true")
        self.assertIn("modem_b /firmware", (self.root / "proc/mounts").read_text())
        self.assertIn("ctl.start vendor.gatekeeper_spu", calls)
        self.assertNotIn("ctl.start vendor.gatekeeper_default", calls)
        self.assertIn("--pid=401", calls)

    def test_fastboot_does_not_start_crypto(self):
        self.prop("ro.twrp.fastbootd", "1")
        _, calls = self.run_script()
        self.assertNotIn("ctl.start", calls)

    def test_slot_property_fallback(self):
        self.prop("ro.boot.slot_suffix", "")
        self.prop("ro.boot.slot", "b")
        self.run_script()

    def test_missing_b_does_not_use_a(self):
        (self.root / "dev/block/by-name/modem_b").unlink()
        log, calls = self.run_script(success=False)
        self.assertIn("active-slot modem", log)
        self.assertNotIn("ctl.start", calls)

    def test_persist_mount_failure_is_not_directory_readiness(self):
        self.write("fail_persist", "1")
        self.run_script(success=False)
        self.assertFalse((self.root / "persist/secnvm").exists())

    def test_wrong_firmware_mount_is_rejected(self):
        self.write("proc/mounts", "/dev/block/by-name/modem_a /firmware vfat ro 0 0\n")
        self.run_script(success=False)

    def test_missing_firmware_fails_before_daemons(self):
        (self.root / "firmware/image/spu_rpmb.mbn").unlink()
        _, calls = self.run_script(success=False)
        self.assertNotIn("ctl.start", calls)

    def test_failed_apps_do_not_start_keymint(self):
        self.write("fail_spdaemon", "1")
        _, calls = self.run_script(success=False)
        self.assertNotIn("ctl.start vendor.keymint", calls)
        self.assertEqual((self.root / "spdaemon_count").read_text().strip(), "2")

    def test_spdaemon_retry_uses_new_pid(self):
        self.write("retry_spdaemon", "1")
        _, calls = self.run_script()
        self.assertIn("--pid=401", calls)
        self.assertIn("--pid=402", calls)

    def test_missing_aidl_is_not_ready(self):
        self.write("fail_interfaces", "1")
        self.run_script(success=False)
        self.assertEqual((self.root / "props/twrp.spu.ready").read_text().strip(), "false")

    def test_stock_tee_gatekeeper_detected(self):
        self.write("stock-vendor.prop", "vendor.gatekeeper.is_security_level_spu=0\n")
        _, calls = self.run_script()
        self.assertIn("ctl.start vendor.gatekeeper_default", calls)
        self.assertNotIn("ctl.start vendor.gatekeeper_spu", calls)

    def test_unsupported_backend_fails(self):
        self.prop("twrp.crypto.gatekeeper", "nxp")
        self.run_script(success=False)

    def test_conflicting_gatekeeper_fails(self):
        self.prop("init.svc.vendor.gatekeeper_default", "running")
        self.run_script(success=False)

    def test_stock_environment_is_opt_in(self):
        self.run_script()
        self.assertEqual((self.root / "props/ro.build.version.security_patch").read_text().strip(), "2099-12-31")

    def test_explicit_stock_environment(self):
        self.prop("twrp.keymint.environment", "stock")
        self.run_script()
        self.assertEqual((self.root / "props/ro.build.version.release").read_text().strip(), "17")
        self.assertEqual((self.root / "props/ro.vendor.build.security_patch").read_text().strip(), "2026-06-01")

    def test_do_not_change_running_keymint_identity(self):
        self.prop("twrp.keymint.environment", "stock")
        self.prop("init.svc.vendor.keymint-qti", "running")
        self.run_script(success=False)


class InitContract(unittest.TestCase):
    def test_no_duplicate_or_invalid_init_sections(self):
        services = set()
        for path in (DEVICE / "recovery/root").rglob("*.rc"):
            if path.name == "ueventd.rc":
                continue
            section = False
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                if line[0].isspace():
                    self.assertTrue(section, f"{path}:{number}: command without section")
                    continue
                word = line.split()[0]
                self.assertIn(word, ["on", "service", "import"], f"{path}:{number}: {line}")
                section = word in ("on", "service")
                if word == "service":
                    name = line.split()[1]
                    self.assertNotIn(name, services, f"Duplicate service: {name}")
                    services.add(name)

    def test_spu_is_requested_and_disabled(self):
        text = (DEVICE / "recovery/root/init.recovery.qcom.rc").read_text()
        self.assertIn("on property:twrp.spu.requested=1\n    start fox_spu_bringup", text)
        self.assertEqual(text.count("start fox_spu_bringup"), 1)
        section = text.split("service fox_spu_bringup ", 1)[1].split("\non ", 1)[0]
        self.assertIn("\n    disabled\n", section)
        self.assertNotIn("fox_clear_bcb", text)
        self.assertNotIn("fox_spu_fallback", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
