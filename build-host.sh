#!/bin/bash
# Build the Mac-side pieces: the patched virglrenderer (Venus + Android buffer sharing),
# a copy of UTM's QEMU library that loads it, and the small QEMU launcher.
# Output: $WORK/host/{qemu-interop,qemu-aarch64-softmmu,libvirglrenderer.1.dylib,virgl_render_server}
. "$(dirname "$0")/lib.sh"
no_running_vm
need git "Xcode command line tools"; need clang "Xcode command line tools"
need python3 "Homebrew or Xcode"; need pkg-config "brew install pkg-config"
FW="$UTM_BETA_APP/Contents/Frameworks"
[ -d "$FW/qemu-aarch64-softmmu.framework" ] || die "UTM 5 beta not found at $UTM_BETA_APP (set UTM_BETA_APP)"
if [ ! -d "$MESA_SRC/include/KHR" ]; then
  say "Mesa source (Khronos headers)"
  fetch "$MESA_URL" "$WORK/downloads/mesa-26.2.4.tar.xz" "$MESA_SHA256"
  mkdir -p "$(dirname "$MESA_SRC")"; tar -xf "$WORK/downloads/mesa-26.2.4.tar.xz" -C "$(dirname "$MESA_SRC")"
fi
mkdir -p "$WORK/src" "$WORK/build" "$WORK/host" "$WORK/pkgconfig"

say "Python build environment (meson, ninja)"
# Rebuild when the pinned list changes.
REQ_HASH="$(shasum -a 256 "$ROOT/host/requirements-build.txt" | cut -d' ' -f1)"
if [ ! -x "$WORK/env/bin/meson" ] || [ "$(cat "$WORK/env/.requirements-sha256" 2>/dev/null || true)" != "$REQ_HASH" ]; then
  rm -rf "$WORK/env"
  python3 -m venv "$WORK/env"
  "$WORK/env/bin/pip" -q install --require-hashes -r "$ROOT/host/requirements-build.txt"
  echo "$REQ_HASH" > "$WORK/env/.requirements-sha256"
fi
export PATH="$WORK/env/bin:$PATH" CCACHE_DISABLE=1

say "libepoxy headers matching UTM's bundled epoxy"
# Only the generated headers are needed; the library itself comes from the UTM frameworks.
checkout "$EPOXY_REPO" "$EPOXY_COMMIT" "$WORK/src/libepoxy"
[ -f "$WORK/build/libepoxy/build.ninja" ] || meson setup "$WORK/build/libepoxy" "$WORK/src/libepoxy" \
  -Dtests=false -Dglx=no -Degl=yes -Dx11=false >/dev/null
ninja -j "$JOBS" -C "$WORK/build/libepoxy" include/epoxy/gl_generated.h include/epoxy/egl_generated.h \
  include/epoxy/gl_angle_ext_generated.h include/epoxy/egl_angle_ext_generated.h >/dev/null

cat > "$WORK/pkgconfig/epoxy.pc" <<PC
Name: epoxy
Description: UTM's bundled epoxy with matching generated headers
Version: 1.5.10
epoxy_has_egl=1
epoxy_has_glx=0
Cflags: -I$MESA_SRC/include -I$WORK/src/libepoxy/include -I$WORK/build/libepoxy/include
Libs: -F$FW -framework epoxy.0
PC
cat > "$WORK/pkgconfig/vulkan.pc" <<PC
Name: vulkan
Description: UTM's bundled Vulkan loader
Version: 1.4.0
Libs: -F$FW -framework vulkan.1
PC

say "virglrenderer (UTM fork) with the Android interop patch"
checkout "$VIRGL_REPO" "$VIRGL_COMMIT" "$WORK/src/virglrenderer"
apply_patch "$WORK/src/virglrenderer" "$ROOT/patches/virglrenderer-android-interop.patch"
[ -f "$WORK/build/virglrenderer/build.ninja" ] || PKG_CONFIG_PATH="$WORK/pkgconfig" meson setup \
  "$WORK/build/virglrenderer" "$WORK/src/virglrenderer" --buildtype=release \
  -Dvenus=true -Dneptune=true -Dvulkan-dload=false -Dplatforms=egl -Dtests=false -Dvtest=false \
  -Dcheck-gl-errors=false --prefix="$WORK/sysroot" >/dev/null
ninja -j "$JOBS" -C "$WORK/build/virglrenderer" >/dev/null
cp "$WORK/build/virglrenderer/src/libvirglrenderer.1.dylib" "$WORK/build/virglrenderer/server/virgl_render_server" "$WORK/host/"

say "QEMU library that loads the patched renderer"
# UTM's QEMU links virglrenderer as a framework; repoint that one load command at our build.
cp "$FW/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu" "$WORK/host/qemu-aarch64-softmmu"
chmod u+w "$WORK/host/qemu-aarch64-softmmu"
install_name_tool -change @rpath/virglrenderer.1.framework/Versions/A/virglrenderer.1 \
  @loader_path/libvirglrenderer.1.dylib "$WORK/host/qemu-aarch64-softmmu" 2>/dev/null
otool -arch arm64 -L "$WORK/host/qemu-aarch64-softmmu" | grep -q "@loader_path/libvirglrenderer.1.dylib" \
  || die "could not repoint QEMU at the patched renderer"
codesign --force --sign - "$WORK/host/qemu-aarch64-softmmu" 2>/dev/null

say "QEMU launcher with the hypervisor entitlement"
clang -O2 "$ROOT/host/qemu-launcher.c" -o "$WORK/host/qemu-interop"
codesign --force --sign - --entitlements "$ROOT/host/hypervisor.entitlements.plist" "$WORK/host/qemu-interop" 2>/dev/null

say "Googlebook VM app"
checkout "$COCOASPICE_REPO" "$COCOASPICE_COMMIT" "$WORK/src/CocoaSpice"
apply_patch "$WORK/src/CocoaSpice" "$ROOT/patches/cocoaspice-viewer.patch"
rm -rf "$WORK/host/Googlebook Viewer.app"
python3 "$ROOT/host/build_viewer.py" "$WORK/src/CocoaSpice" "$FW" "$ROOT/host/viewer.m" "$WORK/host" "$ROOT/run" "$WORK" >/dev/null

say "Host build complete: $WORK/host"
ls -l "$WORK/host"
