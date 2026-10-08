#!/usr/bin/env python3
"""Unpack the pieces of Google's Cuttlefish image that the Googlebook VM borrows.

Input:  aosp_cf_arm64_only_phone-img-16373615.zip from ci.android.com (never redistributed).
Output: a folder with the software KeyMint/Gatekeeper/audio/boot-control/camera packages, the
        minigbm allocator and DRM composer binaries, and the virtio/DMA-heap kernel modules.

Every file is read out of the image without mounting it. Needs dump.erofs (erofs-utils),
debugfs (e2fsprogs) and lz4 on PATH or passed with --tools.

  unpack_cuttlefish.py ZIP OUT [--tools DIR]
"""
import argparse, hashlib, io, json, shutil, struct, subprocess, sys, tempfile, zipfile
from pathlib import Path

ZIP_SHA256 = '051caf8072ba9fb417e05999de2984752e44e13ce70b6c49c669f0a73db85c18'
URL = ('https://ci.android.com/builds/submitted/16373615/aosp_cf_arm64_only_phone-userdebug/'
       'latest/aosp_cf_arm64_only_phone-img-16373615.zip')

# output path -> (container, path inside it). Containers: 'vendor' is the vendor partition,
# 'apex:NAME' is the payload filesystem of /apex/NAME in vendor, 'apex-file:NAME' is the
# package itself, 'apex-payload:NAME' is its raw payload image, 'vendor_dlkm' and
# 'vendor_boot' hold kernel modules.
FILES = {
    'security/com.android.hardware.audio.apex': ('apex-file:com.android.hardware.audio.apex', None),
    'camera/com.google.emulated.camera.provider.hal.v4l2.apex': ('apex-file:com.google.emulated.camera.provider.hal.v4l2.apex', None),
    'security/com.android.hardware.gatekeeper.nonsecure.apex': ('apex-file:com.android.hardware.gatekeeper.nonsecure.apex', None),
    'security/rust_nonsecure_payload.img': ('apex-payload:com.android.hardware.keymint.rust_nonsecure.apex', None),
    'security/boot-service.default': ('apex:com.android.hardware.boot.apex', '/bin/hw/android.hardware.boot-service.default'),
    'graphics/extracted/libminigbm_gralloc.so': ('apex:com.google.cf.gralloc.apex', '/lib64/libminigbm_gralloc.so'),
    'graphics/extracted/libminigbm_gralloc4_utils.so': ('apex:com.google.cf.gralloc.apex', '/lib64/libminigbm_gralloc4_utils.so'),
    'graphics/extracted/android.hardware.graphics.allocator-V3-ndk.so': ('apex:com.google.cf.gralloc.apex', '/lib64/android.hardware.graphics.allocator-V3-ndk.so'),
    'graphics/extracted/android.hardware.graphics.common-V7-ndk.so': ('apex:com.google.cf.gralloc.apex', '/lib64/android.hardware.graphics.common-V7-ndk.so'),
    'graphics/extracted/android.hardware.graphics.allocator-service.minigbm': ('apex:com.google.cf.gralloc.apex', '/bin/hw/android.hardware.graphics.allocator-service.minigbm'),
    'graphics/extracted/mapper.minigbm.so': ('vendor', '/lib64/hw/mapper.minigbm.so'),
    'graphics/extracted/gralloc.default.so': ('vendor', '/lib64/hw/gralloc.default.so'),
    'graphics/cf-composer/android.hardware.composer.hwc3-service.drm': ('apex:com.android.hardware.graphics.composer.drm_hwcomposer.apex', '/bin/hw/android.hardware.composer.hwc3-service.drm'),
    'graphics/cf-composer/drm_hwcomposer_atom_reporter.so': ('apex:com.android.hardware.graphics.composer.drm_hwcomposer.apex', '/lib64/drm_hwcomposer_atom_reporter.so'),
    'modules/system_heap.ko': ('vendor_dlkm', '/lib/modules/system_heap.ko'),
}
RAMDISK_MODULES = ['virtio_pci_legacy_dev.ko', 'virtio_pci_modern_dev.ko', 'virtio_pci.ko',
                   'virtio_dma_buf.ko', 'virtio-gpu.ko', 'virtio_input.ko', 'virtio_blk.ko']


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 22), b''):
            h.update(block)
    return h.hexdigest()


def unsparse(source, dest):
    """Expand an Android sparse image into a sparse regular file."""
    with open(source, 'rb') as f, open(dest, 'xb') as g:
        magic, major, _, hs, cs, bs, blocks, chunks, _ = struct.unpack('<IHHHHIIII', f.read(28))
        assert magic == 0xed26ff3a and major == 1 and hs >= 28 and cs >= 12
        f.read(hs - 28)
        for _ in range(chunks):
            kind, _, count, total = struct.unpack_from('<HHII', f.read(cs))
            n = count * bs
            if kind == 0xcac1:
                assert total == cs + n
                while n:
                    b = f.read(min(n, 8 << 20)); assert b; g.write(b); n -= len(b)
            elif kind == 0xcac2:
                fill = f.read(4)
                if fill == bytes(4): g.seek(n, 1)
                else:
                    b = fill * (1 << 18)
                    while n: k = min(n, len(b)); g.write(b[:k]); n -= k
            elif kind == 0xcac3: g.seek(n, 1)
            elif kind == 0xcac4: f.read(4)
            else: raise ValueError(hex(kind))
        assert g.tell() == blocks * bs
        g.truncate()


def super_partitions(raw):
    """Parse AOSP dynamic-partition (LP) metadata; return {name: byte offset} for single-extent partitions."""
    u = lambda b, o: struct.unpack_from('<I', b, o)[0]
    with open(raw, 'rb') as f:
        f.seek(4096); g = f.read(4096); assert u(g, 0) == 0x616c4467
        f.seek(12288); m = f.read(u(g, 40)); assert u(m, 0) == 0x414c5030
        hs = u(m, 8); tables = m[hs:hs + u(m, 44)]
        assert hashlib.sha256(tables).digest() == m[48:80]
        def table(off):
            start, count, size = struct.unpack_from('<III', m, off)
            return [tables[start + i * size:start + (i + 1) * size] for i in range(count)]
        extents = [struct.unpack_from('<QIQI', e) for e in table(92)]
        out = {}
        for p in table(80):
            name = p[:36].split(b'\0')[0].decode()
            _, start, num, _ = struct.unpack_from('<IIII', p, 36)
            if num == 1:
                out[name] = extents[start][2] * 512
        return out


def vendor_boot_ramdisk(image, lz4):
    """Return {path: bytes} for the first vendor ramdisk of an Android vendor_boot v4 image."""
    b = Path(image).read_bytes()
    assert b[:8] == b'VNDRBOOT' and struct.unpack_from('<I', b, 8)[0] == 4
    page = struct.unpack_from('<I', b, 12)[0]
    total_ramdisk = struct.unpack_from('<I', b, 24)[0]
    # v4 header: cmdline[2048] at 28, tags_addr 2076, name[16] 2080, header_size 2096,
    # dtb_size 2100, dtb_addr 2104 (u64), table_size 2112, entry count 2116, entry size 2120.
    header_size, dtb_size = struct.unpack_from('<II', b, 2096)
    align = lambda n: (n + page - 1) // page * page
    ramdisk_base = align(header_size)
    table = ramdisk_base + align(total_ramdisk) + align(dtb_size)
    size, offset, _ = struct.unpack_from('<III', b, table)
    blob = b[ramdisk_base + offset:ramdisk_base + offset + size]
    cpio = subprocess.run([lz4, '-d', '-c'], input=blob, capture_output=True, check=True).stdout
    files, pos = {}, 0
    while pos < len(cpio):  # newc cpio
        assert cpio[pos:pos + 6] == b'070701'
        f = [int(cpio[pos + 6 + i * 8:pos + 14 + i * 8], 16) for i in range(13)]
        namesize, filesize = f[11], f[6]
        name = cpio[pos + 110:pos + 110 + namesize - 1].decode()
        data = (pos + 110 + namesize + 3) & ~3
        if name == 'TRAILER!!!': break
        files[name] = cpio[data:data + filesize]
        pos = (data + filesize + 3) & ~3
    return files


def main():
    a = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    a.add_argument('zip'); a.add_argument('out')
    a.add_argument('--tools', help='directory tree containing dump.erofs and debugfs')
    args = a.parse_args()

    def tool(name):
        if args.tools:
            hits = sorted(Path(args.tools).rglob(name))
            if hits: return str(hits[0])
        found = shutil.which(name)
        if not found: sys.exit(f'missing tool: {name}')
        return found
    dump, debugfs, lz4 = tool('dump.erofs'), tool('debugfs'), tool('lz4')

    out = Path(args.out); out.mkdir(parents=True, exist_ok=True)
    digest = sha256_file(args.zip)
    if digest != ZIP_SHA256:
        sys.exit(f'{args.zip}: sha256 {digest} does not match the pinned build ({ZIP_SHA256}).\nDownload: {URL}')

    with tempfile.TemporaryDirectory(dir=out) as tmp:
        tmp = Path(tmp)
        with zipfile.ZipFile(args.zip) as z:
            z.extract('super.img', tmp); z.extract('vendor_boot.img', tmp)
        raw = tmp / 'super.raw'
        unsparse(tmp / 'super.img', raw)
        (tmp / 'super.img').unlink()
        parts = super_partitions(raw)

        def erofs(partition, path):
            return subprocess.check_output([dump, f'--offset={parts[partition]}', '--path=' + path, '--cat', str(raw)])
        payloads = {}
        def apex(name):
            if name not in payloads:
                package = erofs('vendor_a', '/apex/' + name)
                payload = zipfile.ZipFile(io.BytesIO(package)).read('apex_payload.img')
                image = tmp / (name + '.img'); image.write_bytes(payload)
                payloads[name] = (package, payload, image)
            return payloads[name]
        def read(container, path):
            kind, _, name = container.partition(':')
            if kind == 'vendor': return erofs('vendor_a', path)
            if kind == 'vendor_dlkm': return erofs('vendor_dlkm_a', path)
            package, payload, image = apex(name)
            if kind == 'apex-file': return package
            if kind == 'apex-payload': return payload
            if payload[1024:1028] == bytes.fromhex('e2e1f5e0'):
                return subprocess.check_output([dump, '--path=' + path, '--cat', str(image)])
            p = subprocess.run([debugfs, '-R', 'cat ' + path, str(image)], capture_output=True, check=True)
            assert p.stdout, path
            return p.stdout

        results = {}
        for target, (container, path) in FILES.items():
            results[target] = read(container, path)
        ramdisk = vendor_boot_ramdisk(tmp / 'vendor_boot.img', lz4)
        for m in RAMDISK_MODULES:
            results['modules/' + m] = ramdisk['lib/modules/' + m]
        for m in ['modules.alias', 'modules.dep', 'modules.softdep', 'modules.options']:
            results['modules/' + m] = ramdisk['lib/modules/' + m]
        # Audio policy files the image builder copies straight from the vendor partition.
        for n in ['audio_effects.xml', 'audio_effects_config.xml', 'audio_policy_configuration.xml',
                  'audio_policy_volumes.xml', 'default_volume_tables.xml',
                  'bluetooth_with_le_audio_policy_configuration_7_0.xml', 'primary_audio_policy_configuration.xml',
                  'r_submix_audio_policy_configuration.xml', 'surround_sound_configuration_5_0.xml',
                  'usb_audio_policy_configuration.xml']:
            results['audio-config/' + n] = erofs('vendor_a', '/etc/' + n)

    manifest = {}
    for target, data in sorted(results.items()):
        p = out / target; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
        manifest[target] = hashlib.sha256(data).hexdigest()
    (out / 'manifest.json').write_text(json.dumps({'source': URL, 'zip_sha256': ZIP_SHA256, 'files': manifest}, indent=1) + '\n')
    print(f'unpacked {len(results)} files into {out}')


if __name__ == '__main__':
    main()
