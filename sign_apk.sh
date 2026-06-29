#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 <apk> [out_apk]" >&2
  echo "Env: APK_CERTS=... MISC_INFO=... APKSIGNER=... TARGET_PRODUCT=... KEY_DIR=..." >&2
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  usage
  exit 2
fi

APK=$1
OUT=${2:-signed.apk}

if [ ! -f "$APK" ]; then
  echo "APK not found: $APK" >&2
  exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APKSIGNER=${APKSIGNER:-"$ROOT/out/host/linux-x86/bin/apksigner"}
if [ ! -x "$APKSIGNER" ]; then
  echo "apksigner not found at $APKSIGNER (set APKSIGNER=...)" >&2
  exit 1
fi

target_product=${TARGET_PRODUCT:-}
APK_CERTS=${APK_CERTS:-}
if [ -z "$APK_CERTS" ]; then
  if [ -n "$target_product" ]; then
    APK_CERTS=$(ls -t \
      "$ROOT/out/target/product/$target_product"/obj/PACKAGING/target_files_intermediates/*/META/apkcerts.txt \
      "$ROOT/out/target/product/$target_product"/obj/PACKAGING/apkcerts.txt \
      "$ROOT/apkcerts.txt" 2>/dev/null | head -n 1)
  fi
  if [ -z "$APK_CERTS" ]; then
    APK_CERTS=$(ls -t \
      "$ROOT/out/target/product/"*/obj/PACKAGING/target_files_intermediates/*/META/apkcerts.txt \
      "$ROOT/out/target/product/"*/obj/PACKAGING/apkcerts.txt 2>/dev/null | head -n 1)
  fi
fi

if [ -z "$APK_CERTS" ] || [ ! -f "$APK_CERTS" ]; then
  echo "apkcerts.txt not found; set APK_CERTS=... or build target_files." >&2
  exit 1
fi

MISC_INFO=${MISC_INFO:-}
if [ -z "$MISC_INFO" ]; then
  meta_dir=$(dirname "$APK_CERTS")
  if [ -f "$meta_dir/misc_info.txt" ]; then
    MISC_INFO="$meta_dir/misc_info.txt"
  fi
fi
if [ -z "$MISC_INFO" ]; then
  if [ -n "$target_product" ]; then
    MISC_INFO=$(ls -t \
      "$ROOT/out/target/product/$target_product"/obj/PACKAGING/target_files_intermediates/*/META/misc_info.txt 2>/dev/null | head -n 1)
  fi
  if [ -z "$MISC_INFO" ]; then
    MISC_INFO=$(ls -t \
      "$ROOT/out/target/product/"*/obj/PACKAGING/target_files_intermediates/*/META/misc_info.txt 2>/dev/null | head -n 1)
  fi
fi

KEY_DIR=${KEY_DIR:-${ANDROID_CERTS:-}}
if [ -z "$KEY_DIR" ] && [ -d "$HOME/.android-certs" ]; then
  KEY_DIR="$HOME/.android-certs"
fi

DEV_CERT=
if [ -n "$MISC_INFO" ] && [ -f "$MISC_INFO" ]; then
  DEV_CERT=$(awk -F= '/^default_system_dev_certificate=/{print $2}' "$MISC_INFO")
fi
DEV_CERT=${DEV_CERT:-build/make/target/product/security/testkey}
DEV_KEY_DIR=$(dirname "$DEV_CERT")
case "$DEV_KEY_DIR" in
  "$ROOT"/*) DEV_KEY_DIR=${DEV_KEY_DIR#"$ROOT/"} ;;
esac

strip_key_ext() {
  echo "$1" | sed -e 's/\.x509\.pem$//' -e 's/\.pem$//' -e 's/\.pk8$//'
}

map_key_base() {
  base=$1
  if [ -n "$KEY_DIR" ] && [ -n "$DEV_KEY_DIR" ]; then
    case "$base" in
      "$DEV_KEY_DIR/testkey"|"$DEV_KEY_DIR/devkey")
        echo "$KEY_DIR/releasekey"
        return
        ;;
      "$DEV_KEY_DIR/media")
        echo "$KEY_DIR/media"
        return
        ;;
      "$DEV_KEY_DIR/shared")
        echo "$KEY_DIR/shared"
        return
        ;;
      "$DEV_KEY_DIR/platform")
        echo "$KEY_DIR/platform"
        return
        ;;
      "$DEV_KEY_DIR/networkstack")
        echo "$KEY_DIR/networkstack"
        return
        ;;
      "$DEV_KEY_DIR/sdk_sandbox")
        echo "$KEY_DIR/sdk_sandbox"
        return
        ;;
      "$DEV_KEY_DIR/bluetooth")
        echo "$KEY_DIR/bluetooth"
        return
        ;;
    esac
  fi
  echo "$base"
}

resolve_path() {
  case "$1" in
    /*) echo "$1" ;;
    *) echo "$ROOT/$1" ;;
  esac
}

APK_NAME=$(basename "$APK")
CERT=$(awk -v name="$APK_NAME" '$0 ~ "name=\""name"\"" {
  if (match($0, /certificate="[^"]+"/)) {
    print substr($0, RSTART + 13, RLENGTH - 14)
  }
  exit
}' "$APK_CERTS")
KEY=$(awk -v name="$APK_NAME" '$0 ~ "name=\""name"\"" {
  if (match($0, /private_key="[^"]+"/)) {
    print substr($0, RSTART + 13, RLENGTH - 14)
  }
  exit
}' "$APK_CERTS")

if [ -z "$CERT" ]; then
  echo "No signing entry for $APK_NAME in $APK_CERTS" >&2
  exit 1
fi

if [ "$CERT" = "PRESIGNED" ] || [ -z "$KEY" ]; then
  echo "$APK_NAME is marked PRESIGNED in $APK_CERTS; refusing to re-sign." >&2
  exit 1
fi

CERT_BASE=$(strip_key_ext "$CERT")
KEY_BASE=$(strip_key_ext "$KEY")
case "$CERT_BASE" in
  "$ROOT"/*) CERT_BASE=${CERT_BASE#"$ROOT/"} ;;
esac
case "$KEY_BASE" in
  "$ROOT"/*) KEY_BASE=${KEY_BASE#"$ROOT/"} ;;
esac

CERT_BASE=$(map_key_base "$CERT_BASE")
KEY_BASE=$(map_key_base "$KEY_BASE")

CERT_PATH=$(resolve_path "$CERT_BASE.x509.pem")
if [ ! -f "$CERT_PATH" ]; then
  CERT_PATH=$(resolve_path "$CERT_BASE.pem")
fi
KEY_PATH=$(resolve_path "$KEY_BASE.pk8")

if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
  echo "Signing key not found: cert=$CERT_PATH key=$KEY_PATH" >&2
  exit 1
fi

echo "Signing $APK_NAME using cert $(basename "$CERT_PATH") (apkcerts: $APK_CERTS)"
"$APKSIGNER" sign --key "$KEY_PATH" --cert "$CERT_PATH" \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out "$OUT" "$APK"
