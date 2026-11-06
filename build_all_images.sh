#!/bin/bash
# Keep explicit checks: sourced Android setup scripts can change shell options.
set -e

run() {
    local status
    if "$@"; then
        return 0
    else
        status=$?
        printf 'ERROR: %s failed (status %s); stopping before subsequent stages.\n' "$1" "$status" >&2
        exit "$status"
    fi
}

VARIANTS=("$@")
if [ "${#VARIANTS[@]}" -eq 0 ]; then
    VARIANTS=(vanilla30 vanilla31 gapps30 gapps31)
fi
for VARIANT in "${VARIANTS[@]}"; do
    case "$VARIANT" in
        vanilla30|vanilla31|gapps30|gapps31) ;;
        *) echo "Unsupported variant: $VARIANT" >&2; exit 2 ;;
    esac
done
BUILD_JOBS=${BUILD_JOBS:-2}
export NINJA_HIGHMEM_NUM_JOBS=${NINJA_HIGHMEM_NUM_JOBS:-1}
for count in "$BUILD_JOBS" "$NINJA_HIGHMEM_NUM_JOBS"; do
    if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
        echo 'Build job counts must be positive integers.' >&2
        exit 2
    fi
done

# Concurrent invocations share Android's product output and cannot be safe.
run mkdir -p "${OUT_DIR:-out}"
exec 9>"${OUT_DIR:-out}/.dumberos-image-build.lock" || exit 1
run flock -n 9

run source build/envsetup.sh
run bash packages/apps/Messaging/tools/prepare-dumber-chat.sh
OUTPUT_DIR=${BUILD_OUTPUT_DIR:-$HOME/build-output}
run mkdir -p "$OUTPUT_DIR"
BUILD_DATE=$(date -u +%Y%m%d)
STAGING=
ARCHIVE=
BACKUP=
cleanup() {
    local status=$?
    trap - EXIT
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        # Restore the last completed archive if building its replacement failed.
        mv -f -- "$BACKUP" "$ARCHIVE" || status=1
    fi
    if [ -n "$STAGING" ]; then
        rm -rf -- "$STAGING" || status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for VARIANT in "${VARIANTS[@]}"; do
    run lunch "lineage_${VARIANT}-ap2a-userdebug"
    if [ -z "${OUT:-}" ]; then
        echo 'lunch did not set OUT; refusing to build.' >&2
        exit 1
    fi
    ARCHIVE="$OUT/obj/PACKAGING/target_files_intermediates/lineage_${VARIANT}-target_files.zip"
    # Force packaging to run even if an old ZIP exists. Never sign that old ZIP.
    if [ -e "$ARCHIVE" ]; then
        BACKUP="${ARCHIVE}.previous.$$"
        run mv -- "$ARCHIVE" "$BACKUP"
    fi
    run make "-j$BUILD_JOBS" target-files-package
    if [ ! -s "$ARCHIVE" ]; then
        echo "Build did not produce $ARCHIVE; refusing to sign." >&2
        exit 1
    fi
    run python3 device/phh/treble/tests/audit_rom_compatibility.py --image-root "$OUT" \
        --aapt2 "${ANDROID_HOST_OUT:-out/host/linux-x86}/bin/aapt2"
    if [ -n "$BACKUP" ]; then
        run rm -- "$BACKUP"
        BACKUP=
    fi
    # Stage on the destination filesystem, then atomically publish the image.
    STAGING=$(mktemp -d "$OUTPUT_DIR/.${VARIANT}.XXXXXXXX") || exit 1
    run bash scripts/sign_target_files.sh "$STAGING/signed-target_files.zip" "$ARCHIVE"
    run unzip -joq "$STAGING/signed-target_files.zip" IMAGES/system.img -d "$STAGING"
    if [ ! -s "$STAGING/system.img" ]; then
        echo 'Signed archive did not contain a nonempty system.img.' >&2
        exit 1
    fi
    # The ZIP uses a reproducible timestamp; date the published file to this run.
    run touch "$STAGING/system.img"
    run mv -fT -- "$STAGING/system.img" "$OUTPUT_DIR/dumber_os-${BUILD_DATE}-${VARIANT}-signed.img"
    run rm -rf -- "$STAGING"
    STAGING=
    echo "Published $OUTPUT_DIR/dumber_os-${BUILD_DATE}-${VARIANT}-signed.img"
done
