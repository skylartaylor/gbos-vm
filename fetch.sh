#!/bin/bash
# Download and verify the things we may not redistribute, on your own machine:
#   Google's Googlebook recovery image, Google's Cuttlefish virtual-device image, and the UTM 5 beta.
# Also installs three small Homebrew tools used to read and write the disk image.
. "$(dirname "$0")/lib.sh"
need curl "macOS"; need python3 "Xcode command line tools"; need hdiutil "macOS"
mkdir -p "$WORK" "$DOWNLOADS"

say "Image tools (Homebrew: erofs-utils, e2fsprogs, lz4, pkgconf)"
need brew "https://brew.sh"
for f in erofs-utils e2fsprogs lz4 pkgconf; do
  brew list --formula "$f" >/dev/null 2>&1 || brew install -q "$f"
done
# Homebrew can't pin versions: note when these differ from the tested ones.
for fv in erofs-utils:1.9.4 e2fsprogs:1.47.4 lz4:1.10.0; do
  have="$(brew list --versions "${fv%%:*}" 2>/dev/null | awk '{print $2}' || true)"
  [ "${have%%_*}" = "${fv#*:}" ] || echo "note: ${fv%%:*} is ${have:-missing}; tested with ${fv#*:}"
done

say "UTM 5.0.6 beta (QEMU, MoltenVK, ANGLE, SPICE)"
if [ ! -d "$UTM_BETA_APP" ]; then
  fetch_big "$UTM_DMG_URL" "$DOWNLOADS/UTM-5.0.6.dmg" "$UTM_DMG_SHA256"
  mnt="$(mktemp -d)"; mounted_here=1
  if ! hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$DOWNLOADS/UTM-5.0.6.dmg" 2>/dev/null; then
    # Already mounted somewhere (macOS refuses a second attach): use that mount instead.
    rmdir "$mnt"; mounted_here=0
    mnt="$(hdiutil info -plist | python3 -c '
import os,plistlib,sys
want=os.path.realpath(sys.argv[1])
for image in plistlib.loads(sys.stdin.buffer.read()).get("images",[]):
    if os.path.realpath(image.get("image-path",""))==want:
        for e in image.get("system-entities",[]):
            if e.get("mount-point"): print(e["mount-point"])
' "$DOWNLOADS/UTM-5.0.6.dmg" | head -1)"
    [ -d "$mnt/UTM.app" ] || die "could not mount $DOWNLOADS/UTM-5.0.6.dmg"
  fi
  mkdir -p "$(dirname "$UTM_BETA_APP")"; cp -R "$mnt/UTM.app" "$UTM_BETA_APP"
  if [ "$mounted_here" = 1 ]; then hdiutil detach -quiet "$mnt"; rmdir "$mnt" 2>/dev/null || true; fi
fi

say "Cuttlefish virtual-device image (Android CI build $CUTTLEFISH_BUILD)"
if [ ! -f "$DOWNLOADS/$CUTTLEFISH_ZIP" ]; then
  # The public CI page hands out a short-lived storage URL for the artifact.
  url="$(python3 - <<PY
import json,re,sys,urllib.parse,urllib.request
html=urllib.request.urlopen('https://ci.android.com/builds/submitted/$CUTTLEFISH_BUILD/aosp_cf_arm64_only_phone-userdebug/latest/$CUTTLEFISH_ZIP',timeout=30).read(1<<20).decode()
url=json.loads(re.search(r'var JSVariables = (\{.*?\});',html).group(1))['artifactUrl']
# Only accept a Google host (the download is checksum pinned too).
u=urllib.parse.urlsplit(url); host=(u.hostname or '').lower()
if u.scheme!='https' or not any(host==d or host.endswith('.'+d) for d in ('googleapis.com','googleusercontent.com','google.com','android.com')):
    sys.exit('unexpected Cuttlefish artifact URL: '+url)
print(url)
PY
)"
  fetch_big "$url" "$DOWNLOADS/$CUTTLEFISH_ZIP" "$CUTTLEFISH_SHA256"
fi
if [ ! -f "$WORK/cuttlefish/manifest.json" ] || [ ! -f "$WORK/cuttlefish/bluetooth/android.hardware.bluetooth-service.cuttlefish" ]; then
  PATH="$(brew --prefix erofs-utils)/bin:$(brew --prefix e2fsprogs)/sbin:$PATH" \
    python3 "$ROOT/tools/unpack_cuttlefish.py" "$DOWNLOADS/$CUTTLEFISH_ZIP" "$WORK/cuttlefish"
fi

say "Googlebook recovery image (7.6 GB download, 19 GB unpacked)"
if [ ! -f "$WORK/googlebook/mica-recovery.raw" ]; then
  fetch_big "$GOOGLEBOOK_URL" "$DOWNLOADS/mica-recovery.zip" "$GOOGLEBOOK_ZIP_SHA256"
  mkdir -p "$WORK/googlebook"
  python3 - "$DOWNLOADS/mica-recovery.zip" "$WORK/googlebook/mica-recovery.raw" "$GOOGLEBOOK_RAW_SHA256" <<'PY'
import hashlib,os,sys,zipfile
src,dst,want=sys.argv[1:4];h=hashlib.sha256()
with zipfile.ZipFile(src) as z, z.open('android-desktop_signed_recovery_image.bin') as f, open(dst+'.part','wb') as out:
    while b:=f.read(8<<20): out.write(b);h.update(b)
if h.hexdigest()!=want: os.unlink(dst+'.part'); sys.exit('extracted image does not match the pinned checksum')
os.rename(dst+'.part',dst)
PY
fi
say "Fetch complete"
