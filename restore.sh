#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

restore_private=false
skip_system=false
skip_greetd=false
skip_firewall=false
dry_run=false

usage() {
    cat <<'EOF'
Usage: ./restore.sh [OPTIONS]

Restore the payload embedded by export.sh. Existing files are retained in
~/.local/state/arch-migration/backups and /var/backups/arch-migration.

Options:
  --private       Decrypt and restore the optional private archive
  --skip-system   Do not restore any system configuration under /etc
  --skip-greetd   Keep the target login manager and omit ReGreet configuration
  --skip-firewall Do not copy the source UFW policy
  --dry-run       Show the planned restore without changing files
  -h, --help      Show this help
EOF
}

while (($#)); do
    case "$1" in
        --private)
            restore_private=true
            shift
            ;;
        --skip-system)
            skip_system=true
            shift
            ;;
        --skip-greetd)
            skip_greetd=true
            shift
            ;;
        --skip-firewall)
            skip_firewall=true
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

if [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_TTY:-}" ]]; then
    if ! $skip_firewall; then
        warn "SSH session detected; skipping source UFW rules to avoid a remote lockout"
    fi
    skip_firewall=true
fi

((EUID != 0)) || die "run this as the target desktop user, not root"
payload="$PROJECT_ROOT/payload"
[[ -d "$payload/home" ]] || die "no payload found; run this from an archive created by export.sh"
umask 077

source_home=""
source_home="$(metadata_value "$payload/meta.tsv" source_home 2>/dev/null || true)"
if [[ -n "$source_home" ]]; then
    validate_source_home "$source_home" || die "invalid source home in bundle metadata"
fi

stamp="$(date +%Y%m%d-%H%M%S)"
home_backup="$HOME/.local/state/arch-migration/backups/$stamp"
system_backup="/var/backups/arch-migration/$stamp"

log "Restore plan"
printf '  source home: %s\n' "${source_home:-unknown}"
printf '  target home: %s\n' "$HOME"
printf '  user backup: %s\n' "$home_backup"
if ! $skip_system; then
    printf '  system backup: %s\n' "$system_backup"
    printf '  ReGreet configuration: %s\n' "$(if $skip_greetd; then printf skip; else printf restore; fi)"
    printf '  UFW configuration: %s\n' "$(if $skip_firewall; then printf skip; else printf restore; fi)"
fi
if $restore_private; then
    printf '  private state: encrypted archive will be restored\n'
fi

if $dry_run; then
    rsync -an --itemize-changes "$payload/home/" "$HOME/"
    if [[ -d "$payload/etc" ]] && ! $skip_system; then
        printf '\nSystem payload:\n'
        while IFS= read -r system_file; do
            system_relative="${system_file#"$payload/etc/"}"
            $skip_greetd && [[ "$system_relative" == greetd/* ]] && continue
            $skip_firewall && [[ "$system_relative" == ufw/* || "$system_relative" == default/ufw ]] && continue
            printf '  /etc/%s\n' "$system_relative"
        done < <(find "$payload/etc" -type f | sort)
        if ! $skip_greetd; then
            printf '  /etc/greetd/hyprland.lua (portable template)\n'
        fi
    fi
    exit 0
fi

command -v rsync >/dev/null 2>&1 || die "rsync is required"
mkdir -p "$home_backup"
chmod 700 "$HOME/.local/state/arch-migration" \
    "$HOME/.local/state/arch-migration/backups" "$home_backup"

log "Restoring user settings"
rsync -a \
    --backup \
    --backup-dir="$home_backup" \
    "$payload/home/" "$HOME/"

rewrite_paths() {
    local manifest="$1"
    local old_home="$2"
    [[ -n "$old_home" && "$old_home" != "$HOME" ]] || return 0
    python - "$old_home" "$HOME" "$manifest" <<'PY'
from pathlib import Path
import sys

old = sys.argv[1].encode()
new = sys.argv[2].encode()
manifest = Path(sys.argv[3])
home = Path.home()

for raw in manifest.read_text().splitlines():
    relative = raw.split("#", 1)[0].strip()
    if not relative:
        continue
    root = home / relative
    candidates = [root] if root.is_file() else (root.rglob("*") if root.is_dir() else [])
    for path in candidates:
        if not path.is_file() or path.is_symlink():
            continue
        try:
            data = path.read_bytes()
        except OSError:
            continue
        if b"\0" in data[:8192] or old not in data:
            continue
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        path.write_bytes(data.replace(old, new))
PY
}

rewrite_paths "$PROJECT_ROOT/manifests/home-safe.txt" "$source_home"

# The browser picker remains useful when only one browser was selected: an
# unavailable choice now produces a desktop notification instead of failing
# silently.
if [[ -f "$PROJECT_ROOT/templates/session-launch.sh" ]]; then
    install -Dm755 \
        "$PROJECT_ROOT/templates/session-launch.sh" \
        "$HOME/.config/quickshell/scripts/session-launch.sh"
fi
if [[ -f "$HOME/.config/hypr/hyprland.lua" ]]; then
    python - "$HOME/.config/hypr/hyprland.lua" \
        "$HOME/.config/quickshell/scripts/session-launch.sh" <<'PY'
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
launcher = sys.argv[2].replace("\\", "\\\\").replace('"', '\\"')
text = config_path.read_text()
text = text.replace(
    'hl.dsp.exec_cmd("obsidian")',
    f'hl.dsp.exec_cmd("{launcher} obsidian")',
)
config_path.write_text(text)
PY
fi

# Prevent the source config's HDMI-A-1 fallback from being selected on first
# boot. Never overwrite a monitor layout that was already saved on the target.
if [[ ! -e "$HOME/.config/hypr/monitors.gen.lua" && \
      -f "$PROJECT_ROOT/templates/monitors.gen.lua" ]]; then
    install -Dm644 \
        "$PROJECT_ROOT/templates/monitors.gen.lua" \
        "$HOME/.config/hypr/monitors.gen.lua"
fi

# A no-wallpapers export still gets one small usable background so the active
# rotation command and bar button do not fail on a missing/empty directory.
wallpaper_found=""
if [[ -d "$HOME/Wallpapers" && ! -L "$HOME/Wallpapers" ]]; then
    wallpaper_found="$(find "$HOME/Wallpapers" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
           -o -iname '*.gif' -o -iname '*.webp' \) -print -quit)"
fi
if [[ -z "$wallpaper_found" && ! -L "$HOME/Wallpapers" && \
      -f "$payload/etc/greetd/oled-mountains.jpg" ]]; then
    install -Dm644 "$payload/etc/greetd/oled-mountains.jpg" \
        "$HOME/Wallpapers/oled-mountains.jpg"
    printf 'Installed the login background as a lightweight wallpaper fallback.\n'
fi

# systemd enablement symlinks can contain the old machine's absolute home path.
if [[ -n "$source_home" && "$source_home" != "$HOME" && -d "$HOME/.config/systemd/user" ]]; then
    while IFS= read -r -d '' link; do
        target="$(readlink "$link")"
        if [[ "$target" == "$source_home"/* ]]; then
            replacement="$HOME/${target#"$source_home"/}"
            ln -sfn -- "$replacement" "$link"
        fi
    done < <(find "$HOME/.config/systemd/user" -type l -print0)
fi

if ! $skip_system; then
    log "Restoring portable system settings"
    sudo mkdir -p "$system_backup"
    if [[ -d "$payload/etc" ]]; then
        system_rsync_args=(-a \
            --chown=root:root \
            --chmod=D755 \
            --backup \
            --backup-dir="$system_backup")
        $skip_greetd && system_rsync_args+=(--exclude=/greetd/)
        $skip_firewall && system_rsync_args+=(--exclude=/ufw/ --exclude=/default/ufw)
        sudo rsync "${system_rsync_args[@]}" "$payload/etc/" /etc/
    fi
    if ! $skip_greetd && [[ -f "$PROJECT_ROOT/system/etc/greetd/hyprland.lua" ]]; then
        if [[ -f /etc/greetd/hyprland.lua ]]; then
            sudo mkdir -p "$system_backup/etc/greetd"
            sudo cp -a /etc/greetd/hyprland.lua "$system_backup/etc/greetd/hyprland.lua"
        fi
        sudo install -Dm644 \
            "$PROJECT_ROOT/system/etc/greetd/hyprland.lua" \
            /etc/greetd/hyprland.lua
    fi
fi

if $restore_private; then
    private_file="$PROJECT_ROOT/private.tar.zst.gpg"
    [[ -f "$private_file" ]] || die "this bundle has no encrypted private archive"
    command -v gpg >/dev/null 2>&1 || die "GnuPG is required for private restore"
    command -v bsdtar >/dev/null 2>&1 || die "bsdtar (libarchive) is required for private restore"
    private_stage="$(mktemp -d "${TMPDIR:-/tmp}/arch-migration-private.XXXXXXXX")"
    cleanup_private() {
        if [[ -n "${private_stage:-}" && -d "$private_stage" && "$private_stage" == "${TMPDIR:-/tmp}"/arch-migration-private.* ]]; then
            rm -rf -- "$private_stage"
        fi
    }
    trap cleanup_private EXIT INT TERM
    warn "private application state should be restored while those applications are closed"
    umask 077
    private_archive="$private_stage/private.tar.zst"
    member_list="$private_stage/members.txt"
    gpg --output "$private_archive" --decrypt "$private_file"
    bsdtar -tf "$private_archive" > "$member_list" || die "could not read the decrypted private archive"
    member_count=0
    while IFS= read -r member || [[ -n "$member" ]]; do
        ((member_count += 1))
        [[ "$member" == home || "$member" == home/ || "$member" == home/* ]] || \
            die "private archive contains a path outside home/: $member"
        validate_relative_path "${member%/}" || \
            [[ "$member" == home/ ]] || die "private archive contains an unsafe path: $member"
    done < "$member_list"
    ((member_count > 0)) || die "private archive is empty"
    bsdtar -xf "$private_archive" -C "$private_stage"
    [[ -d "$private_stage/home" && ! -L "$private_stage/home" ]] || \
        die "private archive did not contain a safe home directory"
    rm -f -- "$private_archive" "$member_list"
    rsync -a \
        --backup \
        --backup-dir="$home_backup/private" \
        "$private_stage/home/" "$HOME/"
    rewrite_paths "$PROJECT_ROOT/manifests/home-private.txt" "$source_home"
    cleanup_private
    trap - EXIT INT TERM
fi

if [[ -f "$HOME/.config/user-dirs.dirs" ]]; then
    while IFS= read -r user_dir_line; do
        if [[ "$user_dir_line" =~ ^XDG_[A-Z_]+_DIR=\"\$HOME/([^\"]+)\"$ ]]; then
            user_dir_relative="${BASH_REMATCH[1]}"
            if validate_relative_path "$user_dir_relative"; then
                mkdir -p "$HOME/$user_dir_relative"
            fi
        fi
    done < "$HOME/.config/user-dirs.dirs"
fi
command -v xdg-user-dirs-update >/dev/null 2>&1 && xdg-user-dirs-update || true
systemctl --user daemon-reload >/dev/null 2>&1 || warn "user systemd manager is not available yet; it will reload at login"

log "Restore complete"
printf 'Any replaced user files are recoverable from:\n  %s\n' "$home_backup"
if ! $skip_system; then
    printf 'Any replaced system files are recoverable from:\n  %s\n' "$system_backup"
fi
