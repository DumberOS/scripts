#!/bin/bash

CERT_DIR="$HOME/.android-certs"
mkdir -p "$CERT_DIR"

# Add core platform keys
CORE_KEYS=(
releasekey
platform
shared
media
networkstack
bluetooth
wifi
runtime
sdk_sandbox
)

# Full set from sign_target_files.sh
APEX_KEYS=(
com.android.adbd
com.android.adservices
com.android.adservices.api
com.android.appsearch
com.android.art
com.android.bluetooth
com.android.btservices
com.android.cellbroadcast
com.android.compos
com.android.configinfrastructure
com.android.connectivity.resources
com.android.conscrypt
com.android.devicelock
com.android.extservices
com.android.graphics.pdf
com.android.hardware.biometrics.face.virtual
com.android.hardware.biometrics.fingerprint.virtual
com.android.hardware.boot
com.android.hardware.cas
com.android.hardware.wifi
com.android.healthfitness
com.android.hotspot2.osulogin
com.android.i18n
com.android.ipsec
com.android.media
com.android.media.swcodec
com.android.mediaprovider
com.android.nearby.halfsheet
com.android.networkstack.tethering
com.android.neuralnetworks
com.android.ondevicepersonalization
com.android.os.statsd
com.android.permission
com.android.resolv
com.android.rkpd
com.android.runtime
com.android.safetycenter.resources
com.android.scheduling
com.android.sdkext
com.android.support.apexer
com.android.telephony
com.android.telephonymodules
com.android.tethering
com.android.tzdata
com.android.uwb
com.android.uwb.resources
com.android.virt
com.android.vndk.current
com.android.vndk.current.on_vendor
com.android.wifi
com.android.wifi.dialog
com.android.wifi.resources
com.google.pixel.camera.hal
com.google.pixel.vibrator.hal
com.qorvo.uwb
)

ALL_KEYS=("${CORE_KEYS[@]}" "${APEX_KEYS[@]}")

echo "Generating certificates in $CERT_DIR..."

for name in "${ALL_KEYS[@]}"; do
  echo "Generating key for $name..."

  # Private key in PEM
  openssl genrsa -out "$CERT_DIR/$name.pem" 4096

  # Public certificate
  openssl req -new -x509 -key "$CERT_DIR/$name.pem" \
    -out "$CERT_DIR/$name.x509.pem" \
    -days 10000 -subj "/CN=Android Key/0=$name"

  # Private key in PKCS#8
  openssl pkcs8 -topk8 -inform PEM -outform DER \
    -in "$CERT_DIR/$name.pem" \
    -out "$CERT_DIR/$name.pk8" -nocrypt
done

echo "✅ All keys generated successfully in $CERT_DIR."

