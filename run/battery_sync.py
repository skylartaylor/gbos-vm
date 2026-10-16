#!/usr/bin/env python3
"""Synchronize macOS battery status (percentage and charging state) to a running Googlebook VM.

Can be run as a background service, executed once from the command line, or imported by launch.py.

Usage:
    battery_sync.py RUN_DIR [--interval SECONDS] [--once]
"""
import argparse, ctypes, re, subprocess, sys, threading, time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vm_control

_iokit = None
_cf = None


def _init_iokit():
    global _iokit, _cf
    if _iokit is not None:
        return True
    try:
        _iokit = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/IOKit.framework/IOKit')
        _cf = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')

        _cf.CFRelease.argtypes = [ctypes.c_void_p]
        _cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        _cf.CFArrayGetCount.restype = ctypes.c_long
        _cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        _cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        _cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        _cf.CFDictionaryGetValue.restype = ctypes.c_void_p
        _cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        _cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        _cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
        _cf.CFStringGetCString.restype = ctypes.c_bool
        _cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        _cf.CFNumberGetValue.restype = ctypes.c_bool
        _cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
        _cf.CFBooleanGetValue.restype = ctypes.c_bool

        _iokit.IOPSCopyPowerSourcesInfo.restype = ctypes.c_void_p
        _iokit.IOPSCopyPowerSourcesList.argtypes = [ctypes.c_void_p]
        _iokit.IOPSCopyPowerSourcesList.restype = ctypes.c_void_p
        _iokit.IOPSGetPowerSourceDescription.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        _iokit.IOPSGetPowerSourceDescription.restype = ctypes.c_void_p
        return True
    except Exception:
        _iokit = None
        _cf = None
        return False


def _dict_get_val(cf_dict, key):
    k = _cf.CFStringCreateWithCString(None, key.encode('utf-8'), 0x08000100)
    v = _cf.CFDictionaryGetValue(cf_dict, k)
    _cf.CFRelease(k)
    return v


def _dict_get_str(cf_dict, key):
    v = _dict_get_val(cf_dict, key)
    if not v:
        return None
    buf = ctypes.create_string_buffer(256)
    if _cf.CFStringGetCString(v, buf, 256, 0x08000100):
        return buf.value.decode('utf-8', errors='replace')
    return None


def _dict_get_int(cf_dict, key):
    v = _dict_get_val(cf_dict, key)
    if not v:
        return None
    val = ctypes.c_int()
    if _cf.CFNumberGetValue(v, 9, ctypes.byref(val)):  # 9 = kCFNumberIntType
        return val.value
    return None


def _dict_get_bool(cf_dict, key):
    v = _dict_get_val(cf_dict, key)
    if not v:
        return False
    return bool(_cf.CFBooleanGetValue(v))


def get_mac_battery():
    """Query macOS for the current battery percentage and power state.

    Returns:
        tuple (percentage: int, state: str) where state is 'charging', 'discharging',
        'full', or 'ac'. If running on a desktop Mac without a battery, returns (100, 'ac').
    """
    if _init_iokit():
        try:
            info = _iokit.IOPSCopyPowerSourcesInfo()
            if info:
                try:
                    sources = _iokit.IOPSCopyPowerSourcesList(info)
                    if sources:
                        try:
                            count = _cf.CFArrayGetCount(sources)
                            if count > 0:
                                # Primary battery is usually index 0
                                src = _cf.CFArrayGetValueAtIndex(sources, 0)
                                desc = _iokit.IOPSGetPowerSourceDescription(info, src)
                                if desc:
                                    cur = _dict_get_int(desc, 'Current Capacity')
                                    max_cap = _dict_get_int(desc, 'Max Capacity') or 100
                                    power_state = _dict_get_str(desc, 'Power Source State') or ''
                                    is_charging = _dict_get_bool(desc, 'Is Charging')
                                    is_charged = _dict_get_bool(desc, 'Is Charged')

                                    pct = max(0, min(100, round((cur / max_cap) * 100))) if cur is not None else 100
                                    if is_charged:
                                        state = 'full'
                                    elif is_charging:
                                        state = 'charging'
                                    elif 'AC' in power_state:
                                        state = 'ac'
                                    else:
                                        state = 'discharging'
                                    return pct, state
                        finally:
                            _cf.CFRelease(sources)
                finally:
                    _cf.CFRelease(info)
        except Exception:
            pass

    # Fallback to pmset command
    try:
        out = subprocess.check_output(['/usr/bin/pmset', '-g', 'batt'], text=True, stderr=subprocess.DEVNULL)
        pct_match = re.search(r'(\d+)%', out)
        pct = int(pct_match.group(1)) if pct_match else 100
        if 'charged' in out.lower():
            state = 'full'
        elif 'charging' in out.lower():
            state = 'charging'
        elif 'AC Power' in out:
            state = 'ac'
        else:
            state = 'discharging'
        return pct, state
    except Exception:
        return 100, 'ac'


def sync_once(run_dir):
    """Query Mac battery once and send to VM."""
    level, state = get_mac_battery()
    vm_control.send_battery(run_dir, level, state)
    return level, state


def sync_loop(run_dir, interval=30, stop_event=None):
    """Continuously sync Mac battery status to the VM."""
    last_level = None
    last_state = None
    last_send_time = 0

    while stop_event is None or not stop_event.is_set():
        try:
            level, state = get_mac_battery()
            now = time.monotonic()
            # Send immediately if status changed, or every 60s as a heartbeat
            if (level != last_level or state != last_state or (now - last_send_time) >= 60):
                vm_control.send_battery(run_dir, level, state)
                last_level = level
                last_state = state
                last_send_time = now
        except OSError:
            # Serial socket closed or VM stopped
            break
        except Exception:
            pass

        # Sleep in small increments to respond promptly to stop_event
        sleep_until = time.monotonic() + interval
        while time.monotonic() < sleep_until:
            if stop_event is not None and stop_event.is_set():
                break
            time.sleep(1)


def start_background_sync(run_dir, interval=30):
    """Start the battery sync loop in a background daemon thread."""
    stop_event = threading.Event()
    thread = threading.Thread(
        target=sync_loop,
        args=(run_dir, interval, stop_event),
        name="BatterySync",
        daemon=True
    )
    thread.start()
    return stop_event, thread


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run_dir', help='Path to VM run directory (containing serial.sock)')
    parser.add_argument('--interval', type=int, default=30, help='Polling interval in seconds (default: 30)')
    parser.add_argument('--once', action='store_true', help='Send battery status once and exit')
    args = parser.parse_args()

    run_dir = Path(args.run_dir).resolve()
    if not (run_dir / 'serial.sock').exists():
        sys.exit(f"serial.sock not found in {run_dir}")

    if args.once:
        level, state = sync_once(run_dir)
        print(f"Sent battery status to VM: {level}% ({state})")
    else:
        print(f"Syncing battery to VM every {args.interval}s (Ctrl-C to stop)...")
        try:
            sync_loop(run_dir, interval=args.interval)
        except KeyboardInterrupt:
            print("\nBattery sync stopped.")


if __name__ == '__main__':
    main()
