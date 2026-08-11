# Arch + Hyprland migration kit

This recreates the current Hyprland/Quickshell desktop on a fresh Arch Linux
device without replaying the old laptop's NVIDIA configuration. The guided
assistant lets you choose applications and optional features before anything is
installed, remembers those choices in `selection.conf`, and uses the same file
for installation and verification.

The target must already have a bootable Arch base installation, networking, a
normal user, and working `sudo`. This kit does not repartition disks or replace
the bootloader, `fstab`, hostname, users, or initramfs configuration.

## Guided migration

On the old machine, run:

```bash
git clone https://github.com/knownclick/arch-migration.git
cd arch-migration
./setup.sh --output /run/media/$USER/MY_USB/arch-migration.tar.zst
```

The public HTTPS clone requires no GitHub account. The exported transfer archive
also embeds this toolkit, so the new machine does not need to clone it again.

The menu starts with a Desktop, Recommended, or Full preset. Toggle any item by
entering its number; multiple numbers may be separated by spaces or commas.
`a` selects all, `n` selects none, `r` restores the current preset, and
`d`/`m`/`f` switch presets. The assistant
then asks about encrypted private state, the custom ReGreet login screen, and
the wallpaper collection, saves the choices, and creates the archive.

The export creates two files. Transfer both:

```text
arch-migration.tar.zst
arch-migration.tar.zst.sha256
```

On the new device, verify and extract them before running any included code:

```bash
cd /path/to/the/transferred/files
sha256sum --check arch-migration.tar.zst.sha256
tar --zstd -xf arch-migration.tar.zst
cd arch-migration
./setup.sh
```

The embedded choices are shown again and may be changed. Because the extracted
directory contains a settings payload, `setup.sh` now previews or runs the
installer instead of exporting. After installation, run the exact verification
command printed by the installer, normally:

```bash
./verify.sh --selection selection.conf
sudo reboot
```

After reboot, use the Quickshell display control to select and save the new
monitor layout.

## What you can choose

The picker currently exposes 24 application/feature choices, including both
browsers, Obsidian, LibreOffice, Thunderbird, MPV, VLC, qBittorrent, editors,
remote-desktop tools, GitHub CLI, `uv`, archive/search/sync tools, RustDesk,
Cloudflare WARP, Bluetooth, printing, phone/camera/SMB mounts, UFW,
virtualization, and legacy desktop utilities.

The required desktop core stays selected: Hyprland, Quickshell, Kitty, Thunar,
PipeWire/WirePlumber, notifications, screenshots, clipboard history, locking,
fonts, portals, the custom calculator, networking, and the scripts referenced
by the active session. Pacman may still install an unselected package when it is
a dependency of something you selected.

The presets are:

- `desktop`: the core desktop plus Firefox, MPV/yt-dlp, 7-Zip, Bluetooth, and
  UFW.
- `recommended`: the core plus the applications and integrations most relevant
  to the restored configuration; large virtualization and legacy stacks stay
  off.
- `full`: every explicit package recorded from the old system plus every picker
  item. Use Recommended when you do not want uncategorized old packages.

Settings for an application may remain in the bundle even when that application
is skipped; they are inert and small. Missing optional app/browser choices now
produce a notification instead of failing silently. If Firefox or
MPV is skipped in favor of Chromium or VLC, the installer adjusts the restored
MIME defaults. It also removes the restored GitHub CLI credential helper when
`gh` is not installed.

For advanced control, all manifests are plain text under `packages/`, and the
menu is defined by `packages/apps.catalog`. Re-running `setup.sh` edits the saved
selection safely; the selection file is parsed as data and is never sourced as
shell code.

## Useful non-interactive forms

Preview without making an archive or installing packages:

```bash
./setup.sh --preset recommended --dry-run
```

Save choices only:

```bash
./setup.sh --preset recommended --save-only
```

Create a source archive from a preset without showing the picker:

```bash
./setup.sh --preset recommended --non-interactive \
  --output /run/media/$USER/MY_USB/arch-migration.tar.zst
```

Inside an extracted bundle, the same command installs instead. Add `--yes` only
when you intentionally want non-interactive pacman and AUR confirmation. The
AUR recipes will execute code as your user and may invoke `sudo` through
`makepkg`; interactive review is the safer default.

Other options include:

```bash
# Smaller source archive
./setup.sh --preset recommended --no-wallpapers

# Include on the source / restore on the target
./setup.sh --restore-private

# Keep SDDM, GDM, or another target login manager
./setup.sh --keep-display-manager

# Direct package-plan preview using saved choices
./install.sh --selection selection.conf --dry-run

# Direct profiles remain available
./install.sh --profile desktop
./install.sh --profile full
./install.sh --profile recommended --with-virtualization
./install.sh --profile recommended --skip-aur
```

`--no-wallpapers` omits the 652 MiB collection but restores the small login
background as a single fallback, so wallpaper controls still work.

When ReGreet is selected and another display manager is already enabled, the
guided choice authorizes replacing it. A direct unattended `install.sh --yes`
run leaves the existing manager alone unless `--replace-display-manager` is
also supplied. `--keep-display-manager` omits both the ReGreet package and its
configuration.

The exported UFW policy denies unsolicited inbound connections and has no SSH
allow rule. When installation/restoration is running through SSH, the toolkit
therefore skips those old rules and does not enable UFW. Configure an SSH allow
rule locally before enabling it on the new device.

## Settings, private state, and personal files

The normal archive contains portable desktop settings: Hyprland, Quickshell,
GTKlock, Mako, Kitty, Thunar, MPV, editor/office preferences, MIME defaults,
dashboard notes, user services, shell/Git preferences, the login theme, locale,
keymap, timezone, UFW/keyd/zram configuration, and optionally wallpapers. It
does not contain login sessions or credentials.

Selecting private state makes a separate AES-256 GnuPG-encrypted archive inside
the bundle. It can include browser and Thunderbird profiles, SSH/GPG keys,
GitHub CLI authentication, RustDesk/Remmina, qBittorrent, Obsidian, Docker/Kube
settings, and selected Codex/Claude settings. Close those applications first
and remember the passphrase; it cannot be recovered. The decrypted archive is
validated and extracted into an isolated staging directory before restore.

Personal documents, projects, photos, videos, Obsidian vaults, repositories,
VM images, Docker volumes, databases, and other working data are not desktop
configuration. Transfer them separately with your backup/sync method. Wi-Fi
profiles, Bluetooth pairings, printer queues, WARP device registration, and
other hardware-bound state should be recreated on the new device.

Existing target files are backed up before replacement:

- User files: `~/.local/state/arch-migration/backups/`
- System files: `/var/backups/arch-migration/`

## Hardware and package safety

The installer detects the new CPU and selects `amd-ucode` or `intel-ucode`. It
detects AMD/Intel graphics through DRM and PCI display devices and chooses the
corresponding Mesa/Vulkan/video packages. NVIDIA packages and the old
NVIDIA-only initramfs configuration are excluded. Verification warns if NVIDIA
packages or initramfs references are left on a non-NVIDIA target.

Sublime Text uses its signed stable vendor repository and validates the full
repository-key fingerprint. Cloudflare WARP and RustDesk use the AUR. Cached AUR
repositories must have the expected HTTPS origin and no tracked local
modifications before they are updated or built. Normal untracked build outputs
do not prevent a later update.

The monitor configuration is deliberately hardware-neutral on first boot.
Source-home references in text configuration and user-service symlinks are
rewritten to the target home, while unsafe bundle metadata is rejected.

This follows Arch's documented fresh-base, explicit-package-list, and portable
dotfile migration approach: [migrating to new hardware](https://wiki.archlinux.org/title/Migrate_installation_to_new_hardware),
[pacman package-list guidance](https://wiki.archlinux.org/title/Pacman/Tips_and_tricks#List_of_installed_packages),
and [AUR safety guidance](https://wiki.archlinux.org/title/Arch_User_Repository).
The Sublime repository setup follows the [official Linux repository instructions](https://www.sublimetext.com/docs/linux_repositories.html).
