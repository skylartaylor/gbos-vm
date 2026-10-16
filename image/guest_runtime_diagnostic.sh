#!/system/bin/sh
# Don't read the host control console.
exec </dev/null
# Read-only diagnostic that prints system state to the serial console and exits.
for pass in 1 2 3 4 5 6 7 8 9 10; do
    sleep 30
    echo VM_RUNTIME_BEGIN_$pass
    cat /proc/uptime /proc/pressure/memory /proc/pressure/cpu /proc/pressure/io
    grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree' /proc/meminfo
    getprop debug.hwui.use_partial_updates
    getprop debug.hwui.skip_empty_damage
    ip -brief address
    if [ "$pass" = 1 ]; then
        dumpsys -t 5 ethernet
        dumpsys -t 5 SurfaceFlinger | grep -E 'GLES|EGL|Composition|RenderEngine'
    fi
    dumpsys -t 5 activity exit-info com.android.settings
    dumpsys -t 5 activity exit-info com.android.chrome
    echo VM_RUNTIME_END_$pass
done
