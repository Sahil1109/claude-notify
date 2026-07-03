#!/bin/bash
# claude-notify installer
#
# Sets up macOS notifications for Claude Code permission requests, with
# click-to-focus back to the exact terminal that asked.
#
#   ./install.sh              install (or update)
#   ./install.sh --uninstall  remove hook + installed files
#
# What it does:
#   1. Installs dependencies (alerter, jq) via Homebrew if missing.
#   2. Copies scripts to ~/.claude/claude-notify/ and compiles the ax-focus
#      Swift helper there.
#   3. Adds a Notification hook to ~/.claude/settings.json (backs it up first,
#      idempotent — safe to re-run).
#   4. Sends a test notification.

set -euo pipefail

INSTALL_DIR="$HOME/.claude/claude-notify"
SETTINGS="$HOME/.claude/settings.json"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "macOS only."

# ---------------------------------------------------------------- uninstall
if [ "${1:-}" = "--uninstall" ]; then
    bold "Uninstalling claude-notify"
    if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
        cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
        tmp="$(mktemp)"
        jq '
            if .hooks.Notification then
                .hooks.Notification |= map(
                    select((.hooks // []) | any(.command? // "" | contains("claude-notify")) | not)
                )
                | if (.hooks.Notification | length) == 0 then del(.hooks.Notification) else . end
            else . end
        ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
        ok "hook removed from settings.json (backup created)"
    fi
    rm -rf "$INSTALL_DIR"
    ok "removed $INSTALL_DIR"
    echo "Done. Restart Claude Code sessions to apply."
    exit 0
fi

bold "Installing claude-notify"

# ------------------------------------------------------------- dependencies
if ! command -v brew >/dev/null; then
    fail "Homebrew required (https://brew.sh). Install it, then re-run."
fi
for dep in alerter jq; do
    if command -v "$dep" >/dev/null || [ -x "/opt/homebrew/bin/$dep" ] || [ -x "/usr/local/bin/$dep" ]; then
        ok "$dep present"
    else
        echo "  installing $dep via brew..."
        brew install "$dep" >/dev/null
        ok "$dep installed"
    fi
done

if ! xcode-select -p >/dev/null 2>&1; then
    fail "Xcode Command Line Tools required for the Swift helper. Run: xcode-select --install, then re-run this script."
fi
ok "swift toolchain present"

# ------------------------------------------------------------------- files
mkdir -p "$INSTALL_DIR"
cp "$SRC_DIR/notify.sh" "$SRC_DIR/focus.sh" "$SRC_DIR/ax-focus.swift" "$INSTALL_DIR/"
[ -f "$SRC_DIR/README.md" ]       && cp "$SRC_DIR/README.md" "$INSTALL_DIR/"
[ -f "$SRC_DIR/HOW-IT-WORKS.md" ] && cp "$SRC_DIR/HOW-IT-WORKS.md" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/notify.sh" "$INSTALL_DIR/focus.sh"
ok "files copied to $INSTALL_DIR"

echo "  compiling ax-focus..."
swiftc -O "$INSTALL_DIR/ax-focus.swift" -o "$INSTALL_DIR/ax-focus"
ok "ax-focus compiled"

# ------------------------------------------------------------ settings.json
JQ="$(command -v jq || echo /opt/homebrew/bin/jq)"
HOOK_CMD="bash \"$INSTALL_DIR/notify.sh\""

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
"$JQ" -e . "$SETTINGS" >/dev/null || fail "$SETTINGS is not valid JSON — fix it first."

cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
tmp="$(mktemp)"
"$JQ" --arg cmd "$HOOK_CMD" '
    .hooks //= {} | .hooks.Notification //= []
    # drop any previous claude-notify entries (idempotent re-install)
    | .hooks.Notification |= map(
        select((.hooks // []) | any(.command? // "" | test("notify\\.sh")) | not)
    )
    | .hooks.Notification += [{
        "matcher": "",
        "hooks": [{"type": "command", "command": $cmd, "timeout": 10}]
    }]
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
ok "Notification hook added to $SETTINGS (backup created)"

# -------------------------------------------------------------------- test
echo '{"session_id":"install-test","cwd":"'"$PWD"'","message":"claude-notify installed — click me to test focus"}' \
    | bash "$INSTALL_DIR/notify.sh"
ok "test notification sent"

echo
bold "Done. Two things to know:"
cat <<'EOF'
  1. macOS may ask you to allow notifications (for alerter/Terminal) and
     Accessibility control (System Settings → Privacy & Security →
     Accessibility) the first time a notification is clicked. Grant both,
     or click-to-focus silently does nothing.
  2. Already-running Claude Code sessions don't have the hook yet — restart
     them or run /hooks once in each.

  Uninstall any time:  ./install.sh --uninstall
  Debug log:           /tmp/claude-notify.log
EOF
