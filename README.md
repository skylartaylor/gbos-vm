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
- Optionally, the **Android Emulator** package from the SDK. Bluetooth borrows its virtual radio (see [What doesn't work yet](#what-doesnt-work-yet)); without it the VM boots with no Bluetooth.

`install.sh` checks all of this before it downloads anything, and offers to install what's missing — the Homebrew packages, a JDK, and the Android pieces through Google's `sdkmanager` (you don't need Android Studio). It never asks for `sudo`. Run `./prereqs.sh` on its own to see where you stand.

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

**Settings** (`⌘,`) has the pointer mode, clipboard, resolution, memory, CPU cores, and toggles for networking, audio and Bluetooth. Pointer mode and clipboard change right away; everything else is a VM option, so it applies the next time you start it.

Resolution defaults to your display's native pixels, at most 16:10 tall. On a notched MacBook that's exactly the area below the notch, so full screen is pixel for pixel. Settings also offers 1080p, 1440p, 4K and 3440 × 1440 ultrawide. The interface scale follows the screen height too, so ultrawides stay readable.

**Clipboard.** `⌘V` pastes the Mac clipboard into the guest, and that is the only time it is sent. Copying from Android to the Mac is off by default; enable it in Settings if you trust what you run in the guest.

**Isolate from this Mac** (Settings, experimental) blocks the internet and your Mac's local services from the guest, keeping only the pointer and clipboard link. Normal networking lets the guest reach your Mac's `127.0.0.1` through `10.0.2.2`.

### Updating

After a `git pull`, rebuild the app and refresh the system part of your disk. Quit the VM first.

```bash
./build-host.sh
./update-image.sh
```

`update-image.sh` keeps your data — it only replaces the system area, and it leaves the previous disk next to the new one as `googlebook.raw.before-update` in case something goes wrong.

If you'd rather drive it from a terminal, `python3 run/launch.py work` does the same thing and takes `--display 1920x1200` and `--fullscreen`.

### Pointer modes

**Captured mouse** is the default: click the window to grab the mouse, `⌃⌥` to let go. It's the classic VM experience — a plain USB mouse as far as Android is concerned, so it behaves.

There are two integrated modes where the pointer moves in and out of the window freely. They're labelled **experimental** because they're still kind of buggy:

- **Android cursor.** The guest draws the pointer, so it changes shape properly (I-beams, resize arrows). It trails your hand a little, and Android sees it as a stylus, which gets weird in places.
- **Mac cursor.** Instant, but it's always an arrow.

Switch in the **Pointer** menu, in Settings, or with `⌃⌘M`. Your choice is remembered, and `⌘V` paste works in all three.

## System Structure

The image starts as Google's unmodified recovery download. We don't touch the system partitions — but Googlebook OS expects hardware our VM doesn't have (a TPM, Trusty, a Qualcomm DSP, a specific GPU), so the **vendor partition gets rebuilt** with virtual-device replacements from Google's own Cuttlefish project:

- **Software KeyMint and Gatekeeper** instead of hardware-backed ones. Your keys aren't protected by a secure element, because there isn't one.
- **No verified boot on the vendor partition.** The other partitions keep their original verity; the one we modify can't.
- **Three extra SELinux rules**, all narrowly about graphics buffer sharing. SELinux stays enforcing. They apply to `platform_app`, `priv_app` and `priv_app_36`, for the graphics allocator's shared memory only.
- **No lock screen, unlocked boot state.** Setup is skipped and the screen stays on. Keys are software only and sit on the same disk as your data, so keep `work/image/googlebook.raw` private (the build makes it readable only by you).
- **A guest log.** `work/logs/<run>/serial.log` holds guest console output, including crash excerpts and package names. Nothing prunes old runs.
- **Cuttlefish's Bluetooth service** instead of the Qualcomm one, talking to a virtual radio on your Mac over a virtual serial port. The radio listens on `127.0.0.1` with no password, so another program on your Mac could join it and show up as a nearby Bluetooth device. Turn Bluetooth off in Settings if that bothers you.
- **A helper running as the Android shell user** that takes pointer and clipboard input from the viewer. It listens to nothing and connects out to `127.0.0.1` on your Mac. Both ends prove a random token to each other before anything else is sent. The token reaches Android over the serial console, into a file only the shell user can read.

So: treat it like a dev VM. It's great for poking at the OS. I wouldn’t daily drive it or anything, but I’m sure some freaks (laudatory) will try.

## What doesn't work yet

- **Bluetooth is virtual only.** If you have the Android Emulator installed, the VM gets its simulated radio (`netsimd`): Bluetooth turns on, but there's nothing real to pair with. Actual devices would need a USB dongle bridged in, which we haven't built. Without the emulator, Android is told it has no Bluetooth at all.
- **A TPM daemon crash-loops in the background.** It's harmless but it wastes a bit of CPU. We haven't found a clean way to stop it yet.
- **60 fps cap** on the guest display. The QEMU build we use doesn't expose a refresh rate setting.
- **Flat shading can be wrong.** Chrome needs a Vulkan extension MoltenVK doesn't have, so we tell the guest it exists. That's fine for almost everything; `flat`-interpolated WebGL content may pick the wrong vertex.
- **Copying *out* of the guest, right-click, and long sessions** are implemented but haven't had a proper test. They might be fine. They might not.
- **Audio was silent on one boot** and then worked. We don't know why yet.

## The Custom Bits

Three things had to be built for this:

**Buffer sharing between GLES and Vulkan.** Android hands the same graphics buffer to both APIs. On Linux that's a dma-buf; macOS has no such thing. We back each shared buffer with POSIX shared memory and import it into both Metal and MoltenVK — patch in `patches/virglrenderer-android-interop.patch`.

**Row pitch.** Metal wants texture rows padded to 16 bytes; Android doesn't. The fix turned out to be small: that memory only ever lives on the Mac side, so the host can use whatever pitch Metal wants and the guest never needs to know.

**A pointer that isn't a mouse.** Android wouldn't accept QEMU's absolute tablet, and steering a relative mouse to match your real cursor drifts. So a tiny helper inside the guest creates a virtual drawing tablet — which Android treats as an absolute pointer — and the viewer feeds it coordinates. This doesn’t work as well as we’d like, so capturing the cursor is most reliable still. We’re hoping to improve it.

The rest is plumbing: `fetch.sh` gets the images, `build-host.sh` builds the patched renderer and viewer, `build-guest.sh` cross-compiles Mesa for Android, and `build-image.sh` assembles the disk.

## Layout

```
install.sh          runs the four steps below in order
fetch.sh            downloads + verifies the Googlebook image, Cuttlefish, and UTM
build-host.sh       patched virglrenderer, QEMU launcher, viewer
build-guest.sh      Mesa (GLES + Vulkan), pointer helper, SELinux policy tool
build-image.sh      assembles the bootable disk
update-image.sh     refreshes an existing disk after a git pull, keeping your data
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