#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
ENCRYPTED_BUNDLE="$SCRIPT_DIR/arch-migration.tar.zst.gpg"
CHECKSUM_FILE="$ENCRYPTED_BUNDLE.sha256"
prepare_only=false

usage() {
    cat <<'EOF'
Usage: ./install/deploy.sh [--prepare-only]

Decrypt the bundled personal migration payload, add it to this checkout, and
launch the guided Arch + Hyprland installer. The password is read silently and
is never saved or passed as a command-line argument.

Options:
  --prepare-only  Decrypt and prepare the payload without launching setup.sh
  -h, --help      Show this help
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --prepare-only)
            prepare_only=true
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

((EUID != 0)) || die "run this as your normal desktop user, not root"
[[ -f /etc/arch-release ]] || die "this deployment helper supports Arch Linux only"
command -v sudo >/dev/null 2>&1 || die "sudo is required"
[[ -t 0 ]] || die "run this from an interactive terminal so the password can be entered safely"
[[ -f "$ENCRYPTED_BUNDLE" ]] || die "encrypted migration bundle is missing"
[[ -f "$CHECKSUM_FILE" ]] || die "encrypted migration bundle checksum is missing"

declare -a bootstrap_packages=()
command -v gpg >/dev/null 2>&1 || bootstrap_packages+=(gnupg)
command -v rsync >/dev/null 2>&1 || bootstrap_packages+=(rsync)
command -v zstd >/dev/null 2>&1 || bootstrap_packages+=(zstd)

if ((${#bootstrap_packages[@]})); then
    printf '\nInstalling tools required to open the encrypted bundle...\n'
    sudo pacman -Syu --needed -- "${bootstrap_packages[@]}"
fi

(
    cd -- "$SCRIPT_DIR"
    sha256sum --check "$(basename -- "$CHECKSUM_FILE")"
) || die "encrypted migration bundle failed its checksum"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/arch-migration-deploy.XXXXXXXX")"
cleanup() {
    if [[ -n "${work_dir:-}" && -d "$work_dir" && \
          "$work_dir" == "${TMPDIR:-/tmp}"/arch-migration-deploy.* ]]; then
        rm -rf -- "$work_dir"
    fi
}
trap cleanup EXIT INT TERM

plain_bundle="$work_dir/arch-migration.tar.zst"
printf '\nMigration bundle password: '
IFS= read -r -s passphrase
printf '\n'
[[ -n "$passphrase" ]] || die "the password cannot be empty"

if ! printf '%s\n' "$passphrase" | gpg \
    --batch \
    --yes \
    --pinentry-mode loopback \
    --passphrase-fd 0 \
    --output "$plain_bundle" \
    --decrypt "$ENCRYPTED_BUNDLE"; then
    unset passphrase
    die "the bundle could not be decrypted; check the password"
fi
unset passphrase

bundle_root="$work_dir/extracted/arch-migration"
mkdir -p -- "$work_dir/extracted"
tar --zstd -xf "$plain_bundle" -C "$work_dir/extracted" \
    arch-migration/payload \
    arch-migration/selection.conf

[[ -d "$bundle_root/payload/home" ]] || die "decrypted bundle has no home payload"
[[ -f "$bundle_root/selection.conf" ]] || die "decrypted bundle has no saved selection"

mkdir -p -- "$PROJECT_ROOT/payload"
rsync -a "$bundle_root/payload/" "$PROJECT_ROOT/payload/"
install -m600 "$bundle_root/selection.conf" "$PROJECT_ROOT/selection.conf"

printf '\nMigration payload is ready in: %s\n' "$PROJECT_ROOT"
if $prepare_only; then
    printf 'Run ./setup.sh from that directory when you are ready.\n'
    exit 0
fi

exec "$PROJECT_ROOT/setup.sh"
