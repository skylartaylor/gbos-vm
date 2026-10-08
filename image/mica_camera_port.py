"""Camera: AOSP's external (USB/V4L2) camera provider from Cuttlefish, for the viewer's webcam.

The camera itself is supplied by the viewer (host/webcam.m): a UVC webcam, 1d6b:0102, plugged
into the VM over usb-redir. The guest kernel's uvcvideo driver turns it into /dev/video0.

Googlebook OS ships its own USB camera HAL, but it is no use here: every session runs through
GPU stream manipulators (OpenGL, OpenCL and Vulkan with external memory) this VM cannot provide,
and with those removed it opens sessions that never start streaming. It is retired below.

Instead this adds the official Cuttlefish build of AOSP's external camera provider
(ICameraProvider/external/0, an APEX with its own init script and VINTF fragment), which reads
any /dev/videoN on the CPU. Two vendor files make it work:
- vendor_service_contexts: Googlebook's policy labels the usb/legacy/qti provider instances but
  not external/0; label it hal_camera_service like the others.
- external_camera_config.xml: without it the provider caps 720p at 7.5 fps and 1080p at 5 fps,
  which drops every mode of a 30 fps webcam except 640x480. Nothing is ignored as internal."""
from pathlib import Path
from erofs_metadata import metadata

R = Path(__file__).resolve().parents[1]
APEX = 'com.google.emulated.camera.provider.hal.v4l2.apex'
CONFIG = b'''<?xml version="1.0" encoding="utf-8"?>
<!-- Webcam supplied by the gbos-vm viewer (host/webcam.m). -->
<ExternalCamera>
    <Provider>
        <ignore>
        </ignore>
    </Provider>
    <Device>
        <MaxJpegBufferSize bytes="4194304"/>
        <NumVideoBuffers count="4"/>
        <NumStillBuffers count="2"/>
        <FpsList>
            <Limit width="640" height="480" fpsBound="30.0"/>
            <Limit width="1280" height="720" fpsBound="30.0"/>
            <Limit width="1920" height="1080" fpsBound="30.0"/>
        </FpsList>
    </Device>
</ExternalCamera>
'''


USB_HAL = 'android.hardware.camera.provider-usb-service.android-desktop'


def apply(add, original, raw, off):
    # Retire Googlebook's USB camera HAL: it would also claim /dev/video0 and then stall. Drop its
    # VINTF declaration (so cameraserver doesn't wait for it) and its service; keep the uvcvideo
    # module parameters its init script sets at boot.
    rc = original('etc/init/%s.rc' % USB_HAL).decode()
    assert rc.startswith('service vendor.camera.provider-usb ') and '\non boot\n' in rc, rc
    add('etc/init/%s.rc' % USB_HAL, ('# Googlebook USB camera HAL retired in the VM (see image/mica_camera_port.py).\n'
                                      + rc[rc.index('on boot\n'):]).encode(), 'vendor_configs_file')
    add('etc/vintf/manifest/%s.xml' % USB_HAL, b'<manifest version="1.0" type="device"/>\n', 'vendor_configs_file')
    apex = (R / 'artifacts/cuttlefish-camera' / APEX).read_bytes()
    add('apex/' + APEX, apex, 'vendor_apex_file')
    add('etc/external_camera_config.xml', CONFIG, 'vendor_configs_file')
    n = 'etc/selinux/vendor_service_contexts'
    m = metadata(raw, '/' + n, off)
    contexts = original(n)
    assert b'ICameraProvider/external/0' not in contexts
    add(n, contexts.rstrip(b'\n') + b'\nandroid.hardware.camera.provider.ICameraProvider/external/0 u:object_r:hal_camera_service:s0\n',
        m['xattrs']['security.selinux'].decode().split(':')[2], m['mode'] & 0o7777)
    return {'provider': 'AOSP external camera provider (Cuttlefish 16373615 ' + APEX + ')',
            'service': 'ICameraProvider/external/0 -> hal_camera_service', 'googlebook_usb_hal': 'retired'}
