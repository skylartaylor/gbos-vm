# gbos-vm

Runs a real Googlebook OS image in a VM on an Apple Silicon Mac — GPU-accelerated, with Chrome working.

It's not an emulator image or a generic Android build. The install script downloads Google's own recovery image for the Dell Googlebook (ARM64, Android 17), swaps the hardware-specific bits for virtual ones, and boots it under QEMU with Vulkan passed through to Metal.

> This isn't affiliated with Google or Dell, and it's not a verified Googlebook. Read [System Structure](#system-structure) before you sign into anything.

## Quick start

```bash
git clone https://github.com/skylartaylor/gbos-vm.git
cd gbos-vm
./install.sh
```

Then open the app it built:

```bash
open "work/host/Googlebook VM.app"
```

Drag that into your Dock if you want it there. It boots the VM when you open it and shuts Android down properly when you quit.

The first boot takes about 45 seconds on a M5 MacBook. If you land on a user picker, click **User** — there's no password.

`install.sh` downloads about 9 GB and wants 60 GB free. On an M5 MacBook the build part takes around five minutes; the downloads take however long your connection takes.

## What you need

- An **Apple Silicon Mac**. Intel Macs won't work — this is an ARM guest running on the hypervisor, not emulation.
- **16 GB of RAM**, realistically. The VM gets 4 GB and the builds want a few more.
- **Xcode command line tools** and **[Homebrew](https://brew.sh)**.
- The **Android SDK** with an NDK, a build-tools version, and a platform (API 34+). Android Studio's defaults are fine. We build with NDK `28.2.13676358`; if you don't have that one the script uses your newest (30 is reported to work), or set `ANDROID_NDK` to pick.
- A **JDK**. If you have Android Studio, its bundled one gets picked up automatically.

The script installs `erofs-utils`, `e2fsprogs`, `lz4` and `pkgconf` from Homebrew if they're missing. It never asks for `sudo`.

We build and test on one machine (M5, 16 GB, macOS 27). A couple of people have reported it working on M4 Macs too — if you try it on something else, tell us how it went.

## Using it

| Shortcut | What it does |
|---|---|
| `⌃⌘F` | Full screen |
| `⌃⌘M` | Cycle pointer modes |
| `⌃⌥` | Release a captured mouse |
| `⌃⌘R` | Restart the VM |
| `⌘V` | Paste the Mac clipboard into the guest |
| `⌘,` | Settings |

Quitting (or closing the window) shuts Android down properly. Your data lives in `work/image/googlebook.raw` and sticks around between runs.

**Settings** (`⌘,`) has the pointer mode, resolution, memory, CPU cores, and toggles for networking, audio and the camera. Pointer mode changes right away; everything else is a VM option, so it applies the next time you start it.

Resolution defaults to your display's native pixels at 16:10. On a notched MacBook that's exactly the area below the notch, so full screen is pixel-for-pixel.

If you'd rather drive it from a terminal, `python3 run/launch.py work` does the same thing and takes `--display 1920x1200` and `--fullscreen`.

### Pointer modes

**Captured mouse** is the default: click the window to grab the mouse, `⌃⌥` to let go. It's the classic VM experience — a plain USB mouse as far as Android is concerned, so it behaves.

There are two integrated modes where the pointer moves in and out of the window freely. They're labelled **experimental** because they're still kind of buggy:

- **Android cursor.** The guest draws the pointer, so it changes shape properly (I-beams, resize arrows). It trails your hand a little, and Android sees it as a stylus, which gets weird in places.
- **Mac cursor.** Instant, but it's always an arrow.

Switch in the **Pointer** menu, in Settings, or with `⌃⌘M`. Your choice is remembered, and clipboard sync works in all three.

### Camera

Android sees your Mac's camera as a plugged-in USB webcam ("Mac Camera"), offered at 1280×720, 1920×1080 and 640×480, 30 fps. The first time an Android app opens it, macOS asks whether **Googlebook VM** may use the camera. The Mac camera (and its green light) only runs while an app is actually streaming from it, and switches off a few seconds after the app stops. Turn it off entirely in Settings.

The built-in Camera app shows a live preview. Apps that draw camera frames themselves with OpenGL ES may still show black — see [What doesn't work yet](#what-doesnt-work-yet).

The camera needs all three builds from this change: `build-host.sh` (the renderer), `build-guest.sh` (the guest Vulkan driver) and `build-image.sh` (which passes `--camera`). An older image just won't list a camera. `python3 run/vm_control.py work/logs/<run> VM_CAMERA_DIAG` prints what the guest sees.

## System Structure

The image starts as Google's unmodified recovery download. We don't touch the system partitions — but Googlebook OS expects hardware our VM doesn't have (a TPM, Trusty, a Qualcomm DSP, a specific GPU), so the **vendor partition gets rebuilt** with virtual-device replacements from Google's own Cuttlefish project:

- **Software KeyMint and Gatekeeper** instead of hardware-backed ones. Your keys aren't protected by a secure element, because there isn't one.
- **No verified boot on the vendor partition.** The other partitions keep their original verity; the one we modify can't.
- **Three extra SELinux rules**, all narrowly about graphics buffer sharing. SELinux stays enforcing.
- **AOSP's V4L2 camera provider** (Cuttlefish's build) instead of Googlebook's USB camera HAL, plus one service label for it in `vendor_service_contexts`. The SELinux policy itself is unchanged.
- **A helper running as the Android shell user** that takes pointer and clipboard input from the viewer. It only accepts a host that presents a random per-boot token, and it listens to nothing — it connects out to `127.0.0.1` on your Mac.

So: treat it like a dev VM. It's great for poking at the OS. I wouldn’t daily drive it or anything, but I’m sure some freaks (laudatory) will try.

## What doesn't work yet

- **Bluetooth.** It crashes on boot and Android will tell you about it. Dismiss the dialog.
- **Camera frames in OpenGL ES apps.** Android itself draws camera previews with Vulkan here, and that works. An app that samples the camera frames with OpenGL ES instead (through a `SurfaceTexture`) gets a black or broken image: the guest's OpenGL ES driver can't read the camera's two-plane YUV buffers yet.
- **A TPM daemon crash-loops in the background.** It's harmless but it wastes a bit of CPU. We haven't found a clean way to stop it yet.
- **60 fps cap** on the guest display. The QEMU build we use doesn't expose a refresh rate setting.
- **Flat shading can be wrong.** Chrome needs a Vulkan extension MoltenVK doesn't have, so we tell the guest it exists. That's fine for almost everything; `flat`-interpolated WebGL content may pick the wrong vertex.
- **Copying *out* of the guest, right-click, and long sessions** are implemented but haven't had a proper test. They might be fine. They might not.
- **Audio was silent on one boot** and then worked. We don't know why yet.

## The Custom Bits

Five things had to be built for this:

**Buffer sharing between GLES and Vulkan.** Android hands the same graphics buffer to both APIs. On Linux that's a dma-buf; macOS has no such thing. We back each shared buffer with POSIX shared memory and import it into both Metal and MoltenVK — patch in `patches/virglrenderer-android-interop.patch`.

**Row pitch.** Metal wants texture rows padded to 16 bytes; Android doesn't. The fix turned out to be small: that memory only ever lives on the Mac side, so the host can use whatever pitch Metal wants and the guest never needs to know.

**A pointer that isn't a mouse.** Android wouldn't accept QEMU's absolute tablet, and steering a relative mouse to match your real cursor drifts. So a tiny helper inside the guest creates a virtual drawing tablet — which Android treats as an absolute pointer — and the viewer feeds it coordinates. This doesn’t work as well as we’d like, so capturing the cursor is most reliable still. We’re hoping to improve it.

**A webcam that is really a process.** QEMU on macOS has no virtual camera, and the Mac's camera isn't a USB device it could pass through. But QEMU's `usb-redir` lets something outside the VM *be* a USB device, so the viewer speaks that protocol over a socket and presents a standard UVC webcam (MJPEG over a bulk endpoint) fed by AVFoundation — `host/webcam.m`. The guest kernel already has `uvcvideo`. Googlebook OS ships its own USB camera HAL, but it runs every session through GPU effects (OpenGL, OpenCL, Vulkan with external memory) the VM can't provide, so the image retires it and adds AOSP's plain V4L2 camera provider from Cuttlefish instead — `image/mica_camera_port.py`.

**Camera frames on a GPU path with no YUV.** Camera frames are YUV: a full-size brightness plane plus a half-size colour plane. On Linux hosts those go through gbm; macOS has nothing like it. Android's allocator already has a fallback for that case — keep both planes in one plain 8-bit texture — but the renderer claimed the Mac could put YUV on screen, which switched the fallback off, so no camera buffer could be allocated at all. Now the renderer stops claiming that, stores the YUV buffers it is asked for directly in the same packed layout, and shares them through the same shared memory as above. The guest's Vulkan driver reads both planes from the buffer's metadata and imports it as a two-plane image, and MoltenVK converts it to RGB as it samples — `patches/virglrenderer-android-interop.patch` and `patches/mesa-android-mapper5.patch`.

The rest is plumbing: `fetch.sh` gets the images, `build-host.sh` builds the patched renderer and viewer, `build-guest.sh` cross-compiles Mesa for Android, and `build-image.sh` assembles the disk.

## Layout

```
install.sh          runs the four steps below in order
fetch.sh            downloads + verifies the Googlebook image, Cuttlefish, and UTM
build-host.sh       patched virglrenderer, QEMU launcher, viewer
build-guest.sh      Mesa (GLES + Vulkan), pointer helper, SELinux policy tool
build-image.sh      assembles the bootable disk
run/                VM runner and a command-line launcher (the app bundles these)
image/              the scripts that rebuild the vendor partition
guest/  host/       sources for the bits we wrote
patches/            our changes to virglrenderer, Mesa and CocoaSpice
```

Everything lands in `work/` (set `GOOGLEBOOK_WORK` to put it elsewhere). If you already have the big downloads, point `GOOGLEBOOK_DOWNLOADS` at them and they won't be fetched again. Builds use four jobs by default — raise `GBOS_JOBS` if you have the RAM, but an uncapped Mesa build will happily push a 16 GB Mac into swap (ask me how I know).

## What gets downloaded, and from where

Nothing from Google or UTM is redistributed here. The script fetches each of these on your machine and checks it against a pinned SHA-256:

- Googlebook recovery image — `dl.google.com` (build `16471258`)
- Cuttlefish virtual device image — `ci.android.com` (build `16373615`)
- UTM 5.0.6 beta — the official GitHub release (for its QEMU, MoltenVK and ANGLE)
- Mesa 26.2.4, libsepol 3.11, bison 3.8.2 — their upstream release tarballs

## Credits

This leans entirely on other people's work: [UTM](https://github.com/utmapp/UTM) and its forks of virglrenderer and CocoaSpice, [Mesa](https://mesa3d.org), [MoltenVK](https://github.com/KhronosGroup/MoltenVK), QEMU, and the Android Cuttlefish team, whose virtual-device components are what make the image boot at all. The pointer helper uses the same trick as [scrcpy](https://github.com/Genymobile/scrcpy).

## License

MIT for everything we wrote — see [LICENSE](LICENSE). The patches apply to MIT-licensed projects, except `patches/cocoaspice-viewer.patch`, which modifies Apache-2.0 code and stays under that license.

## AI Usage

The following AI tools were used to assist in this project:
- OpenAI GPT 6 Astra
- DeepSeek 4.1 Flash
- Anthropic Claude Opus 5.5