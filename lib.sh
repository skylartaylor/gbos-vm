# Shared settings for the Googlebook-on-Apple-Silicon build scripts. Source, don't run.
set -Eeuo pipefail
# Never stop without saying where: any command that ends the script prints its location.
trap 'rc=$?; [ "$BASH_SUBSHELL" -gt 0 ] || { printf "error: %s stopped at line %s (exit %s)\n" "${BASH_SOURCE[0]##*/}" "$LINENO" "$rc" >&2; printf "error: command: %s\n" "$BASH_COMMAND" >&2; }' ERR
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
WORK="${GOOGLEBOOK_WORK:-$ROOT/work}"
BUILD_REQUIREMENTS="${GBOS_BUILD_REQUIREMENTS:-$ROOT/host/requirements-build.txt}"
[ -f "$BUILD_REQUIREMENTS" ] || BUILD_REQUIREMENTS="$ROOT/requirements-build.txt"
# UTM 5.0.7 beta app bundle: supplies QEMU and the epoxy, Vulkan, MoltenVK and ANGLE frameworks.
UTM_BETA_APP="${UTM_BETA_APP:-$WORK/UTM-beta/UTM.app}"
# Mesa source tree: supplies Khronos headers for the host build and is the guest driver source.
MESA_SRC="${MESA_SRC:-$WORK/src/mesa-26.2.4}"
VIRGL_REPO="https://github.com/utmapp/virglrenderer.git"
VIRGL_COMMIT="5d26f605f50f8e22002ec6db5fb775e1992d4e96"
EPOXY_REPO="https://github.com/utmapp/libepoxy.git"
EPOXY_COMMIT="bf98587477fe68d07b93319ece7b40a7d0e2eabe"
# Build Mac binaries that also run on older macOS, not only the version they were built on.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
# Parallel build jobs. Kept low on purpose: an uncapped Mesa build needs far more RAM.
JOBS="${GBOS_JOBS:-4}"
find_build_python() {
  local candidate minor
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  for minor in 20 19 18 17 16 15 14 13 12 11 10; do
    candidate="python3.$minor"
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}
python_version() { "$1" -c 'import sys; print("%d.%d" % sys.version_info[:2])'; }
run_logged() { # logfile label command...
  local logfile="$1" label="$2" rc
  shift 2
  if "$@" >"$logfile" 2>&1; then return 0; else rc=$?; fi
  printf 'error: %s failed (exit %s); last output:\n' "$label" "$rc" >&2
  tail -40 "$logfile" >&2 || true
  die "$label failed; full log: $logfile"
}
ensure_build_env() {
  local interpreter version existing_version
  if [ "${GBOS_BUILD_ENV_READY:-}" = 1 ] && [ -x "${BUILD_ENV_DIR:-}/bin/python" ]; then
    case ":$PATH:" in *":$BUILD_ENV_DIR/bin:"*) ;; *) export PATH="$BUILD_ENV_DIR/bin:$PATH" ;; esac
    return 0
  fi

  interpreter="$(find_build_python)" || die "Python 3.10 or newer is required; install it with 'brew install python'"
  version="$(python_version "$interpreter")"
  if [ -x "$WORK/env/bin/python" ] && "$WORK/env/bin/python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
    BUILD_ENV_DIR="$WORK/env"
    existing_version="$(python_version "$BUILD_ENV_DIR/bin/python")"
    say "Python build environment (existing Python $existing_version)"
  else
    BUILD_ENV_DIR="$WORK/env-py$version"
    say "Python build environment (Python $version)"
  fi

  mkdir -p "$WORK/build"
  if [ ! -x "$BUILD_ENV_DIR/bin/python" ]; then
    "$interpreter" -m venv "$BUILD_ENV_DIR" || die "could not create Python environment at $BUILD_ENV_DIR"
  fi
  if ! "$BUILD_ENV_DIR/bin/python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' >/dev/null 2>&1; then
    die "$BUILD_ENV_DIR exists but does not contain a working Python 3.10+ environment; move it aside and retry"
  fi
  if ! "$BUILD_ENV_DIR/bin/python" -m pip --version >/dev/null 2>&1; then
    "$BUILD_ENV_DIR/bin/python" -m ensurepip --upgrade || die "could not initialize pip in $BUILD_ENV_DIR"
  fi
  local req_hash pip_flags=()
  req_hash="$(shasum -a 256 "$BUILD_REQUIREMENTS" | cut -d' ' -f1)"
  if grep -q -- '--hash=' "$BUILD_REQUIREMENTS"; then
    pip_flags+=(--require-hashes)
  fi
  if [ ! -f "$BUILD_ENV_DIR/.requirements-sha256" ] || [ "$(cat "$BUILD_ENV_DIR/.requirements-sha256" 2>/dev/null || true)" != "$req_hash" ]; then
    run_logged "$WORK/build/python-requirements.log" "Python build requirements installation" \
      "$BUILD_ENV_DIR/bin/python" -m pip install --disable-pip-version-check "${pip_flags[@]}" -r "$BUILD_REQUIREMENTS"
    echo "$req_hash" > "$BUILD_ENV_DIR/.requirements-sha256"
  fi
  "$BUILD_ENV_DIR/bin/python" -m pip check || die "Python build environment has inconsistent packages"
  "$BUILD_ENV_DIR/bin/python" -c 'import mako, packaging, yaml'
  [ "$("$BUILD_ENV_DIR/bin/meson" --version)" = "1.12.1" ] || die "expected Meson 1.12.1 in $BUILD_ENV_DIR"
  [ "$("$BUILD_ENV_DIR/bin/python" -c 'from importlib.metadata import version; print(version("ninja"))')" = "1.13.2" ] \
    || die "expected the Ninja 1.13.2 package in $BUILD_ENV_DIR"
  export BUILD_ENV_DIR GBOS_BUILD_ENV_READY=1
  case ":$PATH:" in *":$BUILD_ENV_DIR/bin:"*) ;; *) export PATH="$BUILD_ENV_DIR/bin:$PATH" ;; esac
}
# Rebuilding replaces signed binaries and the disk image. Doing that under a running VM gets
# its processes killed by macOS ("Code Signature Invalid") or pulls the disk out from under it.
no_running_vm() {
  if /bin/ps -axo args= | grep -F "$WORK/host/qemu-interop" | grep -qv grep; then
    die "a VM from $WORK is running. Quit it first; rebuilding under it would crash it."
  fi
}
say() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing prerequisite: $1 ($2)"; }
# Check out one exact commit of a repository into a directory (idempotent).
checkout() { # url commit dir
  if [ ! -d "$3/.git" ]; then git init -q "$3"; git -C "$3" remote add origin "$1"; fi
  if [ "$(git -C "$3" rev-parse HEAD 2>/dev/null || true)" != "$2" ]; then
    git -C "$3" fetch -q --depth 1 origin "$2"; git -C "$3" checkout -q --force FETCH_HEAD
  fi
}
COCOASPICE_REPO="https://github.com/utmapp/CocoaSpice.git"
COCOASPICE_COMMIT="d8d29fc810047a3ddcebb351cdadc8fe4b4f308d"
# Make a pinned checkout carry exactly this patch: if it is not already applied as-is (first
# run, or the patch changed since), reset the tree to the pinned commit and apply it.
apply_patch() { # repo patch
  if ! git -C "$1" apply --reverse --check "$2" 2>/dev/null; then
    git -C "$1" checkout -q --force HEAD -- .; git -C "$1" clean -qfd
    git -C "$1" apply "$2"
  fi
}
MESA_URL="https://archive.mesa3d.org/mesa-26.2.4.tar.xz"
MESA_SHA256="bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9"
BISON_URL="https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz"
BISON_SHA256="9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"
LIBSEPOL_SHA256="79f3d2c88f44b7eb5cf54d9792e03232297e17f97a179163f2750099a00f164d"
LIBSEPOL_URL="https://github.com/SELinuxProject/selinux/releases/download/3.11/libsepol-3.11.tar.gz"
# Download once and verify against a pinned checksum.
fetch() { # url dest sha256
  [ -n "$3" ] || die "no pinned checksum for $1"
  if [ ! -f "$2" ]; then mkdir -p "$(dirname "$2")"; curl -fL --proto =https --proto-redir =https --retry 3 -o "$2.part" "$1"; mv "$2.part" "$2"; fi
  local got; got="$(shasum -a 256 "$2" | cut -d' ' -f1)"
  [ "$got" = "$3" ] || die "checksum mismatch for $2 (got $got)"
}
GOOGLEBOOK_URL="https://dl.google.com/device/recovery/quartz-user/16471258/recovery.zip"
GOOGLEBOOK_ZIP_SHA256="3ba358a46c3c61d1a8b4b34e81c11227d7b45207e90440556fb77b6e021c9363"
GOOGLEBOOK_RAW_SHA256="9e8674c98796f78b2abe9d5ee0bdd3f31602bd452e3c2799f647849beb53b0c5"
CUTTLEFISH_BUILD="16373615"
CUTTLEFISH_ZIP="aosp_cf_arm64_only_phone-img-16373615.zip"
CUTTLEFISH_SHA256="051caf8072ba9fb417e05999de2984752e44e13ce70b6c49c669f0a73db85c18"
UTM_DMG_URL="https://github.com/utmapp/UTM/releases/download/v5.0.7/UTM.dmg"
UTM_DMG_SHA256="80c2161cae4c1711ae364ed99de8a0e92396287abf85eb583426c7627d039ad9"
# Large downloads go here; point GOOGLEBOOK_DOWNLOADS at an existing folder to reuse them.
DOWNLOADS="${GOOGLEBOOK_DOWNLOADS:-$WORK/downloads}"
# Resumable download of a large file, then checksum verification.
fetch_big() { # url dest sha256
  [ -n "$3" ] || die "no pinned checksum for $1"
  if [ ! -f "$2" ]; then mkdir -p "$(dirname "$2")"; curl -fL --proto =https --proto-redir =https --retry 5 -C - -o "$2.part" "$1"; mv "$2.part" "$2"; fi
  echo "verifying $(basename "$2")"
  [ "$(shasum -a 256 "$2" | cut -d' ' -f1)" = "$3" ] || die "checksum mismatch for $2"
}

# Android toolchain discovery, shared by prereqs.sh and build-guest.sh. Sets ANDROID_SDK,
# ANDROID_NDK, D8, ANDROID_JAR and JAVA_HOME to what it finds (empty when missing).
NDK_TESTED=28.2.13676358
newest() { ls -d "$@" 2>/dev/null | sort -V | tail -1 || true; }
find_android() {
  local c
  if [ -z "${ANDROID_SDK:-}" ]; then
    for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" \
             "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/share/android-commandlinetools"; do
      if [ -n "$c" ] && [ -d "$c" ]; then ANDROID_SDK="$c"; break; fi
    done
  fi
  ANDROID_SDK="${ANDROID_SDK:-$HOME/Library/Android/sdk}"
  # NDK 28.2 is what this is developed against. If it isn't installed, use the newest one that is.
  if [ -z "${ANDROID_NDK:-}" ]; then
    ANDROID_NDK="$ANDROID_SDK/ndk/$NDK_TESTED"
    [ -d "$ANDROID_NDK" ] || ANDROID_NDK="$(newest "$ANDROID_SDK"/ndk/[0-9]*)"
  fi
  [ -x "$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android35-clang" ] || ANDROID_NDK=""
  D8="$(newest "$ANDROID_SDK"/build-tools/*/d8)"
  ANDROID_JAR="$(newest "$ANDROID_SDK"/platforms/android-3[4-9]*/android.jar "$ANDROID_SDK"/platforms/android-[4-9][0-9]*/android.jar)"
  if [ ! -x "${JAVA_HOME:-}/bin/javac" ]; then
    JAVA_HOME=""
    for c in "/Applications/Android Studio.app/Contents/jbr/Contents/Home" "$(/usr/libexec/java_home 2>/dev/null || true)" \
             "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/opt/openjdk"; do
      if [ -x "$c/bin/javac" ]; then JAVA_HOME="$c"; break; fi
    done
  fi
  export ANDROID_SDK ANDROID_NDK D8 ANDROID_JAR JAVA_HOME
}
