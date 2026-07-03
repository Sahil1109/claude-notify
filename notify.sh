#!/bin/bash
# Claude Code Notification hook -> macOS notification -> click focuses the
# terminal that Claude sent the request from.
#
# Wire-up (in ~/.claude/settings.json):
#   "hooks": { "Notification": [ { "hooks": [
#       { "type": "command", "command": "/path/to/notify.sh" } ] } ] }
#
# The hook must return fast, so this script re-execs itself detached
# (--worker mode) and the detached copy blocks on alerter waiting for a click.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG=/tmp/claude-notify.log
log() { printf '%s [%s] %s\n' "$(date '+%H:%M:%S')" "$1" "$2" >> "$LOG"; }
# Hook environments can have a minimal PATH; fall back to brew locations
# (Apple Silicon, then Intel).
find_bin() {
    command -v "$1" 2>/dev/null && return
    for p in "/opt/homebrew/bin/$1" "/usr/local/bin/$1"; do
        [ -x "$p" ] && { echo "$p"; return; }
    done
    echo "$1"
}
ALERTER="$(find_bin alerter)"
JQ="$(find_bin jq)"

# ---------------------------------------------------------------- worker mode
if [ "${1:-}" = "--worker" ]; then
    msg=$2 cwd=$3 session=$4 bundle=$5 term_program=$6 tty_dev=$7

    subtitle="${cwd##*/}"

    result="$("$ALERTER" \
        --message "$msg" \
        --title "Claude Code" \
        --subtitle "$subtitle" \
        --group "claude-notify-${session:-default}" \
        --sound default \
        --timeout 300 \
        --json 2>/dev/null)"

    activation="$(printf '%s' "$result" | "$JQ" -r '.activationType // empty')"
    log worker "session=$session activation=$activation result=$(printf '%s' "$result" | tr -d '\n ')"

    case "$activation" in
        *[Cc]lick*)
            log worker "invoking focus.sh bundle=$bundle term=$term_program tty=$tty_dev cwd=$cwd"
            exec "$SCRIPT_DIR/focus.sh" "$bundle" "$term_program" "$tty_dev" "$cwd"
            ;;
    esac
    exit 0
fi

# ------------------------------------------------------------------ hook mode
payload="$(cat)"

msg="$(printf '%s' "$payload" | "$JQ" -r '.message // "Claude needs your attention"')"
cwd="$(printf '%s' "$payload" | "$JQ" -r '.cwd // empty')"
session="$(printf '%s' "$payload" | "$JQ" -r '.session_id // empty')"

# Identity of the terminal this claude instance is running in, inherited
# through the environment / process tree.
bundle="${__CFBundleIdentifier:-}"
term_program="${TERM_PROGRAM:-}"
tty_dev="$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')"
[ "$tty_dev" = "??" ] && tty_dev=""

log hook "session=$session cwd=$cwd bundle=$bundle term=$term_program tty=$tty_dev msg=$msg"

nohup "${BASH_SOURCE[0]}" --worker \
    "$msg" "$cwd" "$session" "$bundle" "$term_program" "$tty_dev" \
    >/dev/null 2>&1 &

exit 0
