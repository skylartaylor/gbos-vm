#!/system/bin/sh
# Don't read the host control console.
exec </dev/null
# First-boot provisioning: mark the device set up and go straight to the desktop.
# Does not touch accounts, credentials, networking, device-owner or FRP state.
echo "VM_BOOT_COMPLETED uptime=$(cut -d' ' -f1 /proc/uptime)"
echo VM_OFFLINE_DESKTOP_BEGIN
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    vm_user=$(am get-current-user)
    case "$vm_user" in
        ''|*[!0-9]*|0) sleep 5 ;;
        *) break ;;
    esac
done
case "$vm_user" in
    ''|*[!0-9]*|0) echo VM_OFFLINE_DESKTOP_NO_FOREGROUND_USER; exit 1 ;;
esac
echo "VM_OFFLINE_DESKTOP_USER=$vm_user"
cmd package query-activities --brief --user "$vm_user" -a android.intent.action.MAIN -c android.intent.category.HOME
settings put global device_provisioned 1
settings --user 0 put secure user_setup_complete 1
settings --user "$vm_user" put secure user_setup_complete 1
pm disable-user --user "$vm_user" com.google.android.setupwizard
pm disable-user --user "$vm_user" com.google.android.desktop.setupwizard
svc power stayon true
am start --user "$vm_user" -a android.intent.action.MAIN -c android.intent.category.HOME -p com.google.android.apps.nexuslauncher
settings get global device_provisioned
settings --user "$vm_user" get secure user_setup_complete
echo "VM_OFFLINE_DESKTOP_END uptime=$(cut -d' ' -f1 /proc/uptime)"
