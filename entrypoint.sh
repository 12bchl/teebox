#!/bin/sh
set -e

seed=0 new=0 agent_run="" session_found="" session_resume="" session_new=""
while [ $# -gt 0 ]; do
    case "$1" in
        --seed)    seed=1; shift ;;
        --new)     new=1; shift ;;
        --alias)   agent_run="$2"; shift 2 ;;
        --session) session_found="$2" session_resume="$3" session_new="$4"; shift 4 ;;
        --)        shift; break ;;
        *)         break ;;
    esac
done

# only when the top is wrong: an unconditional chown -R walks a multi-GB cache every start
if [ "$(stat -c '%u' "$HOME" 2>/dev/null || echo 0)" != "$(id -u)" ]; then
    sudo -n chown -R "$(id -u):$(id -g)" "$HOME" 2>/dev/null || true
fi

apply_home() {
    [ -d "$1" ] || return 0
    cp -R --preserve=mode,timestamps "$1/." "$HOME/" \
        || echo "teebox: WARNING could not apply overlay $1" >&2
}

if [ "$seed" = 1 ] || [ ! -e "$HOME/.teebox-seeded" ]; then
    [ ! -d /host-home ] || echo "teebox: seeding home from host overlay" >&2
    apply_home /host-home
    : > "$HOME/.teebox-seeded"
fi
apply_home "$PWD/.teebox/home"

if [ -n "$agent_run" ]; then
    alias_line="alias ${agent_run%% *}='$agent_run'"
    grep -qxF "$alias_line" "$HOME/.bashrc" 2>/dev/null || echo "$alias_line" >> "$HOME/.bashrc"
fi

if [ "${TEEBOX_AGENT:-}" = claude ] \
   && [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ] \
   && [ ! -e "$HOME/.claude/.credentials.json" ]; then
    echo "teebox: WARNING no auth detected (export CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY)" >&2
fi

# args one per line; glob $HOME-relative
if [ -n "$session_new" ]; then
    if [ "$new" = 1 ] && [ -n "$session_found" ]; then
        # shellcheck disable=SC2086
        for f in "$HOME"/$session_found; do
            [ ! -e "$f" ] || { rm -rf -- "$f"; echo "teebox: deleted session ${f#"$HOME"/}" >&2; }
        done
    fi
    # shellcheck disable=SC2086
    if [ -n "$session_found" ] && ls -d "$HOME"/$session_found >/dev/null 2>&1; then
        session_new="$session_resume"
    fi
    oIFS="$IFS"; IFS='
'
    for a in $session_new; do set -- "$@" "$a"; done
    IFS="$oIFS"
fi

# last: its exports must reach the agent
if [ -f "$PWD/.teebox/init.sh" ]; then
    # shellcheck disable=SC1091
    . "$PWD/.teebox/init.sh"
fi

exec "$@"
