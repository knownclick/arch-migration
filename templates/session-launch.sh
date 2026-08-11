#!/usr/bin/env bash
# Launch a graphical application in the session's preferred process scope.
set -Eeuo pipefail

uwsm_active() {
    command -v uwsm >/dev/null 2>&1 || return 1
    systemctl --user list-units \
        --type=service \
        --state=active \
        --plain \
        --no-legend \
        'wayland-wm@*.service' 2>/dev/null | grep -q .
}

if [[ "${1:-}" == --desktop ]]; then
    [[ $# -eq 2 ]] || {
        printf 'usage: %s --desktop DESKTOP_ID\n' "$0" >&2
        exit 2
    }
    desktop_id="$2"
    if uwsm_active; then
        exec uwsm app -- "${desktop_id%.desktop}.desktop"
    fi
    exec gtk-launch "${desktop_id%.desktop}"
fi

[[ $# -gt 0 ]] || {
    printf 'usage: %s COMMAND [ARG ...]\n' "$0" >&2
    exit 2
}

if ! command -v -- "$1" >/dev/null 2>&1; then
    printf 'application is not installed: %s\n' "$1" >&2
    if command -v notify-send >/dev/null 2>&1; then
        notify-send 'Application not installed' \
            "${1##*/} was not selected in the migration setup."
    fi
    exit 127
fi

if uwsm_active; then
    exec uwsm app -- "$@"
fi

exec "$@"
