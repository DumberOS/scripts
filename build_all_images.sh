#!/bin/sh

set -e
. build/envsetup.sh
mkdir -p ~/build-output
BUILD_DATE="$(date -u +%Y%m%d)"
for VARIANT in vanilla30 vanilla31 gapps30 gapps31; do
	lunch lineage_${VARIANT}-ap2a-userdebug
	DISABLE_STUB_VALIDATION=true make target-files-package
	bash scripts/sign_target_files.sh $OUT/signed-target_files.zip
	rm $OUT/system.img
	unzip -joq $OUT/signed-target_files.zip IMAGES/system.img -d $OUT
	cp $OUT/system.img ~/build-output/dumber_os-${BUILD_DATE}-${VARIANT}-signed.img
done
