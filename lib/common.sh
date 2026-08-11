#!/usr/bin/env bash

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

log() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

read_manifest() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 0
    awk '
        {
            sub(/[[:space:]]*#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (length($0)) print
        }
    ' "$manifest"
}

append_manifest() {
    local -n destination_array="$1"
    local manifest="$2" value
    while IFS= read -r value; do
        destination_array+=("$value")
    done < <(read_manifest "$manifest")
}

valid_package_name() {
    [[ "$1" =~ ^[a-zA-Z0-9@._+-]+$ ]]
}

array_contains() {
    local -n values_array="$1"
    local wanted="$2" value
    for value in "${values_array[@]}"; do
        [[ "$value" == "$wanted" ]] && return 0
    done
    return 1
}

group_manifest() {
    case "$1" in
        bluetooth) printf '%s/packages/feature-bluetooth.txt\n' "$PROJECT_ROOT" ;;
        printing) printf '%s/packages/feature-printing.txt\n' "$PROJECT_ROOT" ;;
        extended_files) printf '%s/packages/feature-extended-files.txt\n' "$PROJECT_ROOT" ;;
        firewall) printf '%s/packages/feature-firewall.txt\n' "$PROJECT_ROOT" ;;
        virtualization) printf '%s/packages/virtualization.txt\n' "$PROJECT_ROOT" ;;
        legacy) printf '%s/packages/legacy-extras.txt\n' "$PROJECT_ROOT" ;;
        *) return 1 ;;
    esac
}

load_selection() {
    local selection_file="$1" line key value
    [[ -f "$selection_file" ]] || die "selection file not found: $selection_file"

    SELECTION_FORMAT=""
    SELECTION_PROFILE=""
    SELECTION_PRIVATE=no
    SELECTION_WALLPAPERS=yes
    SELECTION_DISPLAY_MANAGER=greetd
    SELECTION_REPO_PACKAGES=()
    SELECTION_AUR_PACKAGES=()
    SELECTION_GROUPS=()
    SELECTION_EXCLUDES=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" && "$line" != \#* ]] || continue
        [[ "$line" == *=* ]] || die "invalid selection line: $line"
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            format)
                SELECTION_FORMAT="$value"
                ;;
            profile)
                [[ "$value" == desktop || "$value" == recommended || "$value" == full ]] || \
                    die "invalid selection profile: $value"
                SELECTION_PROFILE="$value"
                ;;
            repo)
                valid_package_name "$value" || die "invalid repository package in selection: $value"
                SELECTION_REPO_PACKAGES+=("$value")
                ;;
            aur)
                valid_package_name "$value" || die "invalid AUR package in selection: $value"
                SELECTION_AUR_PACKAGES+=("$value")
                ;;
            group)
                group_manifest "$value" >/dev/null || die "invalid feature group in selection: $value"
                SELECTION_GROUPS+=("$value")
                ;;
            exclude)
                valid_package_name "$value" || die "invalid excluded package in selection: $value"
                SELECTION_EXCLUDES+=("$value")
                ;;
            private)
                [[ "$value" == yes || "$value" == no ]] || die "private must be yes or no"
                SELECTION_PRIVATE="$value"
                ;;
            wallpapers)
                [[ "$value" == yes || "$value" == no ]] || die "wallpapers must be yes or no"
                SELECTION_WALLPAPERS="$value"
                ;;
            display_manager)
                [[ "$value" == greetd || "$value" == keep ]] || \
                    die "display_manager must be greetd or keep"
                SELECTION_DISPLAY_MANAGER="$value"
                ;;
            *)
                die "unknown selection key: $key"
                ;;
        esac
    done < "$selection_file"

    [[ "$SELECTION_FORMAT" == 1 ]] || die "unsupported selection format: ${SELECTION_FORMAT:-missing}"
    [[ -n "$SELECTION_PROFILE" ]] || die "selection has no profile"
}

metadata_value() {
    local metadata_file="$1" wanted_key="$2"
    [[ -f "$metadata_file" ]] || return 1
    awk -F '\t' -v wanted="$wanted_key" '$1 == wanted { sub(/^[^\t]*\t/, ""); print; exit }' "$metadata_file"
}

print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

is_arch_linux() {
    [[ -f /etc/arch-release ]] || [[ "$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")" == arch ]]
}

validate_relative_path() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    [[ "$value" != /* ]] || return 1
    [[ "/$value/" != *"/../"* ]] || return 1
    [[ "$value" != . ]] || return 1
}

validate_source_home() {
    local value="$1" normalized
    [[ "$value" == /* && "$value" != / ]] || return 1
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* && "$value" != *$'\t'* ]] || return 1
    normalized="/${value#/}/"
    [[ "$normalized" != *'/../'* && "$normalized" != *'/./'* && "$value" != *'//'* ]]
}

detect_gpu_vendors() {
    local -n destination_map="$1"
    local vendor_file class_file class_id vendor_id
    local restore_nullglob=false
    destination_map=()
    shopt -q nullglob || restore_nullglob=true
    shopt -s nullglob

    for vendor_file in /sys/class/drm/card*/device/vendor; do
        vendor_id="$(<"$vendor_file")"
        if [[ "$vendor_id" =~ ^0x[0-9a-fA-F]{4}$ ]]; then
            # shellcheck disable=SC2034 # assignment is through a nameref
            destination_map["${vendor_id,,}"]=1
        fi
    done
    # PCI display-class detection is a fallback for a fresh install where the
    # kernel driver has not created a DRM card yet.
    for class_file in /sys/bus/pci/devices/*/class; do
        class_id="$(<"$class_file")"
        [[ "$class_id" == 0x03* ]] || continue
        vendor_file="${class_file%/class}/vendor"
        [[ -r "$vendor_file" ]] || continue
        vendor_id="$(<"$vendor_file")"
        if [[ "$vendor_id" =~ ^0x[0-9a-fA-F]{4}$ ]]; then
            # shellcheck disable=SC2034 # assignment is through a nameref
            destination_map["${vendor_id,,}"]=1
        fi
    done
    $restore_nullglob && shopt -u nullglob
}
