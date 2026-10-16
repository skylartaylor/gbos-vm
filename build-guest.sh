#!/bin/bash
# Build the pieces that go inside the guest image, plus the host-side SELinux policy tool:
#   Mesa VirGL GLES libraries, Mesa Venus Vulkan driver (with the Android mapper patch),
#   the pointer/clipboard helper, a Vulkan self-test, and guest_graphics_memfd_policy.
# Needs the Android NDK, SDK build-tools and platform, and a JDK. Output: $WORK/guest, $WORK/tools.
. "$(dirname "$0")/lib.sh"
find_android
[ -n "$ANDROID_NDK" ] && [ -n "$D8" ] && [ -n "$ANDROID_JAR" ] && [ -n "$JAVA_HOME" ] \
  || die "Android build tools are missing. Run ./prereqs.sh to see what, and to install it."
[ "$(basename "$ANDROID_NDK")" = "$NDK_TESTED" ] || echo "note: NDK $NDK_TESTED not installed; using $(basename "$ANDROID_NDK")"
NDK_BIN="$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
ensure_build_env
export CCACHE_DISABLE=1
mkdir -p "$WORK/src" "$WORK/build" "$WORK/guest/mesa-runtime" "$WORK/tools" "$WORK/android-pkgconfig"

say "bison 3 (macOS ships 2.3, which cannot process Mesa's grammars)"
BREW_BISON="$(brew --prefix bison 2>/dev/null || true)/bin"
if [ -x "$BREW_BISON/bison" ]; then BISON_DIR="$BREW_BISON"
else
  BISON_DIR="$WORK/tools/bison/bin"
  if [ ! -x "$BISON_DIR/bison" ]; then
    fetch "$BISON_URL" "$WORK/downloads/bison-3.8.2.tar.xz" "$BISON_SHA256"
    tar -xf "$WORK/downloads/bison-3.8.2.tar.xz" -C "$WORK/src"
    (cd "$WORK/src/bison-3.8.2" && ./configure --prefix="$WORK/tools/bison" --disable-nls >"$WORK/build/bison.log" 2>&1 \
      && make -j "$JOBS" >>"$WORK/build/bison.log" 2>&1 && make install >>"$WORK/build/bison.log" 2>&1) || { tail -20 "$WORK/build/bison.log"; die "bison build failed"; }
  fi
fi
export PATH="$BISON_DIR:$PATH"
bison --version | head -1

say "Mesa source"
fetch "$MESA_URL" "$WORK/downloads/mesa-26.2.4.tar.xz" "$MESA_SHA256"
[ -d "$MESA_SRC" ] || tar -xf "$WORK/downloads/mesa-26.2.4.tar.xz" -C "$(dirname "$MESA_SRC")"

cat > "$WORK/android-aarch64.cross" <<CROSS
[constants]
ndk = '$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64'
[binaries]
c = ndk / 'bin/aarch64-linux-android35-clang'
cpp = [ndk / 'bin/aarch64-linux-android35-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
ar = ndk / 'bin/llvm-ar'
strip = ndk / 'bin/llvm-strip'
c_ld = 'lld'
cpp_ld = 'lld'
pkg-config = '$(command -v pkg-config)'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$WORK/android-pkgconfig'
CROSS
COMMON=(--cross-file "$WORK/android-aarch64.cross" --buildtype=release -Dforce_fallback_for=libdrm,expat
  -Dallow-fallback-for=libdrm -Dplatforms=android -Dplatform-sdk-version=35 -Dandroid-stub=true
  -Dandroid-libbacktrace=disabled -Dllvm=disabled -Dglx=disabled -Dgbm=disabled -Dvideo-codecs=
  -Dgallium-va=disabled -Dzstd=disabled)

say "Mesa VirGL GLES libraries (unpatched source)"
if [ ! -f "$WORK/build/mesa-gles/build.ninja" ]; then
  run_logged "$WORK/build/mesa-gles.configure.log" "Mesa GLES Meson setup" meson setup \
    "$WORK/build/mesa-gles" "$MESA_SRC" "${COMMON[@]}" \
    -Dgallium-drivers=virgl -Dvulkan-drivers= -Degl=enabled -Dgles1=enabled -Dgles2=enabled -Dopengl=true \
    -Degl-lib-suffix=_virgl -Dgles-lib-suffix=_virgl
fi
run_logged "$WORK/build/mesa-gles.build.log" "Mesa GLES build" ninja -j "$JOBS" -C "$WORK/build/mesa-gles"
for pair in src/egl/libEGL_virgl.so src/mesa/glapi/es1api/libGLESv1_CM_virgl.so src/mesa/glapi/es2api/libGLESv2_virgl.so \
            src/gallium/targets/dri/libgallium_dri.so subprojects/libdrm-2.4.133/libdrm.so; do
  "$NDK_BIN/llvm-strip" --strip-unneeded -o "$WORK/guest/mesa-runtime/$(basename "$pair")" "$WORK/build/mesa-gles/$pair"
done

say "Mesa Venus Vulkan driver (with the Android mapper patch)"
# A separate copy of the tree, so the GLES build above stays on unpatched source as tested.
VENUS_SRC="$WORK/src/mesa-26.2.4-venus"
PATCH_ID="$(shasum -a 256 "$ROOT/patches/mesa-android-mapper5.patch" | cut -d' ' -f1)"
if [ "$(cat "$VENUS_SRC/.gbos-patch" 2>/dev/null)" != "$PATCH_ID" ]; then
  # First run, or the patch changed: start again from the unpatched tree.
  rm -rf "$VENUS_SRC" "$WORK/build/mesa-venus"
  cp -c -R "$MESA_SRC" "$VENUS_SRC" 2>/dev/null || cp -R "$MESA_SRC" "$VENUS_SRC"
  patch -s -p1 -d "$VENUS_SRC" < "$ROOT/patches/mesa-android-mapper5.patch"
  echo "$PATCH_ID" > "$VENUS_SRC/.gbos-patch"
fi
if [ ! -f "$WORK/build/mesa-venus/build.ninja" ]; then
  run_logged "$WORK/build/mesa-venus.configure.log" "Mesa Venus Meson setup" meson setup \
    "$WORK/build/mesa-venus" "$VENUS_SRC" "${COMMON[@]}" \
    --wrap-mode=nodownload -Dgallium-drivers= -Dvulkan-drivers=virtio -Degl=disabled -Dgles1=disabled \
    -Dgles2=disabled -Dopengl=false
fi
run_logged "$WORK/build/mesa-venus.build.log" "Mesa Venus build" ninja -j "$JOBS" -C "$WORK/build/mesa-venus" \
  src/virtio/vulkan/libvulkan_virtio.so
cp "$WORK/build/mesa-venus/src/virtio/vulkan/libvulkan_virtio.so" "$WORK/guest/libvulkan_virtio.so"

say "Pointer and clipboard helper"
rm -rf "$WORK/build/input"; mkdir -p "$WORK/build/input"
"$JAVA_HOME/bin/javac" -source 11 -target 11 -Xlint:-options -cp "$ANDROID_JAR" -d "$WORK/build/input" "$ROOT/guest/input/vm/Input.java"
"$D8" --min-api 34 --lib "$ANDROID_JAR" --output "$WORK/guest/vm-input.jar" "$WORK"/build/input/vm/*.class

say "Guest Vulkan self-test"
"$NDK_BIN/aarch64-linux-android35-clang" -O2 -I"$MESA_SRC/include/drm-uapi" "$ROOT/guest/guest_vulkan_probe.c" \
  -lvulkan -lnativewindow -lEGL -lGLESv2 -o "$WORK/guest/guest-vulkan-probe"

say "SELinux policy tool (runs on the Mac while the image is assembled)"
fetch "$LIBSEPOL_URL" "$WORK/downloads/libsepol-3.11.tar.gz" "${LIBSEPOL_SHA256:-}"
[ -d "$WORK/src/libsepol-3.11" ] || tar -xzf "$WORK/downloads/libsepol-3.11.tar.gz" -C "$WORK/src"
[ -f "$WORK/src/libsepol-3.11/src/libsepol.a" ] || make -s -C "$WORK/src/libsepol-3.11/src" libsepol.a \
  CFLAGS="-O2 -Wno-error -D_DARWIN_C_SOURCE" >"$WORK/build/libsepol.build.log" 2>&1 || { tail -20 "$WORK/build/libsepol.build.log"; die "libsepol build failed"; }
cc -O2 -I"$WORK/src/libsepol-3.11/include" "$ROOT/tools-src/guest_graphics_memfd_policy.c" \
  "$WORK/src/libsepol-3.11/src/libsepol.a" -o "$WORK/tools/guest_graphics_memfd_policy"

say "Guest build complete"
ls -l "$WORK/guest" "$WORK/guest/mesa-runtime" "$WORK/tools"
