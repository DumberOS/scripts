#!/bin/bash

set -euo pipefail

fail() {
    echo "OTA failed: $*" >&2
    exit 1
}

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 IMAGE.img" >&2
    exit 1
fi
IMAGE=$1
[[ -f "$IMAGE" && -r "$IMAGE" && -s "$IMAGE" ]] || fail "Image must be a readable, nonempty file: $IMAGE"
IMAGE_SIZE=$(stat -c %s -- "$IMAGE")

get_property() {
    adb shell getprop "$1" | tr -d '\r\n'
}

read_slot() {
    adb shell 'if [ -e /metadata/phh/img ]; then cat /metadata/phh/img; else printf none; fi' | tr -d '\r\n'
}

require_idle() {
    local service state
    for service in phh-ota-make phh-ota-switch; do
        state=$(get_property "init.svc.$service")
        # Disabled oneshot services may have no state property until first run.
        # run_service still requires acknowledgment and an explicit stopped state.
        [[ -z "$state" || "$state" == stopped ]] || fail "$service is not idle (state: $state)"
    done
}

run_service() {
    local service=$1 error state
    local pending=push_ota_waiting_for_start
    # Adaptive preparation can take over an hour on a busy device.
    local deadline=$((SECONDS + 7200))

    require_idle
    # Both helpers clear this property on entry. This acknowledges startup even
    # if a quick service finishes between polls; a stale 'stopped' is not enough.
    adb shell setprop phh.ota.error "$pending"
    if [[ "$service" == phh-ota-make ]]; then
        adb shell setprop phh.ota.cancel false
    fi
    adb shell setprop ctl.start "$service"
    while (( SECONDS < deadline )); do
        error=$(get_property phh.ota.error)
        state=$(get_property "init.svc.$service")
        if [[ "$error" != "$pending" && "$state" == stopped ]]; then
            [[ -z "$error" ]] || fail "$service: $error"
            return
        fi
        sleep 1
    done
    fail "Timed out waiting for $service; the phone was not rebooted and the service may still be running"
}

adb root
adb wait-for-device
[[ "$(adb shell id -u | tr -d '\r\n')" == 0 ]] || fail "Root adb is required"
require_idle
CURRENT_SLOT=$(read_slot)
case "$CURRENT_SLOT" in
    a) EXPECTED_SLOT=b ;;
    b|none) EXPECTED_SLOT=a ;;
    *) fail "Invalid current slot: $CURRENT_SLOT" ;;
esac

echo "Preparing OTA image; this may take several minutes..."
run_service phh-ota-make

# Opening the device also catches stale device nodes left by a failed helper.
CAPACITY=$(adb shell blockdev --getsize64 /dev/phh-ota | tr -d '\r\n')
[[ "$CAPACITY" =~ ^[0-9]+$ ]] || fail "Could not read OTA device capacity"
(( IMAGE_SIZE <= CAPACITY )) || fail "Image is larger than the OTA device ($IMAGE_SIZE > $CAPACITY bytes)"

echo "Writing $IMAGE ($IMAGE_SIZE bytes)..."
# No staging file: stream raw image bytes, preserve adb's remote exit status,
# and wait for the block-device writes to reach storage before verification.
adb shell -T 'dd of=/dev/phh-ota bs=1048576 conv=fsync' < "$IMAGE"

[[ "$(read_slot)" == "$CURRENT_SLOT" ]] || fail "Slot changed during the upload"
echo "Verifying image and switching to slot $EXPECTED_SLOT..."
run_service phh-ota-switch
NEW_SLOT=$(read_slot)
[[ "$NEW_SLOT" == "$EXPECTED_SLOT" ]] || fail "Expected slot $EXPECTED_SLOT, got $NEW_SLOT"

echo "OTA ready on slot $NEW_SLOT. Rebooting in 10s..."
sleep 10
adb reboot
