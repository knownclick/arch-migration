#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

profile="recommended"
profile_explicit=false
selection_file=""
with_virtualization=false
skip_aur=false
skip_config=false
restore_private=false
assume_yes=false
dry_run=false
display_manager_choice=greetd
replace_display_manager=false
display_manager_override=""

usage() {
    cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Install packages and restore this machine's Hyprland environment on a fresh
Arch installation. Run as the target user with working sudo and networking.

Options:
  --profile NAME          desktop, recommended (default), or full
  --selection FILE        Use choices saved by setup.sh
  --with-virtualization   Add Docker, QEMU, libvirt and virt-manager
  --skip-aur              Skip Cloudflare WARP and RustDesk
  --skip-config           Install packages only; do not run restore.sh
  --restore-private       Restore private state from an encrypted export
  --keep-display-manager  Do not enable greetd/ReGreet
  --replace-display-manager
                          Replace another enabled login manager with greetd
  --yes                   Non-interactive pacman/AUR install (sudo may prompt)
  --dry-run               Print the package/action plan only
  -h, --help              Show this help
EOF
}

while (($#)); do
    case "$1" in
        --profile)
            (($# >= 2)) || die "--profile needs a name"
            profile="$2"
            profile_explicit=true
            shift 2
            ;;
        --selection)
            (($# >= 2)) || die "--selection needs a path"
            selection_file="$2"
            shift 2
            ;;
        --with-virtualization)
            with_virtualization=true
            shift
            ;;
        --skip-aur)
            skip_aur=true
            shift
            ;;
        --skip-config)
            skip_config=true
            shift
            ;;
        --restore-private)
            restore_private=true
            shift
            ;;
        --keep-display-manager)
            display_manager_choice=keep
            display_manager_override=keep
            shift
            ;;
        --replace-display-manager)
            display_manager_choice=greetd
            replace_display_manager=true
            display_manager_override=greetd
            shift
            ;;
        --yes)
            assume_yes=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

selection_active=false
if [[ -n "$selection_file" ]]; then
    load_selection "$selection_file"
    if $profile_explicit && [[ "$profile" != "$SELECTION_PROFILE" ]]; then
        die "--profile conflicts with the saved selection profile"
    fi
    profile="$SELECTION_PROFILE"
    [[ "$SELECTION_PRIVATE" == yes ]] && restore_private=true
    display_manager_choice="$SELECTION_DISPLAY_MANAGER"
    [[ "$display_manager_choice" == greetd ]] && replace_display_manager=true
    selection_active=true
fi
if [[ -n "$display_manager_override" ]]; then
    display_manager_choice="$display_manager_override"
    [[ "$display_manager_choice" == greetd ]] && replace_display_manager=true
fi

case "$profile" in
    desktop|recommended|full) ;;
    *) die "profile must be desktop, recommended, or full" ;;
esac
if $restore_private && ! $skip_config && [[ ! -f "$PROJECT_ROOT/private.tar.zst.gpg" ]]; then
    die "private restore was selected, but this bundle has no encrypted private archive"
fi

is_arch_linux || die "this installer supports Arch Linux only"
((EUID != 0)) || die "run this as the target desktop user, not root"
command -v sudo >/dev/null 2>&1 || die "sudo is required"
if ! $assume_yes && [[ ! -t 0 ]] && ! $dry_run; then
    die "non-interactive use requires --yes"
fi

declare -a requested_packages=()
if $selection_active; then
    declare -a protected_packages=()
    append_manifest protected_packages "$PROJECT_ROOT/packages/base.txt"
    append_manifest protected_packages "$PROJECT_ROOT/packages/desktop.txt"
    requested_packages+=("${protected_packages[@]}")
    if [[ "$profile" == full ]]; then
        append_manifest requested_packages "$PROJECT_ROOT/packages/full-current.txt"
    fi

    declare -A excluded_lookup=() protected_lookup=()
    for package in "${SELECTION_EXCLUDES[@]}"; do excluded_lookup["$package"]=1; done
    for package in "${protected_packages[@]}"; do protected_lookup["$package"]=1; done
    declare -a filtered_packages=()
    for package in "${requested_packages[@]}"; do
        if [[ -n "${excluded_lookup[$package]:-}" && -z "${protected_lookup[$package]:-}" ]]; then
            continue
        fi
        filtered_packages+=("$package")
    done
    requested_packages=("${filtered_packages[@]}" "${SELECTION_REPO_PACKAGES[@]}")
    for selected_group in "${SELECTION_GROUPS[@]}"; do
        group_file="$(group_manifest "$selected_group")"
        append_manifest requested_packages "$group_file"
    done
else
    append_manifest requested_packages "$PROJECT_ROOT/packages/base.txt"
    case "$profile" in
        desktop)
            append_manifest requested_packages "$PROJECT_ROOT/packages/desktop.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/apps-desktop.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-bluetooth.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-firewall.txt"
            ;;
        recommended)
            append_manifest requested_packages "$PROJECT_ROOT/packages/desktop.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/apps.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-bluetooth.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-printing.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-extended-files.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-firewall.txt"
            ;;
        full)
            append_manifest requested_packages "$PROJECT_ROOT/packages/desktop.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/apps.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/apps-full-extra.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-bluetooth.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-printing.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-extended-files.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/feature-firewall.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/virtualization.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/legacy-extras.txt"
            append_manifest requested_packages "$PROJECT_ROOT/packages/full-current.txt"
            ;;
    esac
fi
if $with_virtualization && [[ "$profile" != full || "$selection_active" == true ]]; then
    append_manifest requested_packages "$PROJECT_ROOT/packages/virtualization.txt"
fi
if [[ "$display_manager_choice" == greetd ]]; then
    append_manifest requested_packages "$PROJECT_ROOT/packages/feature-login-greetd.txt"
else
    declare -a without_greetd=()
    for package in "${requested_packages[@]}"; do
        [[ "$package" == greetd || "$package" == greetd-regreet ]] && continue
        without_greetd+=("$package")
    done
    requested_packages=("${without_greetd[@]}")
fi

cpu_vendor="$(awk -F: '/vendor_id/{gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
case "$cpu_vendor" in
    AuthenticAMD) requested_packages+=(amd-ucode) ;;
    GenuineIntel) requested_packages+=(intel-ucode) ;;
    *) warn "CPU vendor was not recognized; no microcode package was selected" ;;
esac

declare -A gpu_vendors=()
detect_gpu_vendors gpu_vendors

if [[ -n "${gpu_vendors[0x1002]:-}" ]]; then
    requested_packages+=(mesa vulkan-radeon libva-mesa-driver)
fi
if [[ -n "${gpu_vendors[0x8086]:-}" ]]; then
    requested_packages+=(mesa vulkan-intel intel-media-driver)
fi
if [[ -n "${gpu_vendors[0x10de]:-}" ]]; then
    warn "an NVIDIA GPU was detected, but NVIDIA packages are intentionally excluded"
fi
if ((${#gpu_vendors[@]} == 0)); then
    warn "no PCI/DRM display GPU was detected; Mesa will still be installed by the desktop profile"
fi

mapfile -t packages < <(printf '%s\n' "${requested_packages[@]}" | sort -u)

remote_session=false
[[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]] && remote_session=true
restore_firewall=false
if array_contains packages ufw && ! $remote_session; then
    restore_firewall=true
elif array_contains packages ufw; then
    warn "SSH session detected; old UFW rules will not be restored or enabled"
fi

declare -a aur_packages=()
if ! $skip_aur && $selection_active; then
    aur_packages=("${SELECTION_AUR_PACKAGES[@]}")
elif ! $skip_aur && [[ "$profile" != desktop ]]; then
    aur_manifest="$PROJECT_ROOT/packages/aur.txt"
    [[ "$profile" == full && -s "$PROJECT_ROOT/packages/aur-current.txt" ]] && \
        aur_manifest="$PROJECT_ROOT/packages/aur-current.txt"
    mapfile -t aur_packages < <(read_manifest "$aur_manifest" | sort -u)
fi

log "Install plan"
printf '  profile: %s\n' "$profile"
if $selection_active; then
    printf '  saved selection: %s\n' "$selection_file"
fi
printf '  CPU: %s\n' "${cpu_vendor:-unknown}"
printf '  official/vendor packages: %d\n' "${#packages[@]}"
printf '  AUR packages: %d\n' "${#aur_packages[@]}"
printf '  NVIDIA packages: excluded\n'
printf '  login manager: %s\n' "$display_manager_choice"
printf '  source firewall policy: %s\n' "$(if $restore_firewall; then printf restore; elif $remote_session; then printf 'skip (SSH safety)'; else printf 'not selected'; fi)"
printf '\nPackages:\n'
printf '  %s\n' "${packages[@]}"
if ((${#aur_packages[@]})); then
    printf '\nAUR packages (PKGBUILDs must be trusted before execution):\n'
    printf '  %s\n' "${aur_packages[@]}"
fi

if $dry_run; then
    if ! $skip_config && [[ -d "$PROJECT_ROOT/payload/home" ]]; then
        printf '\nEmbedded configuration payload: yes\n'
    elif ! $skip_config; then
        printf '\nEmbedded configuration payload: no (export on the old machine first)\n'
    fi
    exit 0
fi

sudo -v
pacman_flags=(--needed)
$assume_yes && pacman_flags+=(--noconfirm)

log "Updating Arch and installing bootstrap tools"
sudo pacman -Syu "${pacman_flags[@]}" base base-devel curl git gnupg rsync zstd

contains_package() { array_contains packages "$1"; }
contains_aur_package() { array_contains aur_packages "$1"; }
sublime_repo_added=false

setup_sublime_repository() {
    local architecture channel key_file fingerprint
    architecture="$(uname -m)"
    case "$architecture" in
        x86_64) channel="x86_64" ;;
        aarch64) channel="aarch64" ;;
        *)
            warn "Sublime Text has no configured repository for $architecture; skipping it"
            return 0
            ;;
    esac

    key_file="$(mktemp "${TMPDIR:-/tmp}/sublimehq-key.XXXXXXXX.gpg")"
    if ! curl -fsSL https://download.sublimetext.com/sublimehq-pub.gpg -o "$key_file"; then
        rm -f -- "$key_file"
        die "could not download the Sublime repository key"
    fi
    fingerprint="$(gpg --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
    if [[ "$fingerprint" != 1EDDE2CDFC025D17F6DA9EC0ADAE6AD28A8F901A ]]; then
        rm -f -- "$key_file"
        die "Sublime repository key fingerprint did not match"
    fi
    if ! sudo pacman-key --list-keys "$fingerprint" >/dev/null 2>&1; then
        log "Adding Sublime Text's signing key"
        sudo pacman-key --add "$key_file"
    fi
    rm -f -- "$key_file"
    sudo pacman-key --lsign-key "$fingerprint"
    if ! sudo grep -q '^\[sublime-text\]$' /etc/pacman.conf; then
        log "Adding Sublime Text's signed stable repository"
        printf '\n[sublime-text]\nServer = https://download.sublimetext.com/arch/stable/%s\n' "$channel" | \
            sudo tee -a /etc/pacman.conf >/dev/null
        sublime_repo_added=true
    fi
}

if contains_package sublime-text; then
    setup_sublime_repository
fi

# Refresh and fully upgrade after adding a vendor repository. The bootstrap
# command already did this when no repository was added.
if $sublime_repo_added; then
    sync_flags=()
    $assume_yes && sync_flags+=(--noconfirm)
    sudo pacman -Syu "${sync_flags[@]}"
fi

declare -a available=() missing=()
for package in "${packages[@]}"; do
    if pacman -Si -- "$package" >/dev/null 2>&1; then
        available+=("$package")
    else
        missing+=("$package")
    fi
done

declare -a essential_packages=() missing_essential=()
append_manifest essential_packages "$PROJECT_ROOT/packages/base.txt"
append_manifest essential_packages "$PROJECT_ROOT/packages/desktop.txt"
if [[ "$display_manager_choice" == greetd ]]; then
    append_manifest essential_packages "$PROJECT_ROOT/packages/feature-login-greetd.txt"
fi
case "$cpu_vendor" in
    AuthenticAMD) essential_packages+=(amd-ucode) ;;
    GenuineIntel) essential_packages+=(intel-ucode) ;;
esac
[[ -n "${gpu_vendors[0x1002]:-}" ]] && essential_packages+=(mesa vulkan-radeon libva-mesa-driver)
[[ -n "${gpu_vendors[0x8086]:-}" ]] && essential_packages+=(mesa vulkan-intel intel-media-driver)
mapfile -t essential_packages < <(printf '%s\n' "${essential_packages[@]}" | sort -u)
for package in "${missing[@]}"; do
    array_contains essential_packages "$package" && missing_essential+=("$package")
done
if ((${#missing_essential[@]})); then
    die "required desktop packages are unavailable: ${missing_essential[*]}"
fi

if ((${#available[@]})); then
    log "Installing repository packages"
    sudo pacman -S "${pacman_flags[@]}" -- "${available[@]}"
fi
if ((${#missing[@]})); then
    warn "these packages were unavailable and were skipped: ${missing[*]}"
fi

install_aur_package() {
    local package="$1" build_root package_dir origin
    [[ "$package" =~ ^[a-zA-Z0-9@._+-]+$ ]] || die "unsafe AUR package name: $package"
    if pacman -Qq | grep -Fxq "$package"; then
        printf 'AUR package already installed: %s\n' "$package"
        return 0
    fi
    if [[ "$package" == rustdesk-bin ]] && command -v rustdesk >/dev/null 2>&1; then
        printf 'RustDesk is already installed under another package name\n'
        return 0
    fi
    build_root="${XDG_CACHE_HOME:-$HOME/.cache}/arch-migration/aur"
    package_dir="$build_root/$package"
    mkdir -p "$build_root"
    if [[ -d "$package_dir/.git" ]]; then
        origin="$(git -C "$package_dir" remote get-url origin 2>/dev/null || true)"
        [[ "$origin" == "https://aur.archlinux.org/${package}.git" ]] || \
            die "AUR cache has an unexpected origin; inspect or remove it: $package_dir"
        [[ -z "$(git -C "$package_dir" status --porcelain --untracked-files=no)" ]] || \
            die "AUR cache has tracked local changes; inspect or remove it: $package_dir"
        git -C "$package_dir" pull --ff-only
    else
        [[ ! -e "$package_dir" ]] || die "AUR cache path exists but is not a Git repository: $package_dir"
        git clone "https://aur.archlinux.org/${package}.git" "$package_dir"
    fi
    git -C "$package_dir" ls-files --error-unmatch -- PKGBUILD .SRCINFO >/dev/null 2>&1 || \
        die "AUR repository does not track PKGBUILD and .SRCINFO: $package_dir"
    [[ -f "$package_dir/PKGBUILD" && ! -L "$package_dir/PKGBUILD" && \
       -f "$package_dir/.SRCINFO" && ! -L "$package_dir/.SRCINFO" ]] || \
        die "AUR repository is missing PKGBUILD or .SRCINFO: $package_dir"
    if ! $assume_yes; then
        printf '\nReviewing AUR recipe: %s\n' "$package_dir/PKGBUILD"
        if command -v less >/dev/null 2>&1; then
            less "$package_dir/PKGBUILD"
        else
            sed -n '1,260p' "$package_dir/PKGBUILD"
        fi
        read -r -p "Build and install $package? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || {
            warn "skipped AUR package: $package"
            return 0
        }
    fi
    makepkg_args=(-si --clean --needed)
    $assume_yes && makepkg_args+=(--noconfirm)
    (cd "$package_dir" && makepkg "${makepkg_args[@]}")
}

if ((${#aur_packages[@]})); then
    log "Installing reviewed AUR packages as the normal user"
    for package in "${aur_packages[@]}"; do
        install_aur_package "$package"
    done
fi

if ! $skip_config; then
    if [[ -d "$PROJECT_ROOT/payload/home" ]]; then
        restore_args=()
        $restore_private && restore_args+=(--private)
        [[ "$display_manager_choice" == keep ]] && restore_args+=(--skip-greetd)
        $restore_firewall || restore_args+=(--skip-firewall)
        "$PROJECT_ROOT/restore.sh" "${restore_args[@]}"
    else
        warn "no embedded payload was found; packages were installed but settings were not restored"
    fi
fi

adapt_application_defaults() {
    local mime
    if command -v xdg-mime >/dev/null 2>&1; then
        if ! command -v firefox >/dev/null 2>&1 && command -v chromium >/dev/null 2>&1; then
            for mime in text/html x-scheme-handler/http x-scheme-handler/https \
                x-scheme-handler/about x-scheme-handler/unknown; do
                xdg-mime default chromium.desktop "$mime" || true
            done
            printf 'Chromium was made the web default because Firefox was not selected.\n'
        fi
        if ! command -v mpv >/dev/null 2>&1 && command -v vlc >/dev/null 2>&1; then
            for mime in video/mp4 video/x-matroska video/webm video/x-msvideo \
                video/quicktime video/x-m4v video/mpeg video/x-flv video/3gpp \
                video/3gpp2 video/x-ms-wmv video/mp2t video/ogg video/x-ogm+ogg \
                application/x-matroska; do
                xdg-mime default vlc.desktop "$mime" || true
            done
            printf 'VLC was made the video default because MPV was not selected.\n'
        fi
        if ! command -v lite-xl >/dev/null 2>&1 && command -v subl >/dev/null 2>&1; then
            xdg-mime default sublime_text.desktop application/x-zerosize || true
        fi
    fi
    if ! command -v gh >/dev/null 2>&1 && [[ -f "$HOME/.gitconfig" ]]; then
        git config --global --unset-all 'credential.https://github.com.helper' 2>/dev/null || true
        git config --global --unset-all 'credential.https://gist.github.com.helper' 2>/dev/null || true
        warn "removed the unavailable GitHub CLI credential helper from the restored Git config"
    fi
}

if ! $skip_config && [[ -d "$PROJECT_ROOT/payload/home" ]]; then
    adapt_application_defaults
fi

if [[ -r /etc/locale.conf ]] && command -v locale-gen >/dev/null 2>&1; then
    locale_name="$(sed -n 's/^[[:space:]]*LANG=//p' /etc/locale.conf | head -n1)"
    locale_name="${locale_name#\"}"
    locale_name="${locale_name%\"}"
    if [[ "$locale_name" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
        locale_pattern="${locale_name//./\\.}"
        if grep -Eq "^#${locale_pattern}[[:space:]]" /etc/locale.gen; then
            sudo sed -i -E "s/^#(${locale_pattern}[[:space:]])/\\1/" /etc/locale.gen
        fi
        sudo locale-gen
    fi
fi

enable_unit() {
    local unit="$1"
    if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q .; then
        if ! sudo systemctl enable "$unit" >/dev/null; then
            warn "could not enable $unit"
        fi
    fi
}

log "Enabling services for the next boot"
for unit in \
    NetworkManager.service \
    fstrim.timer \
    keyd.service \
    power-profiles-daemon.service \
    systemd-timesyncd.service; do
    enable_unit "$unit"
done
contains_package avahi && enable_unit avahi-daemon.service
contains_package bluez && enable_unit bluetooth.service
contains_package cups && enable_unit cups.service
$restore_firewall && contains_package ufw && enable_unit ufw.service

configure_login_manager() {
    local display_link=/etc/systemd/system/display-manager.service
    local current_target="" current_unit="" allow_replace=false reply
    if [[ "$display_manager_choice" == keep ]]; then
        printf "Keeping the target system's existing login manager.\n"
        return 0
    fi

    if [[ -L "$display_link" ]]; then
        current_target="$(readlink -f "$display_link" 2>/dev/null || true)"
        current_unit="$(basename -- "$current_target")"
    fi
    if [[ -n "$current_unit" && "$current_unit" != greetd.service ]]; then
        if $replace_display_manager; then
            allow_replace=true
        elif ! $assume_yes && [[ -t 0 ]]; then
            printf '\nAnother login manager is enabled: %s\n' "$current_unit"
            read -r -p 'Disable it and enable greetd/ReGreet instead? [y/N] ' reply
            [[ "$reply" =~ ^[Yy]$ ]] && allow_replace=true
        fi
        if ! $allow_replace; then
            warn "left $current_unit enabled; greetd was not enabled"
            warn "rerun with --replace-display-manager if you want ReGreet"
            return 0
        fi
        mkdir -p "$HOME/.local/state/arch-migration"
        printf '%s\n' "$current_unit" > "$HOME/.local/state/arch-migration/display-manager-before.txt"
        sudo systemctl disable "$current_unit" >/dev/null
    fi
    enable_unit greetd.service
}

configure_login_manager

if contains_package docker; then
    enable_unit docker.service
fi
if contains_package libvirt; then
    enable_unit libvirtd.service
    enable_unit libvirtd.socket
fi
if contains_aur_package cloudflare-warp-bin; then
    enable_unit warp-svc.service
fi
if contains_aur_package rustdesk-bin; then
    enable_unit rustdesk.service
fi

for group_name in docker libvirt; do
    if contains_package "$group_name" && getent group "$group_name" >/dev/null 2>&1 && \
       ! id -nG "$USER" | tr ' ' '\n' | grep -Fxq "$group_name"; then
        sudo usermod -aG "$group_name" "$USER"
        warn "$USER was added to $group_name; the group takes effect after logout/reboot"
    fi
done

systemctl --user daemon-reload >/dev/null 2>&1 || true

log "Installation complete"
printf 'NVIDIA packages and the old NVIDIA initramfs configuration were not copied.\n'
printf 'Reboot once, then use the Quickshell display control to save the new monitor layout.\n'
printf 'Cloudflare WARP, browsers, GitHub CLI and RustDesk may require sign-in on the new device.\n'
if $remote_session && contains_package ufw; then
    printf 'Source UFW rules were skipped and UFW was not enabled by this run (SSH safety).\n'
fi
verify_args=(--profile "$profile")
if $selection_active; then
    verify_args=(--selection "$selection_file")
fi
$with_virtualization && verify_args+=(--with-virtualization)
$skip_aur && verify_args+=(--skip-aur)
[[ "$display_manager_choice" == keep ]] && verify_args+=(--keep-display-manager)
printf 'Before rebooting, verify the result with:\n'
print_command "$PROJECT_ROOT/verify.sh" "${verify_args[@]}"
