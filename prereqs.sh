#!/bin/bash
# Check that everything the build needs is installed, before anything is downloaded.
#   ./prereqs.sh            list what is present and what is missing; offer to install the rest
#   ./prereqs.sh --install  install what is missing without asking
#   ./prereqs.sh --check    only report (exit 1 if something is missing)
# What it can install: Homebrew packages, a JDK, and the Android SDK pieces (through Google's
# sdkmanager, which shows you its licence to accept). It never uses sudo. Xcode's command
# line tools and Homebrew itself need you: it prints the command.
. "$(dirname "$0")/lib.sh"
MODE="${1:-ask}"
BREW_FORMULAE="erofs-utils e2fsprogs lz4 pkgconf"
SDK_BUILD_TOOLS="build-tools;36.0.0"; SDK_PLATFORM="platforms;android-36"

missing=(); manual=()
ok()   { printf '  ok       %s\n' "$*"; }
miss() { printf '  MISSING  %s\n' "$1"; missing+=("$2"); }

survey() {
  local build_python
  missing=(); manual=()
  say "Checking prerequisites"
  if [ "$(uname -m)" = arm64 ]; then ok "Apple Silicon Mac"; else printf '  MISSING  Apple Silicon Mac (this is %s)\n' "$(uname -m)"; manual+=("This only runs on Apple Silicon Macs."); fi
  if xcode-select -p >/dev/null 2>&1 && command -v clang >/dev/null && command -v git >/dev/null; then ok "Xcode command line tools"
  else printf '  MISSING  Xcode command line tools\n'; manual+=("Install the Xcode command line tools:  xcode-select --install"); fi
  if command -v brew >/dev/null; then ok "Homebrew"
  else printf '  MISSING  Homebrew\n'; manual+=("Install Homebrew (it asks for your password), see https://brew.sh"); fi
  if command -v brew >/dev/null; then
    for f in $BREW_FORMULAE; do
      if brew list --formula "$f" >/dev/null 2>&1; then ok "$f"; else miss "$f (Homebrew)" "brew:$f"; fi
    done
  fi
  if build_python="$(find_build_python)"; then ok "Python build runtime ($(python_version "$build_python"))"
  else miss "Python 3.10 or newer" "brew:python"; fi
  find_android
  if [ -n "$JAVA_HOME" ]; then ok "JDK ($JAVA_HOME)"; else miss "a JDK" "brew:openjdk"; fi
  if [ -n "$ANDROID_NDK" ]; then ok "Android NDK ($(basename "$ANDROID_NDK"))"; else miss "Android NDK (under $ANDROID_SDK/ndk)" "sdk:ndk;$NDK_TESTED"; fi
  if [ -n "$D8" ]; then ok "Android build-tools ($(basename "$(dirname "$D8")"))"; else miss "Android build-tools" "sdk:$SDK_BUILD_TOOLS"; fi
  if [ -n "$ANDROID_JAR" ]; then ok "Android platform ($(basename "$(dirname "$ANDROID_JAR")"))"; else miss "Android platform (API 34 or newer)" "sdk:$SDK_PLATFORM"; fi
  if [ -x "$ANDROID_SDK/emulator/netsimd" ] || [ -x "${GBOS_NETSIMD:-}" ]; then ok "Android Emulator (virtual Bluetooth radio)"
  else printf '  optional Android Emulator: not installed, so the VM will have no Bluetooth (it is the "emulator" package in the SDK)\n'; optional_emulator=1; fi
}

find_sdkmanager() {
  local c
  for c in "${SDKMANAGER:-}" "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" "$(command -v sdkmanager || true)" \
           "$(brew --prefix)/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"; do
    if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return; fi
  done
}

install_missing() {
  local brews=() sdks=() item
  for item in "${missing[@]}"; do
    case "$item" in brew:*) brews+=("${item#brew:}") ;; sdk:*) sdks+=("${item#sdk:}") ;; esac
  done
  if [ "${#brews[@]}" -gt 0 ]; then say "Homebrew: ${brews[*]}"; brew install -q "${brews[@]}"; fi
  if [ "${#sdks[@]}" -gt 0 ]; then
    find_android
    [ -n "$JAVA_HOME" ] || die "no JDK found even after installing one; set JAVA_HOME"
    local sdkmanager; sdkmanager="$(find_sdkmanager)"
    if [ -z "$sdkmanager" ]; then
      say "Android command line tools (Homebrew cask)"
      brew install -q --cask android-commandlinetools
      [ -d "$ANDROID_SDK" ] || ANDROID_SDK="$(brew --prefix)/share/android-commandlinetools"
      sdkmanager="$(find_sdkmanager)"; [ -n "$sdkmanager" ] || die "sdkmanager still not found after installing android-commandlinetools"
    fi
    [ "${optional_emulator:-0}" = 1 ] && sdks+=("emulator")
    say "Android SDK packages into $ANDROID_SDK: ${sdks[*]}"
    echo "Google's sdkmanager will ask you to accept its licences."
    mkdir -p "$ANDROID_SDK"
    "$sdkmanager" --sdk_root="$ANDROID_SDK" "${sdks[@]}"
  fi
}

survey
if [ "${#manual[@]}" -gt 0 ]; then
  say "These need you"
  printf '  %s\n' "${manual[@]}"
  die "fix the above, then run this again"
fi
if [ "${#missing[@]}" -eq 0 ]; then say "Everything needed is installed"; exit 0; fi
[ "$MODE" = --check ] && die "${#missing[@]} thing(s) missing; run ./prereqs.sh to install them"
if [ "$MODE" != --install ]; then
  [ -t 0 ] || die "${#missing[@]} thing(s) missing; run ./prereqs.sh --install (or install them yourself)"
  printf '\nInstall the missing items now (Homebrew and Google sdkmanager, no sudo)? [y/N] '
  read -r answer; case "$answer" in y|Y|yes) ;; *) die "nothing installed" ;; esac
fi
install_missing
survey
[ "${#missing[@]}" -eq 0 ] || die "still missing after installing: ${missing[*]}"
say "Everything needed is installed"
