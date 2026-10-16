#!/system/bin/sh
# Don't read the host control console.
exec </dev/null
# Diagnostic: dump Vulkan capabilities, then start Chrome once
# after boot and print its GPU-process log lines to the serial console.
sleep 50
/vendor/bin/vm-vulkan-probe --caps 2>&1 | grep -E 'VM_CAPS|= -'
n=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ $n -lt 60 ]; do sleep 3; n=$((n+1)); done
sleep 25
echo VM_CHROME_DIAG_BEGIN boot_completed=$(getprop sys.boot_completed)
logcat -c
am start --user current -n com.android.chrome/com.google.android.apps.chrome.Main
sleep 40
logcat -d -v threadtime | grep -E -i 'chromium|cr_|angle|MESA|vulkan|libEGL' | tail -250
echo VM_CHROME_DIAG_END
