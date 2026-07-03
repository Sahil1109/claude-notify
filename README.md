# claude-notify (notifier)

macOS notification when Claude Code asks for permission (or sits idle waiting
for input). Clicking the notification jumps back to the terminal that Claude
sent the request from.

## How it works

1. Claude Code fires its `Notification` hook and pipes JSON
   (`message`, `cwd`, `session_id`) into `notify.sh`.
2. `notify.sh` captures the terminal's identity from the environment
   (`__CFBundleIdentifier`, `TERM_PROGRAM`, controlling TTY), then re-execs
   itself detached (`--worker`) so the hook returns instantly.
3. The worker calls [`alerter`](https://github.com/vjeantet/alerter) with
   `--json` and blocks up to 5 minutes waiting for interaction.
4. On click (`activationType` contains "click"), `focus.sh` brings the right
   terminal forward:
   - **VS Code / Cursor / Windsurf** (`TERM_PROGRAM=vscode`), tried in order:
     1. *TTY marker*: writes an escape sequence to `/dev/ttysN` setting that
        terminal's tab title to a unique marker, then `ax-focus` (compiled
        Swift helper, `swiftc -O ax-focus.swift -o ax-focus`) searches each
        window's accessibility tree for the marker and raises the exact
        window. Works even when several windows have the same folder open.
        Needs the terminal panel visible in that window; retries 3×.
     2. *Title match*: AppleScript raises the window whose title ends with
        cwd's basename.
     3. *Fallback*: activate the app (`open -b <bundle>`).
   - **Terminal.app / iTerm2**: AppleScript walks windows/tabs and selects the
     one whose TTY matches.
   - **Anything else** (Ghostty, kitty, ...): activates the app.

Debug log: `/tmp/claude-notify.log` (hook fires, click activations, which
focus strategy matched).

## Install

```sh
git clone https://github.com/Sahil1109/claude-notify.git
cd claude-notify
./install.sh
```

Installs dependencies (`alerter`, `jq` via Homebrew), copies everything to
`~/.claude/claude-notify/`, compiles the Swift helper, adds the Notification
hook to `~/.claude/settings.json` (backed up, idempotent), and sends a test
notification. Requires Xcode Command Line Tools (`xcode-select --install`).

After install: restart running Claude Code sessions (or run `/hooks` in
them), and grant notification + Accessibility permissions if macOS asks.

Uninstall: `./install.sh --uninstall`

Full explanation of the trick chain: [HOW-IT-WORKS.md](HOW-IT-WORKS.md)

## Test manually

```sh
echo '{"session_id":"t1","cwd":"'$PWD'","message":"Claude needs your permission to use Bash"}' \
  | ./notify.sh
```
