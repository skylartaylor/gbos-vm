#!/system/bin/sh
# Fixed-verb control channel from the host over this VM's private serial
# console. Runs as shell; anything not listed below is ignored.
# VM_TOKEN carries a secret: don't echo it.
stty -echo 2>/dev/null
# Per boot token for the pointer helper. The host sends it once per boot, so keep it across
# service restarts and drop a stale one on the first start of a boot (kernel boot id).
TOKEN_FILE=/data/local/tmp/vm-input.token
BOOT_MARK=/data/local/tmp/vm-input.bootid
boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
if [ -z "$boot_id" ] || [ "$(cat "$BOOT_MARK" 2>/dev/null)" != "$boot_id" ]; then
  rm -f "$TOKEN_FILE"
  echo "$boot_id" >"$BOOT_MARK" 2>/dev/null || true
fi
echo VM_CONTROL_READY
handle() {
  case "$line" in
    VM_POWEROFF) echo VM_CONTROL poweroff; setprop sys.powerctl shutdown ;;
    VM_TOKEN\ *)
      t=${line#VM_TOKEN }; tok=${t%% *}; addr=${t#* }
      case "$tok" in *[!0-9a-f]*) return ;; esac
      [ ${#tok} -eq 32 ] || return
      case "$addr" in 10.0.2.2|10.0.2.100) ;; *) return ;; esac
      (umask 077; printf '%s\n%s\n' "$tok" "$addr" >"$TOKEN_FILE.new" && mv -f "$TOKEN_FILE.new" "$TOKEN_FILE") && echo "VM_CONTROL token set" ;;
    VM_PASTE\ *)
      printf %s "${line#VM_PASTE }" | base64 -d 2>/dev/null | while IFS= read -r t || [ -n "$t" ]; do
        [ -n "$t" ] && timeout 20 input text "$t"
        timeout 5 input keyevent 66
      done ;;
    VM_PASTE1\ *)
      t=$(printf %s "${line#VM_PASTE1 }" | base64 -d 2>/dev/null)
      [ -n "$t" ] && timeout 20 input text "$t" ;;
    VM_DENSITY\ [0-9][0-9][0-9])
      timeout 8 wm density "${line#VM_DENSITY }"
      echo "VM_CONTROL density $(timeout 5 wm density | tr '\n' ' ')" ;;
    VM_POINTER_ACCEL_OFF)
      u=$(timeout 5 am get-current-user)
      timeout 5 settings --user "$u" put system mouse_pointer_acceleration_enabled 0
      timeout 5 settings --user "$u" put system pointer_speed 0
      echo "VM_CONTROL accel=$(timeout 5 settings --user "$u" get system mouse_pointer_acceleration_enabled) speed=$(timeout 5 settings --user "$u" get system pointer_speed)" ;;
    VM_POINTER)
      timeout 6 dumpsys input 2>/dev/null | grep -i -E 'position|pointer[a-z ]*[xy]|x=|scale|accel|VelocityControl' | grep -v -i 'touch\|stylus' | head -24 | cut -c1-150 | sed 's/^/VM_CONTROL pointer /' ;;
    VM_POINTER_LOCATION\ [01])
      u=$(timeout 5 am get-current-user)
      timeout 5 settings --user "$u" put system pointer_location "${line#VM_POINTER_LOCATION }"
      echo "VM_CONTROL pointer_location=$(timeout 5 settings --user "$u" get system pointer_location)" ;;
    VM_AUDIO_DIAG)
      ls -l /dev/snd 2>&1 | sed 's/^/VM_CONTROL snd /'
      timeout 8 dumpsys media.audio_policy 2>/dev/null | grep -i -E 'HW Module|usb|Available (input|output)|- id:.*tag|Output [0-9]|Sampling rate|Devices' | head -50 | cut -c1-160 | sed 's/^/VM_CONTROL policy /'
      timeout 8 dumpsys media.audio_flinger 2>/dev/null | grep -i -E 'Output thread|Standby|Hal stream|usb|Frames written|Suspended|Master (mute|volume)' | head -30 | cut -c1-160 | sed 's/^/VM_CONTROL flinger /'
      timeout 8 logcat -d -t 3000 2>/dev/null | grep -i -E 'AHAL|alsa|usbaudio|UsbAlsa|audio_hw|pcm_|StreamUsb|ModuleUsb' | tail -40 | cut -c1-200 | sed 's/^/VM_CONTROL alog /'
      timeout 5 cmd audio help 2>&1 | head -25 | cut -c1-140 | sed 's/^/VM_CONTROL cmdaudio /'
      ls /product/media/audio/ringtones /system/media/audio/ringtones /product/media/audio/ui /system/media/audio/ui 2>/dev/null | head -12 | sed 's/^/VM_CONTROL media /' ;;
    VM_PLAY_TEST)
      u=$(timeout 5 am get-current-user)
      for f in /product/media/audio/ringtones/*.ogg /system/media/audio/ringtones/*.ogg /product/media/audio/alarms/*.ogg /system/media/audio/alarms/*.ogg; do [ -f "$f" ] && break; done
      echo "VM_CONTROL play $f"
      timeout 10 am start --user "$u" -a android.intent.action.VIEW -t audio/ogg -d "file://$f" 2>&1 | head -6 | sed 's/^/VM_CONTROL play /' ;;
    VM_STATUS)
      echo "VM_CONTROL boot=$(getprop sys.boot_completed) user=$(timeout 5 am get-current-user) size=$(timeout 5 wm size | tr '\n' ' ') density=$(timeout 5 wm density | tr '\n' ' ')"
      timeout 5 cat /proc/asound/cards 2>&1 | sed 's/^/VM_CONTROL asound /'
      echo "VM_CONTROL bluetooth feature=$(timeout 5 pm list features 2>/dev/null | grep -c 'hardware.bluetooth$') on=$(timeout 5 settings get global bluetooth_on) hal=$(getprop init.svc.vendor.bluetooth-aidl-qti) gscd=$(getprop init.svc.android.system.desktop.security.gscd)"
      timeout 6 dumpsys bluetooth_manager 2>/dev/null | grep -m4 -i -E '^ *(enabled|state|address|name):' | cut -c1-80 | sed 's/^/VM_CONTROL btmgr /' ;;
  esac
}
# Commands must not read the console, or they would swallow later verbs.
while IFS= read -r line; do
  line=${line%$'\r'}
  handle </dev/null
  echo VM_CONTROL done
done
