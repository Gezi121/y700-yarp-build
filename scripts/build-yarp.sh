#!/usr/bin/env bash
set -euo pipefail

builder_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="${YARP_SOURCE_DIR:-/build/yarp}"
dist_root="${YARP_DIST_DIR:-${builder_root}/dist}"
lock_file="${builder_root}/sources.json"
mkdir -p "${source_root}" "${dist_root}"

case "${1:-}" in
  sync)
    cd "${source_root}"
    manifest_revision="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"]["revision"])' "${lock_file}")"
    repo init -u https://github.com/TWRP-Test/platform_manifest_twrp_aosp.git \
      -b "${manifest_revision}" --depth=1 --no-clone-bundle --no-tags
    python3 "${builder_root}/scripts/source-lock.py" overlay "${lock_file}" "${source_root}"
    repo sync -c -j "${SYNC_JOBS:-8}" --fail-fast --no-tags --no-clone-bundle \
      --optimized-fetch --retry-fetches=3
    python3 "${builder_root}/scripts/source-lock.py" verify "${lock_file}" "${source_root}"
    repo manifest -r -o "${dist_root}/source-manifest.xml"
    cp "${lock_file}" "${dist_root}/sources.json"
    git -C bootable/recovery diff --check
    df -h "${source_root}"
    du -sh .repo
    available_kib="$(df -Pk "${source_root}" | awk 'NR == 2 {print $4}')"
    if (( available_kib < 15 * 1024 * 1024 )); then
      echo '::error::Less than 15 GiB remains after source sync; refusing to fill the runner disk.'
      exit 1
    fi
    ;;

  patch)
    cd "${source_root}"
    # -------------------------------------------------------------------
    # PATCH 1 (critical): AOSP recovery builds ship servicemanager.recovery,
    # which links the VintfObjectRecovery stub. That stub returns an EMPTY
    # VINTF manifest, so servicemanager rejects registration of every AIDL
    # HAL ("Could not find ... in the VINTF manifest") and the HAL aborts
    # with SIGABRT. Dropping the package lets the full servicemanager (which
    # really reads /vendor/etc/vintf/manifest.xml) into the recovery image.
    # Same fix as MissMyTime/twrp_device_sm8850 (build_make patch).
    # -------------------------------------------------------------------
    python3 - <<'PY'
import sys
p = 'build/make/target/product/base_vendor.mk'
s = open(p).read()
if 'servicemanager.recovery' not in s:
    print('PATCH 1: servicemanager.recovery already absent; skip')
    sys.exit(0)
out = []
removed = 0
for line in s.splitlines(True):
    if line.strip() == 'servicemanager.recovery \\':
        removed += 1
        continue
    out.append(line)
open(p, 'w').write(''.join(out))
print('PATCH 1: removed servicemanager.recovery from base_vendor.mk (%d line)' % removed)
PY

    # -------------------------------------------------------------------
    # PATCH 2: vold's Weaver AIDL getConfig gives up after a single try.
    # The SPU weaver service only becomes ready after spdaemon/sec_nvm come
    # up, and vold usually asks earlier on a cold boot. Retry 80 x 250ms
    # (~20s) and validate keySize/valueSize like the reference tree does.
    # Same fix as MissMyTime/twrp_device_sm8850 (system_vold patch).
    # -------------------------------------------------------------------
    python3 - <<'PY'
import sys
p = 'system/vold/Weaver1.cpp'
s = open(p).read()
marker = '\t\tfor (int attempt = 0; attempt < 80; attempt++) {'
if marker in s:
    print('PATCH 2: weaver retry already present; skip')
    sys.exit(0)
old = (
    '\tif (mAidlDevice != nullptr) {\n'
    '\t\tauto r = mAidlDevice->getConfig(&aidlConfig);\n'
    '\t\tif (r.isOk()) {\n'
    '\t\t\tGottenConfig = true;\n'
    '\t\t\treturn true;\n'
    '\t\t}\n'
    '\t\treturn false;\n'
    '\t}'
)
new = (
    '\tif (mAidlDevice != nullptr) {\n'
    '\t\tfor (int attempt = 0; attempt < 80; attempt++) {\n'
    '\t\t\tauto r = mAidlDevice->getConfig(&aidlConfig);\n'
    '\t\t\tif (r.isOk() && aidlConfig.keySize > 0 && aidlConfig.valueSize > 0) {\n'
    '\t\t\t\tGottenConfig = true;\n'
    '\t\t\t\treturn true;\n'
    '\t\t\t}\n'
    '\t\t\tusleep(250000);\n'
    '\t\t}\n'
    '\t\treturn false;\n'
    '\t}'
)
if old not in s:
    print('PATCH 2: WARNING original weaver block not found; skipped (non-fatal)')
    sys.exit(0)
s = s.replace(old, new)
if '#include <unistd.h>' not in s:
    s = s.replace('#include <iostream>', '#include <iostream>\n#include <unistd.h>', 1)
open(p, 'w').write(s)
print('PATCH 2: applied weaver retry patch')
PY

    # -------------------------------------------------------------------
    # PATCH 3: GUI2 brings the display up exactly once. On this platform
    # /dev/dri/card0 (and the panel backlight node) only appear ~1-2 s after
    # init starts, so the first probe fails, gui2_start() returns
    # GUI2_EXIT_INITIALIZATION_FAILED and twrp.cpp keeps the legacy XML GUI
    # for the whole session (the device looked like plain TWRP 3.7.1).
    # Wait for both nodes, bounded, right before the UI/brightness probe.
    # -------------------------------------------------------------------
    python3 - <<'PY'
import sys
p = 'bootable/recovery/twrp.cpp'
s = open(p).read()
if 'Fox (Y700): the display stack shows up' in s:
    print('PATCH 3: display wait already present; skip')
    sys.exit(0)
old = (
    '\t// Load default values to set DataManager constants and handle ifdefs\n'
    '\tDataManager::SetDefaultValues();'
)
new = (
    '\t// Fox (Y700): the display stack shows up ~1-2 s after init starts.\n'
    '\t// GUI2 initializes DRM exactly once; if that open fails twrp.cpp keeps\n'
    '\t// the legacy XML GUI for the whole session, so probe it once ready.\n'
    '\tfor (int waited_ms = 0; waited_ms < 10000; waited_ms += 100) {\n'
    '\t\tif (access("/dev/dri/card0", F_OK) == 0 &&\n'
    '\t\t    access("/sys/class/backlight/panel0-backlight/brightness", F_OK) == 0)\n'
    '\t\t\tbreak;\n'
    '\t\tusleep(100000);\n'
    '\t}\n'
    '\n'
    '\t// Load default values to set DataManager constants and handle ifdefs\n'
    '\tDataManager::SetDefaultValues();'
)
if old not in s:
    print('PATCH 3: WARNING anchor not found; skipped (non-fatal)')
    sys.exit(0)
s = s.replace(old, new, 1)
open(p, 'w').write(s)
print('PATCH 3: applied display-ready wait patch')
PY

    # -------------------------------------------------------------------
    # PATCH 4: TWRP runs its only metadata-decrypt pass during startup, long
    # before fox_spu_bringup.sh has loaded sp_keymaster into the SPU, so the
    # wrapped key cannot be exported and /data stays locked. v1.6 handled that
    # by restarting the recovery process once the chain was up, which works but
    # costs a visible reload. Blocking the pass instead (v1.7) traded it for 80
    # seconds of blank UI - worse. So: hook the wait in, but keep it disabled by
    # default via twrp.spu_wait_ms, settable at runtime for A/B testing.
    # -------------------------------------------------------------------
    python3 - <<'PY'
import sys
p = 'bootable/recovery/partitionmanager.cpp'
s = open(p).read()
if 'Fox (Y700): wait for the SPU/TA chain' in s:
    print('PATCH 4: SPU wait already present; skip')
    sys.exit(0)
old = (
    'void TWPartitionManager::DecryptData() {\n'
    '#ifdef TW_INCLUDE_CRYPTO\n'
)
new = (
    'void TWPartitionManager::DecryptData() {\n'
    '#ifdef TW_INCLUDE_CRYPTO\n'
    '  // Fox (Y700): optionally wait for the SPU/TA chain before the one-shot\n'
    '  // metadata decrypt. The wrapped metadata key can only be exported once\n'
    '  // sp_keymaster is loaded into the SPU and the keymint HALs have\n'
    '  // registered; fox_spu_bringup.sh sets twrp.spu.ready when it is done.\n'
    '  // Default 0 = do not block: the UI comes up at once and the script\n'
    '  // restarts recovery only when /data is still locked (a visible reload).\n'
    '  // Raising twrp.spu_wait_ms trades that reload for a blocked decrypt\n'
    '  // page, which measured far worse on this device (80 s of blank UI).\n'
    '  if (TWFunc::IsPathExists("/dev/spcom")) {\n'
    '    const int spu_wait_ms =\n'
    '        android::base::GetIntProperty("twrp.spu_wait_ms", 0);\n'
    '    for (int waited = 0; waited * 500 < spu_wait_ms; ++waited) {\n'
    '      const std::string spu_state_ready =\n'
    '          android::base::GetProperty("twrp.spu.ready", "");\n'
    '      const std::string spu_state_failed =\n'
    '          android::base::GetProperty("twrp.spu.failed", "");\n'
    '      if (spu_state_ready == "true" || spu_state_failed == "true")\n'
    '        break;\n'
    '      LOGINFO("waiting for the SPU/TA chain before metadata decrypt (%d ms)\\n",\n'
    '              waited * 500);\n'
    '      usleep(500000);\n'
    '    }\n'
    '    LOGINFO("SPU/TA wait done: ready=\'%s\' failed=\'%s\'\\n",\n'
    '            android::base::GetProperty("twrp.spu.ready", "").c_str(),\n'
    '            android::base::GetProperty("twrp.spu.failed", "").c_str());\n'
    '  }\n'
)
if old not in s:
    print('PATCH 4: WARNING anchor not found; skipped (non-fatal)')
    sys.exit(0)
s = s.replace(old, new, 1)
open(p, 'w').write(s)
print('PATCH 4: applied SPU/TA ready wait before metadata decrypt')
PY
    echo '--- patches applied ---'
    ;;

  build)
    cd "${source_root}"
    # Y700 Gen4 builds a ramdisk-only recovery (v4 header, kernel_size=0),
    # so no external prebuilt kernel is required.
    export ALLOW_MISSING_DEPENDENCIES=true
    if [ -n "${CCACHE_DIR:-}" ]; then
      export USE_CCACHE=1
      ccache -M 8G
    else
      export USE_CCACHE=0
    fi
    export MALLOC_ARENA_MAX=2
    export SOONG_GOMEMLIMIT=8GiB
    export GOMEMLIMIT=8GiB
    export GOGC=50
    export GOMAXPROCS=2
    export SOONG_UI_NINJA_ARGS=-j1
    export NINJA_HIGHMEM_NUM_JOBS=1
    set +u
    source build/envsetup.sh
    lunch twrp_TB322FC-bp2a-eng
    mka -j"${BUILD_JOBS:-2}" installclean
    mka -j"${BUILD_JOBS:-2}" recoveryimage
    ;;

  package)
    product_root="${source_root}/out/target/product/TB322FC"
    python3 "${builder_root}/scripts/verify-image.py" "${product_root}" > "${dist_root}/verification.json"
    cp "${product_root}/recovery.img" "${dist_root}/YARP-TB322FC-recovery.img"
    cd "${dist_root}"
    sha256sum YARP-TB322FC-recovery.img > SHA256SUMS.txt
    cat verification.json
    ;;

  *)
    printf 'Usage: %s {sync|patch|build|package}\n' "$0" >&2
    exit 2
    ;;
esac
