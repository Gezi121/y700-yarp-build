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
  build)
    cd "${source_root}"
    # Y700 Gen4 为 ramdisk-only recovery（v4 header, kernel_size=0），
    # 直接使用 GKI 内核引导参数，无外部预编译内核依赖。
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
    printf 'Usage: %s {sync|build|package}\n' "$0" >&2
    exit 2
    ;;
esac
