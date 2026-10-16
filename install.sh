#!/bin/bash
# Build everything from source and leave a runnable Googlebook VM in $GOOGLEBOOK_WORK (default ./work).
# Run:  ./install.sh     then:  python3 run/launch.py work
. "$(dirname "$0")/lib.sh"
[ "$(uname -m)" = arm64 ] || die "Apple Silicon Mac required"
"$ROOT/prereqs.sh"
mkdir -p "$WORK"
free_gb=$(( $(df -k "$WORK" | tail -1 | awk '{print $4}') / 1048576 ))
[ "$free_gb" -ge 60 ] || die "only ${free_gb} GB free where $WORK lives; this needs about 60 GB (downloads, the unpacked image, and room for the VM to grow)"
ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
[ "$ram_gb" -ge 16 ] || echo "warning: ${ram_gb} GB RAM. The VM takes 4 GB and the builds want a few more; close other apps first."
ensure_build_env
"$ROOT/fetch.sh"
"$ROOT/build-host.sh"
"$ROOT/build-guest.sh"
"$ROOT/build-image.sh"
for f in "$WORK/host/Googlebook VM.app" "${GBOS_IMAGE_DIR:-$WORK/image}/googlebook.raw" "${GBOS_IMAGE_DIR:-$WORK/image}/initrd.img" "${GBOS_IMAGE_DIR:-$WORK/image}/kernel.Image"; do
  [ -e "$f" ] || die "the build finished without producing $f. Please report this with the output above."
done
say "Done. Open \"$WORK/host/Googlebook VM.app\" (drag it to your Dock if you like)."
