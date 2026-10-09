#!/system/bin/sh
# Don't read the host control console.
exec </dev/null
# Startup diagnostics: runs the Vulkan self-test even if boot never completes.
sleep 35
echo VM_VULKAN_STARTUP_BEGIN
getprop sys.boot_completed
getprop init.svc.surfaceflinger
getprop init.svc.zygote
getprop init.svc.bootanim
getprop ro.hardware.vulkan
ps -A -o PID,PPID,STAT,WCHAN,NAME | grep -E 'surfaceflinger|system_server|zygote|composer|allocator|bootanim|vulkan'
logcat -d -b all -t 1200 -v threadtime '*:E' | grep -E -i 'vulkan|venus|EGL|gralloc|SurfaceFlinger|RenderEngine|shader|fence|avc: denied|linker' | tail -100
timeout 25 /vendor/bin/vm-vulkan-probe
echo VM_VULKAN_PROBE_EXIT=$?
timeout 25 /vendor/bin/vm-vulkan-probe --ahb
echo VM_AHB_PROBE_EXIT=$?
timeout 25 /vendor/bin/vm-vulkan-probe --ahb-render
echo VM_AHB_RENDER_PROBE_EXIT=$?
logcat -d -b all -t 1500 -v threadtime | grep -E -i 'MESA-VIRTIO|venus|vulkan|avc: denied' | tail -100
dumpsys -t 5 SurfaceFlinger | grep -E 'GLES|EGL|Vulkan|RenderEngine|Composition'
echo VM_VULKAN_STARTUP_END
