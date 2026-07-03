#!/bin/bash
# Focus the terminal a Claude Code notification came from.
# Usage: focus.sh <bundle_id> <term_program> <tty> <cwd>

set -u

bundle="${1:-}"
term_program="${2:-}"
tty_dev="${3:-}"
cwd="${4:-}"

LOG=/tmp/claude-notify.log
log() { printf '%s [focus] %s\n' "$(date '+%H:%M:%S')" "$1" >> "$LOG"; }
log "bundle=$bundle term=$term_program tty=$tty_dev cwd=$cwd"

case "$term_program" in
    vscode)
        # VS Code / Cursor / Windsurf all report TERM_PROGRAM=vscode but have
        # distinct bundle ids and process names. Window titles end with the
        # workspace folder name, so raise the window matching cwd's basename.
        target_bundle="${bundle:-com.microsoft.VSCode}"
        case "$target_bundle" in
            com.microsoft.VSCodeInsiders) proc="Code - Insiders" ;;
            com.todesktop.230313mzl4w4u92) proc="Cursor" ;;
            com.exafunction.windsurf)      proc="Windsurf" ;;
            *)                             proc="Code" ;;
        esac
        folder="${cwd##*/}"

        # Strategy 1: TTY marker. The tty uniquely identifies the terminal, so
        # set its tab title to a marker and AX-search windows for it. This is
        # the only method that works when several windows have the same folder.
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -n "$tty_dev" ] && [ -w "/dev/$tty_dev" ] && [ -x "$SCRIPT_DIR/ax-focus" ]; then
            marker="CCN-$$-${tty_dev}"
            axresult="no-match"
            # Claude/the shell may overwrite the tab title, and VS Code renders
            # it async — rewrite the marker and retry a few times.
            for delay in 0.4 0.7 1.2; do
                printf '\033]0;%s\007' "$marker" > "/dev/$tty_dev"
                sleep "$delay"
                axresult="$("$SCRIPT_DIR/ax-focus" "$target_bundle" "$marker" 2>/dev/null)"
                case "$axresult" in matched*) break ;; esac
            done
            printf '\033]0;\007' > "/dev/$tty_dev"   # reset tab title
            log "tty-marker=$marker ax=$axresult"
            case "$axresult" in matched*) exit 0 ;; esac
        fi

        # Strategy 2: window title ends with the folder name.
        matched="$(osascript - "$proc" "$folder" <<'EOS'
on run argv
    set procName to item 1 of argv
    set folderName to item 2 of argv
    tell application "System Events"
        tell process procName
            -- exact match: window showing only the folder, or "file - folder"
            repeat with w in windows
                set t to title of w
                if t is folderName or t ends with ("— " & folderName) then
                    perform action "AXRaise" of w
                    set frontmost to true
                    return "matched"
                end if
            end repeat
            -- lenient fallback: folder name anywhere in the title
            repeat with w in windows
                if title of w contains folderName then
                    perform action "AXRaise" of w
                    set frontmost to true
                    return "matched"
                end if
            end repeat
        end tell
    end tell
    return "no-match"
end run
EOS
)"

        log "proc=$proc folder=$folder title-match=$matched"
        if [ "$matched" != "matched" ]; then
            # No window has that folder: open it (new window) / activate app.
            if [ -n "$cwd" ]; then
                open -b "$target_bundle" "$cwd"
            else
                open -b "$target_bundle"
            fi
        fi
        ;;

    Apple_Terminal)
        osascript - "/dev/$tty_dev" <<'EOS'
on run argv
    set targetTty to item 1 of argv
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is targetTty then
                    set selected tab of w to t
                    set index of w to 1
                    activate
                    return
                end if
            end repeat
        end repeat
        activate
    end tell
end run
EOS
        ;;

    iTerm.app)
        osascript - "/dev/$tty_dev" <<'EOS'
on run argv
    set targetTty to item 1 of argv
    tell application "iTerm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if tty of s is targetTty then
                        select w
                        select t
                        select s
                        activate
                        return
                    end if
                end repeat
            end repeat
        end repeat
        activate
    end tell
end run
EOS
        ;;

    *)
        # Ghostty, Alacritty, kitty, ... - no per-tab scripting, activate app.
        if [ -n "$bundle" ]; then
            open -b "$bundle"
        fi
        ;;
esac
