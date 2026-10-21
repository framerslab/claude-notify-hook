# claude-notify-hook

A desktop notification whenever Claude Code is waiting on you: for a permission, for your next message, for an answer to a tool's question, or because a background agent needs you or has finished.

It is one shell script wired as a Claude Code hook. It runs wherever Claude Code runs with your settings: the terminal, the VS Code extension and the desktop app. macOS uses `terminal-notifier`, which the installer adds with Homebrew; Linux uses `notify-send`; Windows (Git Bash or WSL) shows a PowerShell toast.

## Install

```bash
git clone https://github.com/framerslab/claude-notify-hook.git
bash claude-notify-hook/install.sh
```

The installer copies `notify-waiting.sh` to `~/.claude/hooks/`, installs `terminal-notifier` with Homebrew on macOS when it is missing (set `CLAUDE_NOTIFY_SKIP_BREW=1` to skip that), and merges two hooks into `~/.claude/settings.json`, which applies to every project on the machine:

| Event | Matcher | What it means |
|---|---|---|
| `Notification` | `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_stale`, `quota_auto_resume_disabled` | Claude waits for your permission; finished about 60 seconds ago and you have not typed; a tool asks you something; a background agent needs you or finished; a usage-limit wait needs your Enter or stopped |
| `Stop` | every finished turn | Off by default (see below) |

New sessions pick the hooks up at once. In a session that is already open, run `/hooks` once to reload them. `/hooks` also lets you review, edit or remove them.

## What you see

Title `Claude Code: <project folder>`, body the event's own message (for example `Claude needs your permission to run: git push`) or a short line saying what it waits for.

## What a click does on macOS

With `terminal-notifier`, a click brings the app the session runs in to the front: VS Code, the Claude desktop app, Terminal, iTerm, Ghostty or Warp. The hook checks VS Code first: its integrated terminal sets `TERM_PROGRAM=vscode`, and the extension sets no `TERM_PROGRAM` of its own but has `VSCODE_PID`. VS Code started with the `code` command from Terminal or iTerm passes that terminal's environment to the extension, `TERM_PROGRAM` included, so `VSCODE_PID` outranks the other terminals' names. Next, `TERM_PROGRAM` names the terminal a CLI session runs in. Last comes `__CFBundleIdentifier`, which macOS sets for every process an app starts and which covers the desktop app; it comes last because a process started from a terminal inherits it. For VS Code it also finds the open window that holds the session's folder, or its nearest parent folder, in VS Code's saved window state (`windowsState` in `~/Library/Application Support/Code/User/globalStorage/storage.json`) and asks VS Code to open that window's folder. VS Code answers by focusing the window that already holds it, so with several windows open the click lands on this session's one. When no window matches, a multi-root workspace for one, the click brings VS Code forward without choosing a window. VS Code gives an outside process no way to name a window, so when two windows hold the same folder, VS Code chooses which of them comes forward.

Without `terminal-notifier` the notification still shows, through the built-in `osascript`. macOS files those notifications under Script Editor, so a click opens Script Editor and its file dialog. Install `terminal-notifier` (`brew install terminal-notifier`, or run the installer again) to fix that.

macOS asks once whether `terminal-notifier` may show notifications. When that permission is off (the answer was Don't Allow, or notifications for it were switched off later), `terminal-notifier` exits 3 and shows nothing, so the hook shows the `osascript` notification instead with the fix in its body: a click on that one opens Script Editor, which is how the problem looks from the outside. The fix is the switch in System Settings > Notifications > terminal-notifier (Allow Notifications); `terminal-notifier -diagnose` prints `authorization denied` while it is off, and `tccutil reset UserNotification fr.julienxx.oss.terminal-notifier`, which should make macOS ask again, can fail on recent macOS, so the switch is the dependable way. Once it is on, clicks land on the session's app again with no restart.

## Settings

Optional file `~/.claude/notify-waiting.conf`, shell syntax:

```bash
NOTIFY_ON_STOP=1                 # also notify the moment a turn ends (default off)
NOTIFY_SOUND=Glass               # macOS sound name; empty for silent
NOTIFY_QUIET_TYPES="auth_success quota_auto_resume_fired"   # notification types to skip
NOTIFY_ACTIVATE=com.microsoft.VSCode   # app a click brings to the front (default: the app the session runs in)
NOTIFY_FOCUS_FOLDER=0            # VS Code: bring it forward without focusing the session's window (default 1)
NOTIFY_TN_DIRS="/opt/homebrew/bin:/usr/local/bin"   # where to find terminal-notifier off the hook's PATH, colon-separated
```

`NOTIFY_ON_STOP` is off by default because `idle_prompt` already fires 60 seconds after a turn ends if you have not typed, and with several sessions running at once a notification on every finished turn is noise. Turn it on when you run one session and want to know the moment it finishes.

## Per-repository settings

The user-level install covers every repository for the person who ran it. A repository can also carry the hook in its own `.claude/settings.json`, so collaborators who cloned it get the notification once they have run the installer. The command is a no-op for anyone who has not:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|agent_completed|quota_auto_resume_stale|quota_auto_resume_disabled",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c '[ -x \"$HOME/.claude/hooks/notify-waiting.sh\" ] && \"$HOME/.claude/hooks/notify-waiting.sh\" || true'",
            "async": true,
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

The same snippet is in `project-settings.snippet.json`.

## How it reads the event

Claude Code sends the hook JSON on stdin. The script reads `hook_event_name`, `notification_type`, `message` and `cwd` (the project folder) with `python3`, falling back to `jq`, then to a plain-text match. Its exit code and output are ignored by Claude Code for these events, and it exits 0 whatever happens.

## Uninstall

Remove the two hook entries with `/hooks` in Claude Code (or from `~/.claude/settings.json`) and delete `~/.claude/hooks/notify-waiting.sh`.
