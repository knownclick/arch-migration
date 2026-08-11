#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

output=""
include_private=false
include_wallpapers=true
wallpapers_explicit=false
assume_yes=false
dry_run=false
selection_file=""
selection_explicit=false

usage() {
    cat <<'EOF'
Usage: ./export.sh [OPTIONS]

Create a self-contained archive to transfer to the new Arch machine.

Options:
  --output FILE       Archive path (default: your home directory)
  --include-private   Add an encrypted archive of logins/private app state
  --selection FILE    Embed choices saved by setup.sh
  --no-wallpapers     Omit the 652 MiB Wallpapers directory
  --yes               Do not pause after private-data warnings
  --dry-run           Show what would be exported without writing anything
  -h, --help          Show this help
EOF
}

while (($#)); do
    case "$1" in
        --output)
            (($# >= 2)) || die "--output needs a path"
            output="$2"
            shift 2
            ;;
        --include-private)
            include_private=true
            shift
            ;;
        --selection)
            (($# >= 2)) || die "--selection needs a path"
            selection_file="$2"
            selection_explicit=true
            shift 2
            ;;
        --no-wallpapers)
            include_wallpapers=false
            wallpapers_explicit=true
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

is_arch_linux || die "this export must be run on the old Arch Linux system"
((EUID != 0)) || die "run this as the desktop user, not root"

if [[ -z "$selection_file" && -f "$PROJECT_ROOT/selection.conf" ]]; then
    selection_file="$PROJECT_ROOT/selection.conf"
fi
if [[ -n "$selection_file" ]]; then
    load_selection "$selection_file"
    [[ "$SELECTION_PRIVATE" == yes ]] && include_private=true
    if ! $wallpapers_explicit && [[ "$SELECTION_WALLPAPERS" == no ]]; then
        include_wallpapers=false
    fi
elif $selection_explicit; then
    die "selection file not found: $selection_file"
fi

source_host=""
if [[ -r /proc/sys/kernel/hostname ]]; then
    IFS= read -r source_host < /proc/sys/kernel/hostname || true
fi
[[ -n "$source_host" ]] || source_host=old-arch
host_tag="$(printf '%s' "$source_host" | sed 's/[^A-Za-z0-9._-]/_/g')"
[[ -n "$host_tag" ]] || host_tag=old-arch
stamp="$(date +%Y%m%d-%H%M%S)"
if [[ -z "$output" ]]; then
    output="$HOME/arch-migration-${host_tag}-${stamp}.tar.zst"
fi

show_manifest() {
    local title="$1"
    local manifest="$2"
    local prefix="$3"
    local relative source size
    log "$title"
    while IFS= read -r relative; do
        if [[ "$prefix" == home ]]; then
            validate_relative_path "$relative" || die "unsafe home manifest entry: $relative"
            source="$HOME/$relative"
        else
            [[ "$relative" == /* && "/$relative/" != *"/../"* ]] || die "unsafe system manifest entry: $relative"
            source="$relative"
        fi
        if [[ -e "$source" || -L "$source" ]]; then
            size="$(du -sh --apparent-size "$source" 2>/dev/null | awk '{print $1}' || printf '?')"
            printf '  %-8s %s\n' "$size" "$source"
        else
            printf '  %-8s %s (not present)\n' "-" "$source"
        fi
    done < <(read_manifest "$manifest")
}

show_manifest "Portable home configuration" "$PROJECT_ROOT/manifests/home-safe.txt" home
if $include_wallpapers; then
    show_manifest "Desktop assets" "$PROJECT_ROOT/manifests/home-assets.txt" home
else
    log "Desktop assets"
    printf '  Wallpapers skipped by --no-wallpapers\n'
fi
show_manifest "Portable system configuration" "$PROJECT_ROOT/manifests/system-safe.txt" system
if [[ -n "$selection_file" ]]; then
    log "Saved installation choices"
    printf '  profile: %s\n  repository apps: %d\n  AUR apps: %d\n  feature groups: %s\n' \
        "$SELECTION_PROFILE" "${#SELECTION_REPO_PACKAGES[@]}" \
        "${#SELECTION_AUR_PACKAGES[@]}" "${SELECTION_GROUPS[*]:-none}"
fi

if $include_private; then
    show_manifest "Private paths (encrypted; never stored in plaintext in the final bundle)" \
        "$PROJECT_ROOT/manifests/home-private.txt" home
    warn "close Chromium, Firefox, Thunderbird, Obsidian, RustDesk, Claude and Codex first"
    if pgrep -x chromium >/dev/null 2>&1 ||
       pgrep -x firefox >/dev/null 2>&1 ||
       pgrep -x thunderbird >/dev/null 2>&1 ||
       pgrep -x obsidian >/dev/null 2>&1 ||
       pgrep -x rustdesk >/dev/null 2>&1; then
        warn "one or more private-data applications still appear to be running"
    fi
    if ! $assume_yes && ! $dry_run; then
        [[ -t 0 ]] || die "use --yes for a non-interactive private export"
        read -r -p "Continue and encrypt private state? [y/N] " reply
        [[ "$reply" =~ ^[Yy]$ ]] || die "private export cancelled"
    fi
fi

if $dry_run; then
    log "Dry run complete"
    printf 'Archive would be written to: %s\n' "$output"
    printf 'Checksum would be written to: %s.sha256\n' "$output"
    exit 0
fi

for command_name in rsync tar zstd pacman; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command is missing: $command_name"
done
if $include_private; then
    command -v gpg >/dev/null 2>&1 || die "GnuPG is required for --include-private"
fi

[[ ! -e "$output" ]] || die "refusing to overwrite existing archive: $output"
checksum_file="${output}.sha256"
[[ ! -e "$checksum_file" ]] || die "refusing to overwrite existing checksum: $checksum_file"
mkdir -p -- "$(dirname -- "$output")"

umask 077
stage="$(mktemp -d "${TMPDIR:-/tmp}/arch-migration-export.XXXXXXXX")"
cleanup() {
    if [[ -n "${stage:-}" && -d "$stage" && "$stage" == "${TMPDIR:-/tmp}"/arch-migration-export.* ]]; then
        rm -rf -- "$stage"
    fi
}
trap cleanup EXIT INT TERM

bundle_root="$stage/arch-migration"
mkdir -p "$bundle_root"

log "Copying the migration toolkit"
rsync -a \
    --exclude '/payload/' \
    --exclude '/private.tar.zst.gpg' \
    --exclude 'arch-migration-*.tar.zst' \
    --exclude '/*.tar.zst' \
    --exclude '/*.tar.zst.sha256' \
    --exclude '*.tmp' \
    "$PROJECT_ROOT/" "$bundle_root/"
if [[ -n "$selection_file" ]]; then
    install -m600 "$selection_file" "$bundle_root/selection.conf"
fi

payload="$bundle_root/payload"
mkdir -p "$payload/home" "$payload/etc" "$payload/reports"

copy_home_manifest() {
    local manifest="$1"
    local destination="$2"
    local relative source parent
    while IFS= read -r relative; do
        validate_relative_path "$relative" || die "unsafe home manifest entry: $relative"
        source="$HOME/$relative"
        if [[ ! -e "$source" && ! -L "$source" ]]; then
            continue
        fi
        parent="$destination/$(dirname -- "$relative")"
        mkdir -p "$parent"
        rsync -a \
            --exclude '__pycache__/' \
            --exclude '*.pyc' \
            --exclude '*.codex-backup-*' \
            --exclude 'monitors.gen.lua' \
            --exclude 'monitors.gen.lua.*' \
            --exclude 'lockfile' \
            "$source" "$parent/"
    done < <(read_manifest "$manifest")
}

copy_system_manifest() {
    local manifest="$1"
    local destination="$2"
    local absolute relative parent
    while IFS= read -r absolute; do
        [[ "$absolute" == /* && "/$absolute/" != *"/../"* ]] || die "unsafe system manifest entry: $absolute"
        [[ -e "$absolute" || -L "$absolute" ]] || continue
        [[ -r "$absolute" ]] || {
            warn "not readable; skipped: $absolute"
            continue
        }
        relative="${absolute#/}"
        parent="$destination/$(dirname -- "$relative")"
        mkdir -p "$parent"
        rsync -a "$absolute" "$parent/"
    done < <(read_manifest "$manifest")
}

log "Copying portable settings"
copy_home_manifest "$PROJECT_ROOT/manifests/home-safe.txt" "$payload/home"
if $include_wallpapers; then
    copy_home_manifest "$PROJECT_ROOT/manifests/home-assets.txt" "$payload/home"
fi
copy_system_manifest "$PROJECT_ROOT/manifests/system-safe.txt" "$payload"

# The staging tree is created under umask 077, but these directories are
# restored below /etc and must remain traversable by normal system services.
# File modes still come from the source files themselves.
find "$payload/etc" -type d -exec chmod 755 {} +

log "Recording a fresh package and service inventory"
metadata_user="${USER//$'\t'/ }"
metadata_user="${metadata_user//$'\n'/ }"
metadata_home="${HOME//$'\t'/ }"
metadata_home="${metadata_home//$'\n'/ }"
metadata_host="${source_host//$'\t'/ }"
metadata_host="${metadata_host//$'\n'/ }"
printf 'source_user\t%s\nsource_home\t%s\nsource_host\t%s\nexported_at\t%s\n' \
    "$metadata_user" "$metadata_home" "$metadata_host" "$(date --iso-8601=seconds)" > "$payload/meta.tsv"

pacman -Qqen | awk '
    $0 !~ /nvidia/ &&
    $0 !~ /^(amd-ucode|intel-ucode|egl-wayland|vulkan-radeon|vulkan-intel|intel-media-driver|xf86-video-amdgpu|xf86-video-intel)$/
' | sort -u > "$bundle_root/packages/full-current.txt"

pacman -Qqem | awk '
    /nvidia/ { next }
    $0 == "rustdesk" { print "rustdesk-bin"; next }
    { print }
' | sort -u > "$bundle_root/packages/aur-current.txt"

pacman -Qe > "$payload/reports/explicit-package-versions.txt"
pacman -Q > "$payload/reports/all-package-versions.txt"
systemctl list-unit-files --state=enabled --no-legend --no-pager \
    > "$payload/reports/enabled-system-services.txt" 2>/dev/null || true
systemctl --user list-unit-files --state=enabled --no-legend --no-pager \
    > "$payload/reports/enabled-user-services.txt" 2>/dev/null || true

if $include_private; then
    log "Creating encrypted private-state archive"
    private_stage="$stage/private-state"
    mkdir -p "$private_stage/home"
    copy_home_manifest "$PROJECT_ROOT/manifests/home-private.txt" "$private_stage/home"
    private_archive="$stage/private-state.tar.zst"
    tar --zstd -cf "$private_archive" -C "$private_stage" home
    export GPG_TTY="${GPG_TTY:-$(tty 2>/dev/null || true)}"
    gpg --symmetric \
        --cipher-algo AES256 \
        --compress-algo none \
        --pinentry-mode loopback \
        --no-symkey-cache \
        --output "$bundle_root/private.tar.zst.gpg" \
        "$private_archive"
    rm -f -- "$private_archive"
fi

log "Compressing the transfer archive"
tar --zstd -cf "$output" -C "$stage" arch-migration

output_directory="$(cd -- "$(dirname -- "$output")" && pwd -P)"
output_basename="$(basename -- "$output")"
(
    cd -- "$output_directory"
    sha256sum -- "$output_basename" > "${output_basename}.sha256"
)

log "Export complete"
du -h "$output"
printf '\nTransfer both files to the new machine:\n  %s\n  %s\n' "$output" "$checksum_file"
printf '\nVerify before extracting:\n  cd %q && sha256sum --check %q\n' \
    "$(dirname -- "$output")" "$(basename -- "$checksum_file")"
