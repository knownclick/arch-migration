# Source-machine audit

Captured on 2026-08-11 from the source laptop:

- Arch Linux, x86_64, Hyprland 0.56.2 on Wayland
- AMD Ryzen 5 3550H with integrated Radeon Vega plus NVIDIA GTX 1650 Mobile
- 940 installed packages
- 121 explicitly installed repository packages
- 2 explicitly installed foreign packages: `cloudflare-warp-bin`, `rustdesk`
- 1 orphaned dependency: `electron39`
- Active custom session: Quickshell bar/dashboard/app drawer, Mako, cliphist,
  Awww wallpaper rotation, hypridle, GTKlock with Swaylock fallback, ReGreet,
  custom monitor control, keyd Caps Lock mapping, PipeWire/WirePlumber

The source machine had NVIDIA modules hard-coded in `mkinitcpio.conf` and four
hardware-tied explicit packages (`amd-ucode`, `egl-wayland`,
`nvidia-open-dkms`, `nvidia-utils`). None are replayed verbatim. The installer
detects the new CPU/GPU instead.

The audit also found hard-coded source-home paths in Hyprland, Quickshell,
GTKlock launch scripts, DesktopUI image URLs, and enabled systemd-user symlinks.
`restore.sh` rewrites text paths and link targets after copying them.

Currently enabled system services included NetworkManager, Bluetooth, CUPS,
Avahi, greetd, keyd, power-profiles-daemon, UFW, Docker, libvirt, RustDesk,
Cloudflare WARP, timesync, and fstrim. The installer enables a service only if
its package supplied the unit, so choosing a smaller profile does not create
broken enablement links.

Large/private locations discovered and excluded from the safe payload include:

- Mozilla profile: about 1.0 GiB
- Chromium profile: about 159 MiB
- Thunderbird profile: about 347 MiB
- Codex state/packages/logs: about 4.0 GiB
- Claude settings/state: about 256 MiB; cached standalone versions: about 987 MiB
- SSH, GitHub CLI, Remmina, RustDesk, qBittorrent, browser and Electron tokens

The wallpaper directory is about 652 MiB and DesktopUI browser art is about
13 MiB. Both are genuine parts of the current desktop appearance; wallpapers
are enabled by default but can be omitted at export time.

## Migration-kit hardening audit

A second pass found and corrected several issues that could otherwise make a
smaller, customized install behave differently from the source desktop:

- `python-gobject` and `libqalculate`, required by the custom calculator, are
  now explicit core dependencies instead of arriving accidentally through
  Bluetooth, printing, or other optional applications.
- Bluetooth, printing/Avahi, Docker, libvirt, WARP, and RustDesk services are
  enabled only when their corresponding choice is selected. An already-present
  but deselected package no longer causes its service to be enabled.
- UFW is a visible feature choice. Because the source rules do not allow SSH,
  an SSH-driven migration automatically skips copying/enabling that policy to
  avoid locking out the remote session after reboot.
- Keeping another display manager now omits ReGreet itself and skips its `/etc`
  configuration. Replacing an existing manager is explicit, and the previous
  unit name is recorded for recovery.
- Desktop, Recommended, and Full direct profiles now match their picker presets;
  Full also retains the freshly exported explicit-package inventory.
- CPU/GPU detection uses both DRM and PCI display-class devices, which covers a
  fresh system where a graphics driver has not created its DRM card yet.
- Saved choices and bundle metadata are parsed as constrained data rather than
  sourced as shell. A crafted metadata home such as `/` or a traversal path is
  rejected before path rewriting.
- Encrypted private data is decrypted to a protected temporary file, its archive
  paths are checked, and `bsdtar` performs a secure staged extraction before
  anything is copied into the target home.
- Every export gets a portable SHA-256 sidecar. AUR build caches must have the
  expected origin, no tracked local changes, and tracked regular `PKGBUILD` and
  `.SRCINFO` files.
- The restored launcher reports a skipped application instead of failing
  silently, and MIME/Git defaults are adapted when their source application was
  deliberately deselected.

The scripts were syntax-checked and ShellCheck-clean, all current repository
package names resolved against the synchronized package databases, and a real
archive was exported, checksum-verified, extracted, reused by the picker, and
restored into an isolated home. A separate encrypted fixture exercised the
private-state restore path.
