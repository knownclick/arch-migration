# Encrypted internet deployment

`arch-migration.tar.zst.gpg` is the password-encrypted personal configuration
payload for this machine. It contains the portable Hyprland/Quickshell settings
and the saved application selection. It does not contain the optional private
browser, login, SSH, GPG, or application-state archive.

On a fresh Arch installation, log in as the normal user and run:

```bash
sudo pacman -Syu --needed git
git clone https://github.com/knownclick/arch-migration.git
cd arch-migration
./install/deploy.sh
```

The helper verifies the encrypted file, installs `gnupg`, `rsync`, and `zstd`
when needed, asks for the password without displaying or saving it, prepares
the payload, and starts the normal application picker. The password is
intentionally not stored in this public repository.

To decrypt and prepare the payload without starting the installer:

```bash
./install/deploy.sh --prepare-only
```
