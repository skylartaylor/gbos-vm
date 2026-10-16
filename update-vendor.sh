#!/bin/bash
# Rebuild the vendor partition overlay with updated guest scripts and graft it
# into $WORK/image/googlebook.raw.
# Preserves all user data in the existing disk.
. "$(dirname "$0")/lib.sh"
no_running_vm
need brew "https://brew.sh"
need lz4 "brew install lz4"

IMAGE_DIR="${GBOS_IMAGE_DIR:-$WORK/image}"
[ -f "$IMAGE_DIR/googlebook.raw" ] || die "no existing disk at $IMAGE_DIR/googlebook.raw"
[ -f "$IMAGE_DIR/relocation.json" ] || die "missing $IMAGE_DIR/relocation.json"

GUEST="${GOOGLEBOOK_GUEST_DIR:-$WORK/guest}"; TOOLS="${GOOGLEBOOK_TOOLS_DIR:-$WORK/tools}"
for f in "$WORK/googlebook/mica-recovery.raw" "$WORK/cuttlefish/manifest.json" "$GUEST/libvulkan_virtio.so" \
         "$GUEST/mesa-runtime/libgallium_dri.so" "$GUEST/vm-input.jar" "$TOOLS/guest_graphics_memfd_policy"; do
  [ -e "$f" ] || die "missing input: $f"
done

WS="$WORK/ws-update-vendor"
rm -rf "$WS"
mkdir -p "$WS/scripts" "$WS/artifacts/mica" "$WS/artifacts/graphics-port-review" "$WS/artifacts/cuttlefish-arm17" \
         "$WS/experiments/erofs-utils/1.9.4" "$WS/experiments/ext4-tools/e2fsprogs/1.47.4"
cp -R "$ROOT"/image/* "$WS/scripts/"
ln -sf "$WORK/googlebook/mica-recovery.raw" "$WS/artifacts/mica-recovery.raw"
ln -sf "$WORK/cuttlefish/security" "$WS/artifacts/security-port-review"
ln -sf "$WORK/cuttlefish/graphics/extracted" "$WS/artifacts/graphics-port-review/extracted"
ln -sf "$WORK/cuttlefish/graphics/cf-composer" "$WS/artifacts/graphics-port-review/cf-composer"
ln -sf "$WORK/cuttlefish/modules" "$WS/artifacts/cuttlefish-arm17/modules"
ln -sf "$WORK/cuttlefish/audio-config" "$WS/artifacts/cuttlefish-audio-config"
ln -sf "$(brew --prefix erofs-utils)/bin" "$WS/experiments/erofs-utils/1.9.4/bin"
ln -sf "$(brew --prefix e2fsprogs)/sbin" "$WS/experiments/ext4-tools/e2fsprogs/1.47.4/sbin"
export GOOGLEBOOK_GUEST_DIR="$GUEST" GOOGLEBOOK_TOOLS_DIR="$TOOLS"

cd "$WS"
say "Extracting normal ramdisks"
python3 scripts/extract_mica_normal.py
python3 scripts/make_mica_gpu_initrd.py

say "Rebuilding vendor partition overlay with updated guest scripts"
python3 scripts/make_mica_security_port.py base --graphics --audio --vm-compat --locksettings --offline-desktop \
  --quiet-diagnostics --runtime-diagnostics --crash-diagnostics --venus --vulkan-desktop --quiet-absent-hardware \
  --host-control --host-input ${GBOS_IMAGE_FLAGS:-}

say "Grafting vendor partition into $IMAGE_DIR/googlebook.raw"
python3 -c "
import json
rel = json.loads(open('$IMAGE_DIR/relocation.json').read())
offset = rel['vendor_offset']
size = rel['vendor_partition_bytes']
vendor = open('$WS/artifacts/mica/base/vendor.erofs', 'rb').read()
assert len(vendor) <= size, f'vendor.erofs {len(vendor)} exceeds partition size {size}'
with open('$IMAGE_DIR/googlebook.raw', 'r+b') as f:
    f.seek(offset)
    f.write(vendor)
    if len(vendor) < size:
        f.write(bytes(size - len(vendor)))
print(f'Grafted {len(vendor)} bytes into $IMAGE_DIR/googlebook.raw at offset {offset}')
"

cd "$WORK"
rm -rf "$WS"

say "Vendor partition update complete! Your user data was preserved."
