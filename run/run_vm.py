#!/usr/bin/env python3
"""Run the Googlebook VM once with an explicit QEMU command line.

  run_vm.py WORK RUN_NAME [--seconds N] [--snapshot] [--offline | --isolated] [--no-audio] [--no-bluetooth]
            [--display WxH] [--memory MIB] [--cpus N]

WORK is the build folder (host/, image/, UTM-beta/). Logs and sockets go to WORK/logs/RUN_NAME.
The disk is written to unless --snapshot is given. Networking is QEMU user-mode NAT with no
inbound forwards; --offline removes it (the pointer/clipboard helper then cannot connect).
--isolated keeps only the pointer/clipboard link: the guest can't reach the internet or any
service listening on this Mac's loopback (plain NAT maps 10.0.2.2 to the Mac's 127.0.0.1).
On stop, Android is asked to power off through the guest control channel before QEMU is killed.

Bluetooth: if the Android emulator's netsimd is installed (SDK "emulator" package, or set
GBOS_NETSIMD), it is started as a virtual Bluetooth controller and Android is told it has
Bluetooth. Otherwise, or with --no-bluetooth, the guest boots with no Bluetooth at all.
"""
import argparse, atexit, fcntl, json, os, re, secrets, signal, socket, subprocess, sys, threading, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vm_control

# Kernel command line for the pinned image (mica-user 16471258). The vbmeta values describe the
# original, unmodified vbmeta partition of that image.
CMDLINE = ('console=ttyAMA0,115200 earlycon=pl011,0x9000000 panic=0 root=/dev/ram0 '
           'androidboot.hardware=android-desktop androidboot.hardware.platform=android-desktop '
           'androidboot.slot_suffix=_a androidboot.boot_devices=3f000000.pcie androidboot.vbmeta.size=7680 '
           'androidboot.vbmeta.hash_alg=sha256 '
           'androidboot.vbmeta.digest=9118d58c024a0b43fef17a1dcdf6b999b5ea9cbc053fd4377d5d78c445b15692 '
           'androidboot.vbmeta.device_state=unlocked androidboot.verifiedbootstate=orange '
           'androidboot.veritymode=enforcing printk.devkmsg=on '
           'androidboot.vendor.apex.com.android.hardware.keymint.strongbox.desktop=none '
           'androidboot.vendor.apex.com.android.hardware.audio.desktop=none loglevel=3')


def find_netsimd():
    # The last two are where prereqs.sh puts the SDK when it installs one through Homebrew.
    sdks = [os.environ.get(k) for k in ('ANDROID_SDK', 'ANDROID_HOME', 'ANDROID_SDK_ROOT')] + [
        str(Path.home() / 'Library/Android/sdk'), '/opt/homebrew/share/android-commandlinetools',
        '/usr/local/share/android-commandlinetools']
    for c in [os.environ.get('GBOS_NETSIMD')] + [str(Path(s) / 'emulator/netsimd') for s in sdks if s]:
        if c and os.access(c, os.X_OK): return c


def start_netsimd(binary, out):
    """Start a virtual Bluetooth controller serving HCI on a free loopback port. Returns (process, port).

    netsimd exits by itself when QEMU disconnects; if this script ends before that (QEMU never
    started, say), it is stopped on the way out."""
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]
    tmp = out / 'netsim'; tmp.mkdir()
    proc = subprocess.Popen([binary, '--hci-port', str(port), '--no-web-ui', '--no-cli-ui', '--logtostderr', '--instance', '27'],
                            cwd=tmp, env=dict(os.environ, TMPDIR=str(tmp)), stdin=subprocess.DEVNULL,
                            stdout=(out / 'netsim.log').open('wb'), stderr=subprocess.STDOUT, start_new_session=True)
    def stop():
        if proc.poll() is None:
            try: os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError: pass
    atexit.register(stop)
    return proc, port


def send_token(proc, out, token, host_addr):
    """Hand the per-boot token to the guest over the serial console, which only this user can
    reach, once its control service is up. It used to go on the kernel command line, where any
    guest app that can read ro.boot.* properties could see it."""
    serial = out / 'serial.log'
    def seen(marker):
        # Match at a line start so guest log text can't fake a marker.
        try: return re.search(rb'(?m)^' + re.escape(marker), serial.read_bytes()) is not None
        except OSError: return False
    deadline = time.monotonic() + 300
    while not seen(b'VM_CONTROL_READY'):
        if proc.poll() is not None or time.monotonic() > deadline: return
        time.sleep(.5)
    err = None
    for _ in range(6):
        try: vm_control.send(out, f'VM_TOKEN {token} {host_addr}')
        except OSError as e: err = e
        for _ in range(10):
            if seen(b'VM_CONTROL token set'): return
            if proc.poll() is not None: return
            time.sleep(.5)
    print('WARNING: the guest never acknowledged the input token' + (f' ({err})' if err else '') +
          '; the pointer/clipboard link will not connect', file=sys.stderr, flush=True)


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument('work'); a.add_argument('name')
    a.add_argument('--seconds', type=int, default=3600)
    a.add_argument('--snapshot', action='store_true'); a.add_argument('--offline', action='store_true')
    a.add_argument('--isolated', action='store_true')
    a.add_argument('--no-audio', action='store_true'); a.add_argument('--no-bluetooth', action='store_true')
    a.add_argument('--display', default='1920x1200'); a.add_argument('--memory', type=int, default=4096)
    a.add_argument('--cpus', type=int, default=6)
    a.add_argument('--image', help='image folder (default WORK/image)')
    args = a.parse_args()
    work = Path(args.work).resolve()
    assert args.name.replace('-', '').replace('_', '').isalnum() and 10 <= args.seconds <= 86400
    image = Path(args.image).resolve() if args.image else work / 'image'
    host, utm = work / 'host', work / 'UTM-beta/UTM.app'
    for p in (host / 'qemu-interop', host / 'qemu-aarch64-softmmu', host / 'virgl_render_server',
              image / 'googlebook.raw', image / 'initrd.img', image / 'kernel.Image', utm / 'Contents/Frameworks'):
        if not p.exists(): sys.exit(f'missing: {p}')
    width, height = args.display.split('x')
    (work / 'logs').mkdir(exist_ok=True)
    lock = (work / 'logs/vm.lock').open('a')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: sys.exit('another VM from this folder is already running')
    # Private: holds the token and the QMP, SPICE and serial sockets.
    out = work / 'logs' / args.name; out.mkdir(mode=0o700)
    # Random per-boot secret for the pointer/clipboard link (see guest/input).
    token = secrets.token_hex(16)
    with os.fdopen(os.open(out / 'token', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as f: f.write(token)

    netsim, cmdline = None, CMDLINE
    netsimd = None if args.no_bluetooth else find_netsimd()
    if netsimd:
        netsim, bt_port = start_netsimd(netsimd, out)
        cmdline += ' androidboot.product.vendor.sku=vmbt'
    print('bluetooth:', f'virtual controller ({netsimd})' if netsimd else 'none', flush=True)

    cmd = [str(host / 'qemu-interop'), '-L', str(utm / 'Contents/Resources/qemu'), '-nodefaults', '-vga', 'none',
           '-nic', 'none', '-device', 'virtio-gpu-gl-pci,hostmem=8G,blob=true,venus=true',
           '-global', f'virtio-gpu-gl-pci.xres={width}', '-global', f'virtio-gpu-gl-pci.yres={height}',
           '-cpu', 'host', '-smp', f'cpus={args.cpus},sockets=1,cores={args.cpus},threads=1',
           '-machine', 'virt,gic-version=3,highmem=on,highmem-ecam=off', '-accel', 'hvf,ipa-granule-size=0x1000',
           '-m', str(args.memory), '-audio', 'none',
           '-kernel', str(image / 'kernel.Image'), '-initrd', str(image / 'initrd.img'), '-append', cmdline,
           '-drive', f'if=none,media=disk,id=driveimage,format=raw,file={image / "googlebook.raw"}',
           '-device', 'virtio-blk-pci,drive=driveimage', '-device', 'virtio-serial', '-no-reboot',
           '-device', 'qemu-xhci,id=xhci,addr=0x5', '-device', 'usb-kbd,id=keyboard,bus=xhci.0',
           '-device', 'usb-mouse,id=mouse,bus=xhci.0',
           '-display', 'none',
           '-spice', 'unix=on,addr=spice.sock,disable-ticketing=on,disable-copy-paste=on,disable-agent-file-xfer=on,gl=es',
           '-chardev', 'socket,id=serial0,path=serial.sock,server=on,wait=off,logfile=serial.log',
           '-serial', 'chardev:serial0', '-qmp', 'unix:qmp.sock,server=on,wait=off']
    if args.snapshot: cmd.append('-snapshot')
    if not args.offline:
        # Isolated: only the one forward to the viewer's loopback port.
        isolate = ',restrict=on,guestfwd=tcp:10.0.2.100:27183-cmd:/usr/bin/nc 127.0.0.1 27183' if args.isolated else ''
        cmd += ['-netdev', 'user,id=googlebooknet,ipv6=off' + isolate,
                '-device', 'usb-net,id=ethernet,netdev=googlebooknet,bus=xhci.0,mac=52:54:00:12:34:56']
    if netsim:
        # /dev/hvc0 in the guest; the Bluetooth service there speaks HCI over it.
        cmd += ['-chardev', f'socket,id=bluetooth,host=127.0.0.1,port={bt_port},reconnect-ms=500',
                '-device', 'virtconsole,chardev=bluetooth']
    if not args.no_audio:
        cmd += ['-audiodev', 'coreaudio,id=audio0', '-device', 'usb-audio,audiodev=audio0,bus=xhci.0']
    env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(utm / 'Contents/Frameworks'),
               RENDER_SERVER_EXEC_PATH=str(host / 'virgl_render_server'),
               VK_DRIVER_FILES=str(utm / 'Contents/Resources/vulkan/icd.d/MoltenVK_icd.json'),
               ANGLE_DEFAULT_PLATFORM='metal', XDG_RUNTIME_DIR=str(out), TMPDIR=str(out))
    env.pop('APP_SANDBOX_GROUP_ID', None)
    (out / 'command.json').write_text(json.dumps({'command': cmd, 'seconds': args.seconds}, indent=2))
    with (out / 'host.log').open('wb') as log:
        proc = subprocess.Popen(cmd, cwd=out, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        print('PID', proc.pid, 'logs', out, flush=True)
        threading.Thread(target=send_token, args=(proc, out, token, '10.0.2.100' if args.isolated else '10.0.2.2'), daemon=True).start()
        def interrupt(signum, frame): raise KeyboardInterrupt
        signal.signal(signal.SIGTERM, interrupt)
        rc = None
        try: rc = proc.wait(timeout=args.seconds)
        except (subprocess.TimeoutExpired, KeyboardInterrupt): pass
        finally:
            if proc.poll() is None:
                try:
                    vm_control.send(out, 'VM_POWEROFF'); rc = proc.wait(timeout=30)
                except Exception: pass
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try: rc = proc.wait(timeout=8)
                except subprocess.TimeoutExpired: os.killpg(proc.pid, signal.SIGKILL); rc = proc.wait()
            if netsim and netsim.poll() is None:
                try: netsim.wait(timeout=3)
                except subprocess.TimeoutExpired: os.killpg(netsim.pid, signal.SIGTERM)
        (out / 'result.json').write_text(json.dumps({'exit_code': rc}))
        print('exit', rc, flush=True)


if __name__ == '__main__':
    main()
