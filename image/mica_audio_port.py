"""Official Cuttlefish audio APEX and its matching virtual-device configuration."""
from pathlib import Path
import re
import subprocess
R=Path(__file__).resolve().parents[1]

# USB microphones only (the viewer's "Mac Microphone", host/microphone.m). Cuttlefish's policy has
# no USB module at all, so Android saw the microphone but had no HAL module to record from it.
# Output stays off this module on purpose: the VM's USB speaker (QEMU's usb-audio, ALSA card 0)
# is already played through the primary module, and two modules can't both open that card.
USB_INPUT_MODULE=b'''<?xml version="1.0" encoding="UTF-8"?>
<!-- USB audio input for the VM (see image/mica_audio_port.py). -->
<module name="usb" halVersion="2.0">
    <mixPorts>
        <mixPort name="usb_device input" role="sink"/>
    </mixPorts>
    <devicePorts>
        <devicePort tagName="USB Device In" type="AUDIO_DEVICE_IN_USB_DEVICE" role="source"/>
        <devicePort tagName="USB Headset In" type="AUDIO_DEVICE_IN_USB_HEADSET" role="source"/>
    </devicePorts>
    <routes>
        <route type="mix" sink="usb_device input" sources="USB Device In,USB Headset In"/>
    </routes>
</module>
'''
# The audio HAL registers one IModule per policy module; vendor services must be in VINTF.
USB_MODULE_VINTF=b'''<manifest version="1.0" type="device">
    <hal format="aidl">
        <name>android.hardware.audio.core</name>
        <version>4</version>
        <fqname>IModule/usb</fqname>
    </hal>
</manifest>
'''

def apply(add):
 p=R/'artifacts/security-port-review/com.android.hardware.audio.apex'
 add('apex/com.android.hardware.audio.apex',p.read_bytes(),'vendor_apex_file')
 # The new official APEX owns this interface; remove the duplicate declaration.
 add('etc/vintf/manifest/bluetooth_audio.xml',b'<manifest version="1.0" type="device"/>\n','vendor_configs_file')
 # No Qualcomm hotword DSP exists in the VM. An advertised but absent AIDL
 # sound-trigger service makes system_server wait forever (it trips the watchdog).
 add('etc/vintf/manifest/soundtrigger.qti.xml',b'<manifest version="1.0" type="device"/>\n','vendor_configs_file')
 names=['audio_effects.xml','audio_effects_config.xml','audio_policy_configuration.xml','audio_policy_volumes.xml','default_volume_tables.xml','bluetooth_with_le_audio_policy_configuration_7_0.xml','primary_audio_policy_configuration.xml','r_submix_audio_policy_configuration.xml','surround_sound_configuration_5_0.xml','usb_audio_policy_configuration.xml']
 for n in names:
  b=(R/'artifacts/cuttlefish-audio-config'/n).read_bytes();assert b.startswith(b'<?xml') or b.startswith(b'<!--'),n
  if n=='audio_policy_configuration.xml':
   anchor=b'<xi:include href="r_submix_audio_policy_configuration.xml"/>'
   assert b.count(anchor)==1 and b'usb_audio_policy_configuration.xml' not in b
   b=b.replace(anchor,anchor+b'\n\n        <!-- USB microphones (input only) -->\n        <xi:include href="usb_audio_policy_configuration.xml"/>')
  if n=='usb_audio_policy_configuration.xml':
   b=USB_INPUT_MODULE
  if n=='primary_audio_policy_configuration.xml':
   # The VM has no built-in microphone (QEMU's usb-audio only plays). Declaring one made
   # camcorder recordings, which prefer it over a USB microphone, open a capture device
   # that doesn't exist and wait forever. The audio HAL refuses a built-in device that
   # isn't attached, so the port goes entirely, with the two inputs that only it fed.
   for pat in (rb'\n *<item>Built-In Mic</item>', rb'\n *<devicePort tagName="Built-In Mic".*?</devicePort>',
               rb'\n *<mixPort name="primary input".*?</mixPort>', rb'\n *<mixPort name="mmap_no_irq_in".*?</mixPort>',
               rb'\n *<route type="mix" sink="primary input"\s+sources="Built-In Mic"/>',
               rb'\n *<route type="mix" sink="mmap_no_irq_in"\s+sources="Built-In Mic"/>'):
    b,k=re.subn(pat,b'',b,flags=re.S);assert k==1,pat
   assert b'Built-In Mic' not in b and b'primary input' not in b and b'mmap_no_irq_in' not in b
  add('etc/'+n,b,'vendor_configs_file')
 add('etc/vintf/manifest/audio_usb_module.xml',USB_MODULE_VINTF,'vendor_configs_file')
