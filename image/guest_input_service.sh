#!/system/bin/sh
# Run the guest input helper as shell, the same way scrcpy runs its server.
# It only talks to the viewer on the host, over the VM's NAT link.
while true; do
  # Fresh copy each start.
  cp /vendor/etc/vm-input.jar /data/local/tmp/vm-input.jar || exit 1
  chmod 644 /data/local/tmp/vm-input.jar
  CLASSPATH=/data/local/tmp/vm-input.jar app_process /system/bin vm.Input 27183 </dev/null 2>&1 | grep --line-buffered VM_INPUT
  sleep 3
done
