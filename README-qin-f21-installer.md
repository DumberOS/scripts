# Guarded Qin F21 Pro installer

`install_qin_f21_pro.sh` validates a connected phone and DumberOS release before
flashing. Its supported scope is intentionally narrow: the Qin F21 Pro 4 GB RAM
/ 64 GB eMMC GMS variant with vendor product `full_k61v1_64_gms`, device
`k61v1_64_bsp`, and VNDK 30.

It does not unlock the bootloader or create a recovery backup. Follow the
[Qin/Doov hacking guide](https://github.com/xsmh/qin-doov-hacking) first and do
not use flash mode until the stock backup for that exact phone has been
verified.

## Requirements

- Linux with Bash, ADB, fastboot, OpenSSL, e2fsprogs (`debugfs` and `tune2fs`),
  and standard GNU command-line tools
- an already-unlocked, bootable phone with USB debugging authorized
- the uncompressed DumberOS `gapps30` or `vanilla30` `.img`
- its matching `.img.sig` release asset

The default invocation performs read-only preflight checks:

```bash
./install_qin_f21_pro.sh \
  --image dumber_os-YYYYMMDD-gapps30-signed.img \
  --signature dumber_os-YYYYMMDD-gapps30-signed.img.sig
```

To migrate from stock, flash mode requires a data wipe:

```bash
./install_qin_f21_pro.sh \
  --image dumber_os-YYYYMMDD-gapps30-signed.img \
  --signature dumber_os-YYYYMMDD-gapps30-signed.img.sig \
  --flash --wipe
```

For a later DumberOS-to-DumberOS system update, omit `--wipe` to retain data.
Make a current data backup first even though the script does not erase it.

Before any mutation, the script verifies the official RSA release signature,
checks the ext filesystem and embedded build properties, identifies the exact
vendor/hardware/storage variant, confirms the bootloader is unlocked, checks
the active slot again in bootloader fastboot and fastbootd, and requires a typed
confirmation. It targets only the active logical `system` partition. If extra
space is required and a safe resize is not possible, it stops without deleting
another logical partition. The Qin/Doov guide documents manual recovery and
layout options for that case.

The script never flashes physical `super`, boot, vbmeta, vendor, modem,
preloader, NVRAM, NVDATA, or calibration partitions.

The bundled public key is byte-for-byte identical to
`DumberOSUpdater/res/raw/pubkey.pem` (SHA-256
`6daf2d0af65df3562ffe196b515b9cec0447ae3778c09765b2478cbcf2e61776`). If the
release signing key is rotated, both copies must be updated together.
