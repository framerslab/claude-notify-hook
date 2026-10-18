# claude-notify-hook

A desktop notification whenever Claude Code is waiting on you: for a permission, for your next message, for an answer to a tool's question, or because a background agent needs you or has finished.

It is one shell script wired as a Claude Code hook. It runs wherever Claude Code runs with your settings: the terminal, the VS Code extension and the desktop app. No dependencies: macOS uses `terminal-notifier` when installed (a click brings the editor or terminal forward), otherwise the built-in `osascript`; Linux uses `notify-send`; Windows (Git Bash or WSL) shows a PowerShell toast.

## Install

```bash
git clone https://github.com/framerslab/claude-notify-hook.git
bash claude-notify-hook/install.sh
```

The installer copies `notify-waiting.sh` to `~/.claude/hooks/` and merges two hooks into `~/.claude/settings.json`, which applies to every project on the machine:

| Event | Matcher | What it means |
|---|---|---|
| `Notification` | `permission_prompt`, `idle_prompt`, `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_stale`, `quota_auto_resume_disabled` | Claude waits for your permission; finished about 60 seconds ago and you have not typed; a tool asks you something; a background agent needs you or finished; a usage-limit wait needs your Enter or stopped |
| `Stop` | every finished turn | Off by default (see below) |

New sessions pick the hooks up at once. In a session that is already open, run `/hooks` once to reload them. `/hooks` also lets you review, edit or remove them.

## What you see

Title `Claude Code: <project folder>`, body the event's own message (for example `Claude needs your permission to run: git push`) or a short line saying what it waits for.

## Settings

Optional file `~/.claude/notify-waiting.conf`, shell syntax:

```bash
NOTIFY_ON_STOP=1                 # also notify the moment a turn ends (default off)
NOTIFY_SOUND=Glass               # macOS sound name; empty for silent
NOTIFY_QUIET_TYPES="auth_success quota_auto_resume_fired"   # notification types to skip
NOTIFY_ACTIVATE=com.microsoft.VSCode   # app terminal-notifier brings forward on click
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
