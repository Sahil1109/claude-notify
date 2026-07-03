# How claude-notify works

When Claude Code asks for permission, a macOS notification appears. Clicking it
jumps to the **exact VS Code window and terminal tab** the request came from —
even with multiple windows open on the same folder, and multiple terminals per
window.

macOS has no API for "focus VS Code window X, terminal Y", and VS Code exposes
no CLI or AppleScript for it either. This document explains the trick chain
that makes it work anyway.

## The pipeline

```
Claude needs permission
        │
        ▼
Notification hook ──▶ notify.sh (hook mode)      captures identity, exits fast
        │
        ▼
notify.sh --worker (detached)                    alerter waits for click
        │  click
        ▼
focus.sh ──▶ TTY marker + ax-focus               finds & focuses exact tab
```

## Step 1 — Hook fires, identity captured

Claude Code's `Notification` hook (configured in `~/.claude/settings.json`)
runs `notify.sh` and pipes JSON on stdin: `message`, `cwd`, `session_id`.

The script also captures two things only available at that moment, inherited
through the process environment:

- **Which terminal app** — `TERM_PROGRAM` (`vscode`) and `__CFBundleIdentifier`
  (`com.microsoft.VSCode`, or Cursor/Windsurf bundle ids).
- **Which terminal tab** — the controlling TTY of the claude process:
  `ps -o tty= -p $PPID` → e.g. `ttys012`.

The TTY is the magic key. Every terminal tab on macOS owns a unique
pseudo-terminal device (`/dev/ttys012`). It identifies the exact tab, for
free, for the tab's whole lifetime.

## Step 2 — Detach and wait for the click

Hooks must return quickly, so `notify.sh` re-executes itself with
`nohup ... &` (`--worker` mode) and exits immediately. The detached worker
runs [`alerter`](https://github.com/vjeantet/alerter), which posts the
notification and **blocks** until the user interacts (up to 5 minutes),
then prints JSON. A click yields `"activationType": "contentsClicked"`,
which triggers `focus.sh`.

## Step 3 — Find the tab: the TTY marker trick

Problem: given `ttys012`, which VS Code window/tab is it? The process tree
does not tell you — all integrated-terminal shells are children of one shared
`ptyHost` process, regardless of window. Modern VS Code also dropped
`VSCODE_IPC_HOOK_CLI`, so there is no per-window `code` CLI targeting, and
`open -b com.microsoft.VSCode <folder>` only targets the *app*, picking an
arbitrary window when several have the same folder open.

The trick, in `focus.sh`:

1. Write an escape sequence **directly into the TTY device**:

   ```sh
   printf '\033]0;CCN-<pid>-ttys012\007' > /dev/ttys012
   ```

   Anything written to a TTY appears as terminal output, and terminals
   interpret `OSC 0` as "set my title". The target tab — wherever it is —
   silently renames itself to a unique marker string.

2. Run `ax-focus` (a small compiled Swift binary) which walks the
   **accessibility tree** — the same UI-element graph VoiceOver uses — of
   every VS Code window, hunting for any element whose title/value contains
   the marker.

   Electron quirk: the AX tree is lazily exposed and appears *empty* until
   you set `AXManualAccessibility = true` on the app element. (AppleScript's
   `entire contents` returns 0 elements regardless — useless here; the raw
   `AXUIElement` C API from Swift is fast and works.)

3. The write→render round-trip is asynchronous and Claude itself sometimes
   rewrites the tab title, so the marker is rewritten and re-searched up to
   3 times (0.4s / 0.7s / 1.2s).

## Step 4 — Focus window *and* tab

When the marker element is found:

- `AXRaise` on its window → correct window comes forward.
- `AXPress` on the matched element (climbing to the nearest pressable
  ancestor — the tab row — if the text element itself isn't pressable) →
  simulates a click on that terminal tab, so the *right terminal* is
  selected, not whichever tab was last active in that window.

Then the marker is erased (`printf '\033]0;\007' > /dev/ttysN`) and the tab
title returns to normal.

In short: **the notification smuggles a unique name onto the exact terminal
tab through its TTY device, then a fake screen reader finds and clicks that
name.** No VS Code cooperation required.

## Fallback chain

`focus.sh` tries, in order:

1. **TTY marker + ax-focus** — exact window and tab. Needs the terminal
   panel visible in the target window (hidden panels have no AX elements).
2. **Title match** — AppleScript raises the window whose title ends with
   cwd's basename. Ambiguous when two windows share a folder name.
3. **`open -b <bundle>`** — just activates the app. Deliberately does NOT
   open the folder: that spawns a new window when nothing matches.

Terminal.app and iTerm2 don't need any of this: both expose tabs' `tty`
directly to AppleScript, so `focus.sh` matches the TTY exactly.

## Files

| File | Role |
|------|------|
| `notify.sh` | Hook entry + detached alerter worker |
| `focus.sh` | Click handler, fallback chain |
| `ax-focus.swift` | AX search + raise + tab press (`swiftc -O ax-focus.swift -o ax-focus`) |
| `/tmp/claude-notify.log` | Debug log: hook fires, clicks, which strategy matched |

## Known limits

- Terminal panel hidden in the target window → marker invisible to AX →
  falls back to title match (log shows `ax=no-match`).
- The `Notification` hook also fires when Claude idles 60s waiting for
  input, not only on permission requests.
- Click window is 5 minutes; after that alerter times out and the
  notification click does nothing.
