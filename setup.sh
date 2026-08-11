#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

preset=""
selection_file="$PROJECT_ROOT/selection.conf"
save_only=false
preview_only=false
non_interactive=false
assume_yes=false
force_private=false
force_keep_display_manager=false
export_output=""
include_wallpapers=true
force_no_wallpapers=false

usage() {
    cat <<'EOF'
Usage: ./setup.sh [OPTIONS]

Guided, dependency-free migration assistant. On the source machine it creates
the transfer archive; inside an exported bundle it installs the chosen setup.

Options:
  --preset NAME          Start from desktop, recommended, or full
  --selection FILE       Save/load a different selection file
  --restore-private      Include/restore encrypted private application state
  --keep-display-manager Keep the target's current login manager
  --output FILE          Export archive path when running on the source
  --no-wallpapers        Omit wallpapers from the source export
  --save-only            Save choices without installing
  --dry-run              Save choices and preview the next export/install
  --non-interactive      Accept preset/saved defaults without showing the menu
  --yes                  Pass non-interactive confirmation to export/install
  -h, --help             Show this help
EOF
}

while (($#)); do
    case "$1" in
        --preset)
            (($# >= 2)) || die "--preset needs a name"
            preset="$2"
            shift 2
            ;;
        --selection)
            (($# >= 2)) || die "--selection needs a path"
            selection_file="$2"
            shift 2
            ;;
        --restore-private)
            force_private=true
            shift
            ;;
        --keep-display-manager)
            force_keep_display_manager=true
            shift
            ;;
        --output)
            (($# >= 2)) || die "--output needs a path"
            export_output="$2"
            shift 2
            ;;
        --no-wallpapers)
            include_wallpapers=false
            force_no_wallpapers=true
            shift
            ;;
        --save-only)
            save_only=true
            shift
            ;;
        --dry-run)
            preview_only=true
            shift
            ;;
        --non-interactive)
            non_interactive=true
            shift
            ;;
        --yes)
            assume_yes=true
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

case "$preset" in
    ""|desktop|recommended|full) ;;
    *) die "preset must be desktop, recommended, or full" ;;
esac
((EUID != 0)) || die "run this as the target desktop user, not root"

catalog="$PROJECT_ROOT/packages/apps.catalog"
[[ -f "$catalog" ]] || die "application catalog is missing: $catalog"

declare -a item_ids=() item_labels=() item_sources=() item_defaults=() item_specs=() item_descriptions=()
while IFS='|' read -r id label source defaults spec description; do
    [[ -n "$id" && "$id" != \#* ]] || continue
    [[ "$id" =~ ^[a-z0-9_]+$ ]] || die "invalid catalog id: $id"
    [[ "$source" == repo || "$source" == aur || "$source" == group ]] || \
        die "invalid source for $id: $source"
    item_ids+=("$id")
    item_labels+=("$label")
    item_sources+=("$source")
    item_defaults+=("$defaults")
    item_specs+=("$spec")
    item_descriptions+=("$description")
done < "$catalog"

((${#item_ids[@]} > 0)) || die "application catalog is empty"
declare -A chosen=()
private_choice=no
display_manager_choice=greetd
loaded_saved=false

csv_contains() {
    local csv="$1" wanted="$2"
    [[ ",$csv," == *",$wanted,"* ]]
}

set_preset_choices() {
    local selected_preset="$1" index
    for index in "${!item_ids[@]}"; do
        if csv_contains "${item_defaults[$index]}" "$selected_preset"; then
            chosen["${item_ids[$index]}"]=1
        else
            chosen["${item_ids[$index]}"]=0
        fi
    done
}

if [[ -f "$selection_file" && -z "$preset" ]]; then
    load_selection "$selection_file"
    preset="$SELECTION_PROFILE"
    private_choice="$SELECTION_PRIVATE"
    if ! $force_no_wallpapers; then
        [[ "$SELECTION_WALLPAPERS" == yes ]] && include_wallpapers=true || include_wallpapers=false
    fi
    display_manager_choice="$SELECTION_DISPLAY_MANAGER"
    declare -A saved_repo=() saved_aur=() saved_groups=()
    for value in "${SELECTION_REPO_PACKAGES[@]}"; do saved_repo["$value"]=1; done
    for value in "${SELECTION_AUR_PACKAGES[@]}"; do saved_aur["$value"]=1; done
    for value in "${SELECTION_GROUPS[@]}"; do saved_groups["$value"]=1; done
    for index in "${!item_ids[@]}"; do
        source_type="${item_sources[$index]}"
        spec="${item_specs[$index]}"
        selected=1
        if [[ "$source_type" == group ]]; then
            [[ -n "${saved_groups[$spec]:-}" ]] || selected=0
        else
            IFS=',' read -r -a spec_packages <<< "$spec"
            for package in "${spec_packages[@]}"; do
                if [[ "$source_type" == repo ]]; then
                    [[ -n "${saved_repo[$package]:-}" ]] || selected=0
                else
                    [[ -n "${saved_aur[$package]:-}" ]] || selected=0
                fi
            done
        fi
        chosen["${item_ids[$index]}"]="$selected"
    done
    loaded_saved=true
fi

if [[ -z "$preset" ]]; then
    if $non_interactive; then
        die "--non-interactive needs --preset or an existing selection file"
    fi
    printf '\nChoose a starting point:\n\n'
    printf '  1. Recommended  Balanced desktop and commonly used applications\n'
    printf '  2. Desktop only Minimal Hyprland desktop with Firefox and MPV\n'
    printf '  3. Full          Every application and optional feature\n\n'
    read -r -p 'Preset [1]: ' preset_reply
    case "${preset_reply:-1}" in
        1|recommended) preset=recommended ;;
        2|desktop) preset=desktop ;;
        3|full) preset=full ;;
        *) die "invalid preset choice" ;;
    esac
    set_preset_choices "$preset"
elif ! $loaded_saved; then
    set_preset_choices "$preset"
fi

render_menu() {
    local index mark source_tag
    printf '\nApplications and optional features\n'
    printf 'The Hyprland/Quickshell core, Kitty, Thunar, audio, locking and fonts are always installed.\n\n'
    for index in "${!item_ids[@]}"; do
        mark=' '
        [[ "${chosen[${item_ids[$index]}]}" == 1 ]] && mark=x
        case "${item_sources[$index]}" in
            aur) source_tag=AUR ;;
            group) source_tag=feature ;;
            *) source_tag=app ;;
        esac
        printf '  %2d. [%s] %-22s %-7s %s\n' \
            "$((index + 1))" "$mark" "${item_labels[$index]}" "$source_tag" "${item_descriptions[$index]}"
    done
    printf '\nEnter numbers to toggle; a=all, n=none, r=reset, d=desktop, m=recommended, f=full.\n'
    printf 'Current preset: %s. Press Enter to continue.\n' "$preset"
}

if ! $non_interactive; then
    while true; do
        render_menu
        read -r -p '> ' toggle_reply
        [[ -n "$toggle_reply" ]] || break
        toggle_reply="${toggle_reply//,/ }"
        for token in $toggle_reply; do
            case "$token" in
                a)
                    for id in "${item_ids[@]}"; do chosen["$id"]=1; done
                    ;;
                n)
                    for id in "${item_ids[@]}"; do chosen["$id"]=0; done
                    ;;
                r)
                    set_preset_choices "$preset"
                    ;;
                d)
                    preset=desktop
                    set_preset_choices "$preset"
                    ;;
                m)
                    preset=recommended
                    set_preset_choices "$preset"
                    ;;
                f)
                    preset=full
                    set_preset_choices "$preset"
                    ;;
                *[!0-9]*|'')
                    warn "ignored invalid choice: $token"
                    ;;
                *)
                    if ((token >= 1 && token <= ${#item_ids[@]})); then
                        index=$((token - 1))
                        id="${item_ids[$index]}"
                        if [[ "${chosen[$id]}" == 1 ]]; then chosen["$id"]=0; else chosen["$id"]=1; fi
                    else
                        warn "ignored out-of-range choice: $token"
                    fi
                    ;;
            esac
        done
    done

    if $force_private; then
        if [[ -d "$PROJECT_ROOT/payload/home" && ! -f "$PROJECT_ROOT/private.tar.zst.gpg" ]]; then
            die "--restore-private was requested, but this bundle has no encrypted private archive"
        fi
        private_choice=yes
    elif [[ -d "$PROJECT_ROOT/payload/home" && ! -f "$PROJECT_ROOT/private.tar.zst.gpg" ]]; then
        [[ "$private_choice" == yes ]] && \
            warn "the saved choice requested private state, but this bundle does not contain it"
        private_choice=no
    else
        private_default=N
        [[ "$private_choice" == yes ]] && private_default=Y
        if [[ -f "$PROJECT_ROOT/private.tar.zst.gpg" ]]; then
            private_prompt="Restore encrypted browser/login/private state?"
        else
            private_prompt="Include encrypted browser/login/private state in the export?"
        fi
        read -r -p "$private_prompt [${private_default}/$( [[ $private_default == Y ]] && printf n || printf y )] " private_reply
        case "${private_reply:-$private_default}" in
            y|Y|yes|YES) private_choice=yes ;;
            *) private_choice=no ;;
        esac
    fi

    if $force_keep_display_manager; then
        display_manager_choice=keep
    else
        display_default=Y
        [[ "$display_manager_choice" == keep ]] && display_default=N
        read -r -p "Use the custom ReGreet login screen? [${display_default}/$( [[ $display_default == Y ]] && printf n || printf y )] " display_reply
        case "${display_reply:-$display_default}" in
            y|Y|yes|YES) display_manager_choice=greetd ;;
            *) display_manager_choice=keep ;;
        esac
    fi

    if [[ ! -d "$PROJECT_ROOT/payload/home" ]]; then
        if $force_no_wallpapers; then
            include_wallpapers=false
        else
            wallpaper_default=Y
            $include_wallpapers || wallpaper_default=N
            read -r -p "Include the 652 MiB wallpaper collection? [${wallpaper_default}/$( [[ $wallpaper_default == Y ]] && printf n || printf y )] " wallpaper_reply
            case "${wallpaper_reply:-$wallpaper_default}" in
                y|Y|yes|YES) include_wallpapers=true ;;
                *) include_wallpapers=false ;;
            esac
        fi
    fi
fi

$force_private && private_choice=yes
$force_keep_display_manager && display_manager_choice=keep
if [[ -d "$PROJECT_ROOT/payload/home" && "$private_choice" == yes && \
      ! -f "$PROJECT_ROOT/private.tar.zst.gpg" ]]; then
    die "private restore is selected, but this bundle has no encrypted private archive"
fi

declare -a selected_repo=() selected_aur=() selected_groups=() excluded_packages=()
for index in "${!item_ids[@]}"; do
    source_type="${item_sources[$index]}"
    spec="${item_specs[$index]}"
    if [[ "${chosen[${item_ids[$index]}]}" == 1 ]]; then
        case "$source_type" in
            repo)
                IFS=',' read -r -a spec_packages <<< "$spec"
                selected_repo+=("${spec_packages[@]}")
                ;;
            aur)
                IFS=',' read -r -a spec_packages <<< "$spec"
                selected_aur+=("${spec_packages[@]}")
                ;;
            group)
                selected_groups+=("$spec")
                ;;
        esac
    else
        if [[ "$source_type" == repo ]]; then
            IFS=',' read -r -a spec_packages <<< "$spec"
            excluded_packages+=("${spec_packages[@]}")
        elif [[ "$source_type" == group ]]; then
            group_file="$(group_manifest "$spec")"
            append_manifest excluded_packages "$group_file"
        fi
    fi
done

mapfile -t selected_repo < <(printf '%s\n' "${selected_repo[@]}" | awk 'NF' | sort -u)
mapfile -t selected_aur < <(printf '%s\n' "${selected_aur[@]}" | awk 'NF' | sort -u)
mapfile -t selected_groups < <(printf '%s\n' "${selected_groups[@]}" | awk 'NF' | sort -u)
mapfile -t excluded_packages < <(printf '%s\n' "${excluded_packages[@]}" | awk 'NF' | sort -u)

mkdir -p "$(dirname -- "$selection_file")"
selection_tmp="$(mktemp "${selection_file}.tmp.XXXXXXXX")"
{
    printf '# Generated by setup.sh. Re-run the wizard to change it.\n'
    printf 'format=1\nprofile=%s\nprivate=%s\nwallpapers=%s\ndisplay_manager=%s\n' \
        "$preset" "$private_choice" "$(if $include_wallpapers; then printf yes; else printf no; fi)" \
        "$display_manager_choice"
    for package in "${selected_repo[@]}"; do printf 'repo=%s\n' "$package"; done
    for package in "${selected_aur[@]}"; do printf 'aur=%s\n' "$package"; done
    for group in "${selected_groups[@]}"; do printf 'group=%s\n' "$group"; done
    for package in "${excluded_packages[@]}"; do printf 'exclude=%s\n' "$package"; done
} > "$selection_tmp"
mv -- "$selection_tmp" "$selection_file"

log "Choices saved"
printf '  selection: %s\n' "$selection_file"
printf '  preset: %s\n' "$preset"
printf '  repository application packages: %d\n' "${#selected_repo[@]}"
printf '  AUR application packages: %d\n' "${#selected_aur[@]}"
printf '  feature groups: %s\n' "${selected_groups[*]:-none}"
printf '  private restore: %s\n' "$private_choice"
printf '  wallpaper collection: %s\n' "$(if $include_wallpapers; then printf include; else printf omit; fi)"
printf '  login manager: %s\n' "$display_manager_choice"

if $save_only; then
    if [[ ! -d "$PROJECT_ROOT/payload/home" ]]; then
        if [[ "$selection_file" == "$PROJECT_ROOT"/* ]]; then
            printf '\nRun export.sh next; this selection will be included in the transfer archive.\n'
        else
            printf '\nRun export.sh --selection %q next to include these choices.\n' "$selection_file"
        fi
    fi
    exit 0
fi

if [[ -d "$PROJECT_ROOT/payload/home" ]]; then
    install_args=(--selection "$selection_file")
    $assume_yes && install_args+=(--yes)
    if $preview_only; then
        exec "$PROJECT_ROOT/install.sh" "${install_args[@]}" --dry-run
    fi
    if $non_interactive; then
        exec "$PROJECT_ROOT/install.sh" "${install_args[@]}"
    fi
    printf '\n  1. Install now\n  2. Preview only\n  3. Save and exit\n'
    read -r -p 'Next step [1]: ' action
    case "${action:-1}" in
        1) exec "$PROJECT_ROOT/install.sh" "${install_args[@]}" ;;
        2) exec "$PROJECT_ROOT/install.sh" "${install_args[@]}" --dry-run ;;
        3) exit 0 ;;
        *) die "invalid action" ;;
    esac
else
    export_args=(--selection "$selection_file")
    [[ -n "$export_output" ]] && export_args+=(--output "$export_output")
    $include_wallpapers || export_args+=(--no-wallpapers)
    if [[ "$private_choice" == yes ]]; then
        export_args+=(--include-private --yes)
    elif $assume_yes; then
        export_args+=(--yes)
    fi
    if $preview_only; then
        exec "$PROJECT_ROOT/export.sh" "${export_args[@]}" --dry-run
    fi
    if $non_interactive; then
        exec "$PROJECT_ROOT/export.sh" "${export_args[@]}"
    fi
    printf '\nNo payload is present, so this appears to be the source toolkit.\n'
    printf '  1. Create the transfer archive now\n  2. Preview the export\n  3. Save and exit\n'
    read -r -p 'Next step [1]: ' action
    case "${action:-1}" in
        1) exec "$PROJECT_ROOT/export.sh" "${export_args[@]}" ;;
        2) exec "$PROJECT_ROOT/export.sh" "${export_args[@]}" --dry-run ;;
        3) exit 0 ;;
        *) die "invalid action" ;;
    esac
fi
