#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

profile="recommended"
profile_explicit=false
selection_file=""
skip_aur=false
with_virtualization=false
display_manager_choice=greetd
display_manager_override=""
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
        --skip-aur)
            skip_aur=true
            shift
            ;;
        --with-virtualization)
            with_virtualization=true
            shift
            ;;
        --keep-display-manager)
            display_manager_choice=keep
            display_manager_override=keep
            shift
            ;;
        -h|--help)
            printf 'Usage: ./verify.sh [--profile NAME | --selection FILE] [--with-virtualization] [--keep-display-manager] [--skip-aur]\n'
            exit 0
            ;;
        *) die "unknown option: $1" ;;
    esac
done

selection_active=false
if [[ -n "$selection_file" ]]; then
    load_selection "$selection_file"
    if $profile_explicit && [[ "$profile" != "$SELECTION_PROFILE" ]]; then
        die "--profile conflicts with the saved selection profile"
    fi
    profile="$SELECTION_PROFILE"
    display_manager_choice="$SELECTION_DISPLAY_MANAGER"
    selection_active=true
fi
[[ -n "$display_manager_override" ]] && display_manager_choice="$display_manager_override"
case "$profile" in
    desktop|recommended|full) ;;
    *) die "profile must be desktop, recommended, or full" ;;
esac

failures=0
warnings=0
ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*" >&2; ((failures += 1)); }
notice() { printf 'warning: %s\n' "$*" >&2; ((warnings += 1)); }

if is_arch_linux; then
    ok "Arch Linux detected"
else
    bad "not running Arch Linux"
fi

declare -a expected=()
if $selection_active; then
    declare -a protected_packages=()
    append_manifest protected_packages "$PROJECT_ROOT/packages/base.txt"
    append_manifest protected_packages "$PROJECT_ROOT/packages/desktop.txt"
    expected+=("${protected_packages[@]}")
    [[ "$profile" == full ]] && append_manifest expected "$PROJECT_ROOT/packages/full-current.txt"
    declare -A excluded_lookup=() protected_lookup=()
    for package in "${SELECTION_EXCLUDES[@]}"; do excluded_lookup["$package"]=1; done
    for package in "${protected_packages[@]}"; do protected_lookup["$package"]=1; done
    declare -a filtered_expected=()
    for package in "${expected[@]}"; do
        if [[ -n "${excluded_lookup[$package]:-}" && -z "${protected_lookup[$package]:-}" ]]; then
            continue
        fi
        filtered_expected+=("$package")
    done
    expected=("${filtered_expected[@]}" "${SELECTION_REPO_PACKAGES[@]}")
    for selected_group in "${SELECTION_GROUPS[@]}"; do
        group_file="$(group_manifest "$selected_group")"
        append_manifest expected "$group_file"
    done
else
    append_manifest expected "$PROJECT_ROOT/packages/base.txt"
    case "$profile" in
        desktop)
            append_manifest expected "$PROJECT_ROOT/packages/desktop.txt"
            append_manifest expected "$PROJECT_ROOT/packages/apps-desktop.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-bluetooth.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-firewall.txt"
            ;;
        recommended)
            append_manifest expected "$PROJECT_ROOT/packages/desktop.txt"
            append_manifest expected "$PROJECT_ROOT/packages/apps.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-bluetooth.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-printing.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-extended-files.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-firewall.txt"
            ;;
        full)
            append_manifest expected "$PROJECT_ROOT/packages/desktop.txt"
            append_manifest expected "$PROJECT_ROOT/packages/apps.txt"
            append_manifest expected "$PROJECT_ROOT/packages/apps-full-extra.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-bluetooth.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-printing.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-extended-files.txt"
            append_manifest expected "$PROJECT_ROOT/packages/feature-firewall.txt"
            append_manifest expected "$PROJECT_ROOT/packages/virtualization.txt"
            append_manifest expected "$PROJECT_ROOT/packages/legacy-extras.txt"
            append_manifest expected "$PROJECT_ROOT/packages/full-current.txt"
            ;;
    esac
fi
if $with_virtualization && [[ "$profile" != full || "$selection_active" == true ]]; then
    append_manifest expected "$PROJECT_ROOT/packages/virtualization.txt"
fi
if [[ "$display_manager_choice" == greetd ]]; then
    append_manifest expected "$PROJECT_ROOT/packages/feature-login-greetd.txt"
else
    declare -a without_greetd=()
    for package in "${expected[@]}"; do
        [[ "$package" == greetd || "$package" == greetd-regreet ]] && continue
        without_greetd+=("$package")
    done
    expected=("${without_greetd[@]}")
fi

cpu_vendor="$(awk -F: '/vendor_id/{gsub(/[[:space:]]/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
case "$cpu_vendor" in
    AuthenticAMD) expected+=(amd-ucode) ;;
    GenuineIntel) expected+=(intel-ucode) ;;
esac
declare -A gpu_vendors=()
detect_gpu_vendors gpu_vendors
[[ -n "${gpu_vendors[0x1002]:-}" ]] && expected+=(mesa vulkan-radeon)
[[ -n "${gpu_vendors[0x8086]:-}" ]] && expected+=(mesa vulkan-intel intel-media-driver)
mapfile -t expected < <(printf '%s\n' "${expected[@]}" | sort -u)

missing=()
for package in "${expected[@]}"; do
    pacman -Q "$package" >/dev/null 2>&1 || missing+=("$package")
done
if ((${#missing[@]})); then
    bad "missing profile packages: ${missing[*]}"
else
    ok "all $profile profile packages are installed"
fi

declare -a expected_aur=()
if ! $skip_aur && $selection_active; then
    expected_aur=("${SELECTION_AUR_PACKAGES[@]}")
elif ! $skip_aur && [[ "$profile" == recommended ]]; then
    mapfile -t expected_aur < <(read_manifest "$PROJECT_ROOT/packages/aur.txt")
elif ! $skip_aur && [[ "$profile" == full ]]; then
    mapfile -t expected_aur < <(read_manifest "$PROJECT_ROOT/packages/aur-current.txt")
fi
missing_aur=()
for package in "${expected_aur[@]}"; do
    if [[ "$package" == rustdesk-bin ]]; then
        pacman -Q rustdesk-bin >/dev/null 2>&1 || command -v rustdesk >/dev/null 2>&1 || missing_aur+=("$package")
    else
        pacman -Q "$package" >/dev/null 2>&1 || missing_aur+=("$package")
    fi
done
if ((${#missing_aur[@]})); then
    bad "missing selected AUR packages: ${missing_aur[*]}"
elif ((${#expected_aur[@]})); then
    ok "all selected AUR packages are installed"
fi

if pacman -Qq | grep -Eq '(^|-)nvidia($|-)'; then
    if [[ -n "${gpu_vendors[0x10de]:-}" ]]; then
        ok "NVIDIA packages correspond to detected NVIDIA hardware"
    else
        notice "NVIDIA packages are installed without detected NVIDIA hardware"
    fi
else
    ok "no NVIDIA package names detected"
fi
if [[ -z "${gpu_vendors[0x10de]:-}" ]] && \
   grep -RqsE '(^|[^[:alnum:]_])nvidia([^[:alnum:]_]|$)' \
       /etc/mkinitcpio.conf /etc/mkinitcpio.conf.d 2>/dev/null; then
    notice "NVIDIA references remain in the target initramfs configuration"
fi

required_commands=(
    awww brightnessctl cliphist grim gtklock hyprctl jq kitty
    hyprlock loginctl mako notify-send pavucontrol playerctl python qalc qs slurp
    start-hyprland systemctl thunar wl-copy wpctl xdg-mime
)
[[ "$display_manager_choice" == greetd ]] && required_commands+=(regreet)
expected_has() {
    local wanted="$1" package
    for package in "${expected[@]}"; do [[ "$package" == "$wanted" ]] && return 0; done
    return 1
}
expected_has firefox && required_commands+=(firefox)
expected_has chromium && required_commands+=(chromium)
expected_has obsidian && required_commands+=(obsidian)
expected_has mpv && required_commands+=(mpv)
expected_has vlc && required_commands+=(vlc)
expected_has thunderbird && required_commands+=(thunderbird)
expected_has qbittorrent && required_commands+=(qbittorrent)
expected_has libreoffice-fresh && required_commands+=(libreoffice)
expected_has lite-xl && required_commands+=(lite-xl)
expected_has sublime-text && required_commands+=(subl)
expected_has remmina && required_commands+=(remmina)
expected_has github-cli && required_commands+=(gh)
expected_has rclone && required_commands+=(rclone)
expected_has catfish && required_commands+=(catfish)
expected_has bluez-utils && required_commands+=(bluetoothctl)
for package in "${expected_aur[@]}"; do
    [[ "$package" == cloudflare-warp-bin ]] && required_commands+=(warp-cli)
    [[ "$package" == rustdesk-bin ]] && required_commands+=(rustdesk)
done
missing_commands=()
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
if ((${#missing_commands[@]})); then
    bad "desktop commands missing: ${missing_commands[*]}"
else
    ok "all commands referenced by the active desktop are available"
fi

required_files=(
    "$HOME/.config/hypr/hyprland.lua"
    "$HOME/.config/hypr/monitors.gen.lua"
    "$HOME/.config/quickshell/shell.qml"
    "$HOME/.config/quickshell/scripts/compositorctl.py"
    "$HOME/.config/systemd/user/hyprland-session.target"
    "$HOME/.config/gtklock/config.ini"
    /etc/keyd/default.conf
    /etc/locale.conf
    /etc/localtime
)
if [[ "$display_manager_choice" == greetd ]]; then
    required_files+=(/etc/greetd/config.toml /etc/greetd/hyprland.lua)
fi
for file in "${required_files[@]}"; do
    [[ -f "$file" ]] || bad "configuration file missing: $file"
done

for script in \
    "$HOME/.config/hypr/scripts/lock-screen.sh" \
    "$HOME/.config/hypr/scripts/wallpaper-rotate.sh" \
    "$HOME/.config/quickshell/scripts/session-launch.sh" \
    "$HOME/.config/quickshell/scripts/warp-control.sh"; do
    if [[ -f "$script" ]]; then
        [[ -x "$script" ]] || bad "desktop script is not executable: $script"
        bash -n "$script" || bad "shell syntax failed: $script"
    fi
done

python - <<'PY' || bad "Python GTK bindings required by the custom calculator are unavailable"
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk  # noqa: F401
PY

if [[ -f "$HOME/.config/quickshell/scripts/compositorctl.py" ]]; then
    python - "$HOME/.config/quickshell/scripts/compositorctl.py" <<'PY' || bad "Python syntax failed: compositorctl.py"
import ast
from pathlib import Path
import sys
ast.parse(Path(sys.argv[1]).read_text(), filename=sys.argv[1])
PY
fi

if [[ -d "$HOME/.config/systemd/user" ]]; then
    broken_links="$(find "$HOME/.config/systemd/user" -xtype l -print 2>/dev/null || true)"
    if [[ -n "$broken_links" ]]; then
        bad "broken user-service links: ${broken_links//$'\n'/, }"
    else
        ok "user-service links resolve"
    fi
fi

source_home=""
source_home="$(metadata_value "$PROJECT_ROOT/payload/meta.tsv" source_home 2>/dev/null || true)"
if [[ -n "$source_home" ]]; then
    validate_source_home "$source_home" || bad "invalid source home in bundle metadata"
fi
if [[ -n "$source_home" && "$source_home" != "$HOME" ]]; then
    declare -a portable_roots=()
    while IFS= read -r relative; do
        [[ -e "$HOME/$relative" || -L "$HOME/$relative" ]] && portable_roots+=("$HOME/$relative")
    done < <(read_manifest "$PROJECT_ROOT/manifests/home-safe.txt")
    if ((${#portable_roots[@]})) && \
       grep -RIl --exclude='*.pyc' --fixed-strings "$source_home" \
           "${portable_roots[@]}" >/dev/null 2>&1; then
        bad "old home path remains in restored desktop configuration: $source_home"
    else
        ok "old home path was rewritten to $HOME"
    fi
fi

expected_units=(
    NetworkManager.service
    fstrim.timer
    keyd.service
    power-profiles-daemon.service
    systemd-timesyncd.service
)
expected_has ufw && expected_units+=(ufw.service)
if [[ "$display_manager_choice" == greetd ]]; then
    expected_units+=(greetd.service)
fi
expected_has bluez && expected_units+=(bluetooth.service)
expected_has avahi && expected_units+=(avahi-daemon.service)
expected_has cups && expected_units+=(cups.service)
expected_has docker && expected_units+=(docker.service)
expected_has libvirt && expected_units+=(libvirtd.service)
for package in "${expected_aur[@]}"; do
    [[ "$package" == cloudflare-warp-bin ]] && expected_units+=(warp-svc.service)
    [[ "$package" == rustdesk-bin ]] && expected_units+=(rustdesk.service)
done

for unit in "${expected_units[@]}"; do
    if systemctl list-unit-files --no-legend "$unit" 2>/dev/null | grep -q .; then
        systemctl is-enabled "$unit" >/dev/null 2>&1 || notice "$unit is not enabled"
    fi
done

if [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] && command -v hyprctl >/dev/null 2>&1; then
    config_errors="$(hyprctl configerrors 2>/dev/null || true)"
    if [[ -z "$config_errors" ]]; then
        ok "Hyprland reports no config errors"
    else
        bad "Hyprland config errors: $config_errors"
    fi
else
    notice "Hyprland is not running; live config validation was skipped"
fi

printf '\nVerification: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
((failures == 0))
