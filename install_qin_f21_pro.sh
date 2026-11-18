#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PUBKEY="$SCRIPT_DIR/keys/dumberos_ota_pubkey.pem"

IMAGE=
SIGNATURE=
FLASH=false
WIPE=false
FASTBOOT_SERIAL=

usage() {
    cat <<'EOF'
Usage:
  install_qin_f21_pro.sh --image IMAGE --signature IMAGE.sig [--flash] [--wipe]

By default the script only validates the image and connected phone. It makes no
changes. Pass --flash to reboot an already-unlocked phone into fastbootd and
flash only its active logical system partition.

Options:
  --image PATH       Uncompressed DumberOS .img file (gapps30 or vanilla30)
  --signature PATH   Matching official .img.sig release asset
  --flash            Perform the flash after preflight and confirmation
  --wipe             Erase userdata and metadata (required when leaving stock)
  -h, --help         Show this help

Supported hardware is deliberately limited to the validated Qin F21 Pro 4/64
GB GMS variant: full_k61v1_64_gms / k61v1_64_bsp / VNDK 30.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

adb_prop() {
    adb -s "$ADB_SERIAL" shell getprop "$1" 2>/dev/null | tr -d '\r'
}

wait_for_fastboot() {
    local attempt
    local -a devices

    for ((attempt = 0; attempt < 60; attempt++)); do
        mapfile -t devices < <(fastboot devices 2>/dev/null | awk 'NF >= 1 {print $1}')
        if (( ${#devices[@]} == 1 )); then
            FASTBOOT_SERIAL=${devices[0]}
            return 0
        fi
        if (( ${#devices[@]} > 1 )); then
            die "More than one fastboot device is connected."
        fi
        sleep 1
    done

    die "Timed out waiting for the phone in fastboot mode."
}

fastboot_var() {
    local name=$1
    local output
    local value

    if ! output=$(fastboot -s "$FASTBOOT_SERIAL" getvar "$name" 2>&1); then
        printf '%s\n' "$output" >&2
        die "Could not read fastboot variable: $name"
    fi
    value=$(printf '%s\n' "$output" | tr -d '\r' |
        awk -F': ' -v key="$name" 'index($0, key ":") {value=$NF} END {print value}')
    [[ -n $value ]] || die "Fastboot returned no value for: $name"
    printf '%s\n' "$value"
}

parse_fastboot_size() {
    local value=${1,,}

    [[ $value =~ ^(0x[0-9a-f]+|[0-9]+)$ ]] || die "Invalid partition size: $1"
    printf '%d\n' "$((value))"
}

while (( $# > 0 )); do
    case $1 in
        --image)
            (( $# >= 2 )) || die "--image requires a path"
            IMAGE=$2
            shift 2
            ;;
        --signature)
            (( $# >= 2 )) || die "--signature requires a path"
            SIGNATURE=$2
            shift 2
            ;;
        --flash)
            FLASH=true
            shift
            ;;
        --wipe)
            WIPE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n $IMAGE ]] || die "--image is required"
[[ -n $SIGNATURE ]] || die "--signature is required"
[[ -f $IMAGE ]] || die "Image not found: $IMAGE"
[[ -f $SIGNATURE ]] || die "Signature not found: $SIGNATURE"
[[ -f $PUBKEY ]] || die "Bundled DumberOS public key not found: $PUBKEY"
if $WIPE && ! $FLASH; then
    die "--wipe is only valid together with --flash"
fi
case $IMAGE in
    *.gz) die "Extract the .img.gz first; do not flash or rename the compressed file." ;;
esac

for command in adb awk debugfs openssl sha256sum stat tr tune2fs; do
    need_command "$command"
done
if $FLASH; then
    need_command fastboot
    need_command sleep
fi

printf 'Verifying DumberOS release signature...\n'
openssl dgst -sha256 -verify "$PUBKEY" -signature "$SIGNATURE" "$IMAGE" >/dev/null ||
    die "The image does not match the official DumberOS signature."

IMAGE_SHA256=$(sha256sum "$IMAGE" | awk '{print $1}')
IMAGE_SIZE=$(stat -c '%s' "$IMAGE")
[[ $IMAGE_SIZE =~ ^[0-9]+$ ]] || die "Could not determine image size."
(( IMAGE_SIZE % 4096 == 0 )) || die "Image size is not aligned to 4096 bytes."
(( IMAGE_SIZE >= 1500000000 && IMAGE_SIZE <= 3800000000 )) ||
    die "Image size is outside the expected DumberOS range."

FS_INFO=$(tune2fs -l "$IMAGE" 2>/dev/null) ||
    die "The image is not an uncompressed ext filesystem."
FS_STATE=$(printf '%s\n' "$FS_INFO" |
    awk -F: '$1 == "Filesystem state" {sub(/^[[:space:]]+/, "", $2); print $2; exit}')
[[ $FS_STATE == clean ]] || die "Image filesystem is not marked clean: ${FS_STATE:-unknown}"

BUILD_PROP=$(debugfs -R 'cat /system/build.prop' "$IMAGE" 2>/dev/null) ||
    die "Could not read /system/build.prop from the image."
IMAGE_FLAVOR=$(printf '%s\n' "$BUILD_PROP" |
    awk -F= '$1 == "ro.build.flavor" {print $2; exit}')
IMAGE_FINGERPRINT=$(printf '%s\n' "$BUILD_PROP" |
    awk -F= '$1 == "ro.system.build.fingerprint" {print $2; exit}')
IMAGE_BRANCH=$(printf '%s\n' "$BUILD_PROP" |
    awk -F= '$1 == "ro.dumbdroid.branch" {print $2; exit}')
IMAGE_BUILD=$(printf '%s\n' "$BUILD_PROP" |
    awk -F= '$1 == "ro.system.build.date.utc" {print $2; exit}')

case $IMAGE_FLAVOR in
    lineage_gapps30-*|lineage_vanilla30-*) ;;
    *) die "Image is not a DumberOS VNDK 30 build: ${IMAGE_FLAVOR:-unknown}" ;;
esac
[[ $IMAGE_FINGERPRINT == *'/tdgsi_arm64_ab:'* ]] ||
    die "Image is not the expected arm64 A/B Treble GSI."
[[ $IMAGE_BRANCH == gapps || $IMAGE_BRANCH == vanilla ]] ||
    die "Image has an unexpected DumberOS branch: ${IMAGE_BRANCH:-unknown}"
[[ $IMAGE_FLAVOR == "lineage_${IMAGE_BRANCH}30-"* ]] ||
    die "Image flavor and DumberOS branch disagree."

mapfile -t ADB_DEVICES < <(adb devices | awk 'NR > 1 && $2 == "device" {print $1}')
(( ${#ADB_DEVICES[@]} == 1 )) ||
    die "Connect exactly one unlocked Android device with USB debugging authorized."
ADB_SERIAL=${ADB_DEVICES[0]}

VENDOR_NAME=$(adb_prop ro.product.vendor.name)
VENDOR_DEVICE=$(adb_prop ro.product.vendor.device)
VENDOR_MODEL=$(adb_prop ro.product.vendor.model)
VNDK=$(adb_prop ro.vndk.version)
DYNAMIC_PARTITIONS=$(adb_prop ro.boot.dynamic_partitions)
ABI=$(adb_prop ro.product.cpu.abi)
FLASH_LOCKED=$(adb_prop ro.boot.flash.locked)
SLOT_SUFFIX=$(adb_prop ro.boot.slot_suffix)
INSTALLED_BRANCH=$(adb_prop ro.dumbdroid.branch)
MEM_KIB=$(adb -s "$ADB_SERIAL" shell cat /proc/meminfo 2>/dev/null | tr -d '\r' |
    awk '$1 == "MemTotal:" {print $2; exit}')
EMMC_SECTORS=$(adb -s "$ADB_SERIAL" shell cat /sys/block/mmcblk0/size 2>/dev/null |
    tr -d '\r[:space:]')

[[ $VENDOR_NAME == full_k61v1_64_gms ]] ||
    die "Unsupported vendor product: ${VENDOR_NAME:-unknown}. Chinese/restricted variants are not accepted."
[[ $VENDOR_DEVICE == k61v1_64_bsp ]] ||
    die "Unsupported vendor device: ${VENDOR_DEVICE:-unknown}"
[[ $VENDOR_MODEL == 'F21 Pro' ]] || die "Unsupported model: ${VENDOR_MODEL:-unknown}"
[[ $VNDK == 30 ]] || die "The Qin F21 Pro requires a VNDK 30 image; device reports $VNDK."
[[ $DYNAMIC_PARTITIONS == true ]] || die "Dynamic partitions are not enabled on this phone."
[[ $ABI == arm64-v8a ]] || die "Unsupported primary ABI: ${ABI:-unknown}"
[[ $FLASH_LOCKED == 0 ]] || die "Bootloader is locked. This script does not unlock phones."
[[ $SLOT_SUFFIX == _a || $SLOT_SUFFIX == _b ]] ||
    die "Could not determine active A/B slot: ${SLOT_SUFFIX:-unknown}"
[[ $MEM_KIB =~ ^[0-9]+$ ]] || die "Could not determine installed RAM."
(( MEM_KIB >= 3500000 && MEM_KIB <= 4300000 )) ||
    die "Only the validated 4 GB F21 Pro revision is accepted (MemTotal: $MEM_KIB KiB)."
[[ $EMMC_SECTORS =~ ^[0-9]+$ ]] || die "Could not determine eMMC capacity."
(( EMMC_SECTORS >= 110000000 && EMMC_SECTORS <= 135000000 )) ||
    die "Only the validated 64 GB F21 Pro revision is accepted (sectors: $EMMC_SECTORS)."

ACTIVE_SLOT=${SLOT_SUFFIX#_}
TARGET_SYSTEM="system_${ACTIVE_SLOT}"
if [[ $INSTALLED_BRANCH == gapps || $INSTALLED_BRANCH == vanilla ]]; then
    CURRENT_OS="DumberOS ($INSTALLED_BRANCH)"
else
    CURRENT_OS="stock or another OS"
fi

printf '\nPreflight passed.\n'
printf '  Phone:       Qin F21 Pro 4/64 GB GMS (%s)\n' "$ADB_SERIAL"
printf '  Current OS:  %s\n' "$CURRENT_OS"
printf '  Active slot: %s\n' "$ACTIVE_SLOT"
printf '  Image:       %s\n' "$IMAGE"
printf '  Flavor:      %s\n' "$IMAGE_FLAVOR"
printf '  Build UTC:   %s\n' "${IMAGE_BUILD:-unknown}"
printf '  Size:        %s bytes\n' "$IMAGE_SIZE"
printf '  SHA-256:     %s\n' "$IMAGE_SHA256"
printf '  Signature:   verified with the bundled DumberOS release key\n'

if ! $FLASH; then
    printf '\nNo changes made. Re-run with --flash after making and verifying a stock backup.\n'
    exit 0
fi

if [[ $CURRENT_OS != DumberOS* ]] && ! $WIPE; then
    die "Leaving stock requires --wipe because its userdata is incompatible with DumberOS."
fi
[[ -t 0 ]] || die "Flash mode requires an interactive terminal."

cat <<EOF

The next step will reboot the phone and flash only $TARGET_SYSTEM. It will never
delete another logical partition or flash physical super, boot, vbmeta, vendor,
modem, preloader, or calibration partitions.

You must already have a verified stock backup for this exact phone. Keep the
cable connected and do not interrupt the flash.
EOF
if $WIPE; then
    printf '\nWARNING: userdata and metadata will be erased.\n'
else
    printf '\nUserdata and metadata will be retained.\n'
fi
printf '\nType exactly "FLASH QIN F21 PRO 4/64" to continue: '
read -r CONFIRMATION
[[ $CONFIRMATION == 'FLASH QIN F21 PRO 4/64' ]] || die "Confirmation did not match."

printf 'Rebooting to the bootloader...\n'
adb -s "$ADB_SERIAL" reboot bootloader
wait_for_fastboot
[[ $FASTBOOT_SERIAL == "$ADB_SERIAL" ]] ||
    die "Fastboot serial changed ($ADB_SERIAL -> $FASTBOOT_SERIAL); refusing to continue."

BOOTLOADER_UNLOCKED=$(fastboot_var unlocked)
[[ $BOOTLOADER_UNLOCKED == yes || $BOOTLOADER_UNLOCKED == true ]] ||
    die "Fastboot reports that the bootloader is locked."
BOOTLOADER_SLOT=$(fastboot_var current-slot)
[[ $BOOTLOADER_SLOT == "$ACTIVE_SLOT" ]] ||
    die "Active slot changed ($ACTIVE_SLOT -> $BOOTLOADER_SLOT); refusing to continue."

printf 'Rebooting to userspace fastboot (fastbootd)...\n'
fastboot -s "$FASTBOOT_SERIAL" reboot fastboot
FASTBOOT_SERIAL=
wait_for_fastboot
[[ $FASTBOOT_SERIAL == "$ADB_SERIAL" ]] ||
    die "Fastbootd serial changed ($ADB_SERIAL -> $FASTBOOT_SERIAL); refusing to continue."
[[ $(fastboot_var is-userspace) == yes ]] ||
    die "Phone is not in fastbootd. No partitions were changed."
[[ $(fastboot_var current-slot) == "$ACTIVE_SLOT" ]] ||
    die "Active slot changed in fastbootd. No partitions were changed."
[[ $(fastboot_var "is-logical:$TARGET_SYSTEM") == yes ]] ||
    die "$TARGET_SYSTEM is not a logical partition. Refusing to flash."

CURRENT_SYSTEM_SIZE=$(parse_fastboot_size "$(fastboot_var "partition-size:$TARGET_SYSTEM")")
if (( CURRENT_SYSTEM_SIZE < IMAGE_SIZE )); then
    printf 'Resizing %s from %s to %s bytes...\n' \
        "$TARGET_SYSTEM" "$CURRENT_SYSTEM_SIZE" "$IMAGE_SIZE"
    if ! fastboot -s "$FASTBOOT_SERIAL" resize-logical-partition \
            "$TARGET_SYSTEM" "$IMAGE_SIZE"; then
        die "Could not resize $TARGET_SYSTEM. No other partition was deleted; consult the Qin/Doov guide."
    fi
fi

if $WIPE; then
    printf 'Erasing userdata and metadata...\n'
    fastboot -s "$FASTBOOT_SERIAL" erase userdata
    fastboot -s "$FASTBOOT_SERIAL" erase metadata
fi

printf 'Flashing %s...\n' "$TARGET_SYSTEM"
fastboot -s "$FASTBOOT_SERIAL" flash "$TARGET_SYSTEM" "$IMAGE"
printf 'Flash completed successfully. Rebooting...\n'
fastboot -s "$FASTBOOT_SERIAL" reboot
