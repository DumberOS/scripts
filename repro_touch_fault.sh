#!/bin/bash

adb logcat -c

while true; do
	echo "Locking"
	adb shell input keyevent 223
	sleep 1
	echo "Checking for very early error"
	adb logcat -d | grep 'Bus abnormal'
	if [ "$?" = "0" ]; then
		echo "Very early error"
	fi
	sleep 12
	echo "Checking for error before unlocking"
	adb logcat -d | grep 'Bus abnormal'
	if [ "$?" = "0" ]; then
		echo "Error before unlocking"
	fi
	echo "Unlocking"
	adb shell input keyevent 224
	echo "Checking for early error"
	adb logcat -d | grep 'Bus abnormal'
	if [ "$?" = "0" ]; then
		echo "Early error"
	fi
	sleep 1
	echo "Swiping"
	adb shell input swipe 240 560 240 120 150
	if [ "`adb shell cat /sys/class/leds/lcd-backlight/brightness`" = "0" ]; then
		echo "Backlight is broken"
		break;
	fi
	sleep 1
	echo "Checking for error"
	adb logcat -d | grep 'Bus abnormal'
	if [ "$?" = "0" ]; then
		echo "Touchscreen is broken"
#		break;
	fi
done
