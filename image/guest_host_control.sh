#!/system/bin/sh
# Fixed-verb control channel from the host over this VM's private serial
# console. Runs as shell; anything not listed below is ignored.
echo VM_CONTROL_READY
handle() {
  case "$line" in
    VM_POWEROFF) echo VM_CONTROL poweroff; setprop sys.powerctl shutdown ;;
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
      timeout 5 cat /proc/asound/cards 2>&1 | sed 's/^/VM_CONTROL asound /' ;;
    VM_BATTERY\ *)
      args="${line#VM_BATTERY }"
      level="${args%% *}"
      state="${args#* }"
      [ "$state" = "$args" ] && state="discharging"
      if [ -n "$level" ]; then
        if [ "$state" = "charging" ] || [ "$state" = "ac" ]; then
          cmd battery set ac 1
          cmd battery set status 2
        elif [ "$state" = "full" ]; then
          cmd battery set ac 1
          cmd battery set status 5
        else
          cmd battery unplug
          cmd battery set status 3
        fi
        cmd battery set level "$level"
        echo "VM_CONTROL battery level=$level state=$state"
      fi ;;
    VM_BATTERY_RESET)
      cmd battery reset
      echo "VM_CONTROL battery_reset" ;;
  esac
}
# Commands must not read the console, or they would swallow later verbs.
while IFS= read -r line; do
  line=${line%$'\r'}
  handle </dev/null
  echo VM_CONTROL done
done
