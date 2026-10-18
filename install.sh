#!/usr/bin/env bash
# Installs the Claude Code "waiting on you" desktop notification hook for the current user:
#   1. copies notify-waiting.sh to ~/.claude/hooks/
#   2. merges a Notification hook and a Stop hook into ~/.claude/settings.json (user scope, every project)
# Idempotent: running it again changes nothing that is already in place.
# Needs bash and python3 (for the JSON merge). Works on macOS, Linux and Windows under Git Bash or WSL.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
hooks_dir="$claude_dir/hooks"
settings="$claude_dir/settings.json"
target="$hooks_dir/notify-waiting.sh"
cmd="bash $target"
matcher='permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|agent_completed|quota_auto_resume_stale|quota_auto_resume_disabled'

mkdir -p "$hooks_dir"
cp "$here/notify-waiting.sh" "$target"
chmod +x "$target"
echo "installed $target"

fi

if ! command -v python3 >/dev/null 2>&1; then
  cat <<EOF
python3 was not found, so the settings were not merged. Add this to $settings by hand (inside "hooks"):
  "Notification": [{"matcher": "$matcher", "hooks": [{"type": "command", "command": "$cmd", "async": true, "timeout": 10}]}],
  "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "$cmd", "async": true, "timeout": 10}]}]
EOF
  exit 0
fi

CMD="$cmd" MATCH="$matcher" SETTINGS="$settings" python3 - <<'EOF'
import json, os, tempfile
p = os.environ["SETTINGS"]; cmd = os.environ["CMD"]; match = os.environ["MATCH"]
d = {}
if os.path.exists(p):
    with open(p) as f:
        raw = f.read().strip()
    d = json.loads(raw) if raw else {}
hooks = d.setdefault("hooks", {})
def present(ev):
    return any(cmd == (h.get("command") or "") for e in hooks.get(ev, []) for h in e.get("hooks", []))
changed = False
if not present("Notification"):
    hooks.setdefault("Notification", []).append({"matcher": match, "hooks": [{"type": "command", "command": cmd, "async": True, "timeout": 10}]})
    changed = True
if not present("Stop"):
    stop = hooks.setdefault("Stop", [])
    tgt = next((e for e in stop if (e.get("matcher") or "") == ""), None)
    if tgt is None:
        tgt = {"matcher": "", "hooks": []}; stop.append(tgt)
    tgt["hooks"].append({"type": "command", "command": cmd, "async": True, "timeout": 10})
    changed = True
if changed:
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = tempfile.NamedTemporaryFile("w", dir=os.path.dirname(p), delete=False, suffix=".tmp")
    json.dump(d, tmp, indent=2); tmp.write("\n"); tmp.close()
    os.chmod(tmp.name, 0o600); os.replace(tmp.name, p)
    print("merged the Notification and Stop hooks into", p)
else:
    print("hooks already present in", p)
EOF

# On macOS a click on a notification needs terminal-notifier. Without it the hook falls back to
# osascript, whose notifications macOS files under Script Editor, so a click opens Script Editor.
# This runs after the settings merge, so an installer that stops early changes nothing in Homebrew.
# CLAUDE_NOTIFY_SKIP_BREW=1 skips it.
first_executable() { local c; for c in "$@"; do [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done; return 1; }
find_tn() { first_executable "$(command -v terminal-notifier 2>/dev/null || true)" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier; }
tn=""; tn_failed=0
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && [ "${CLAUDE_NOTIFY_SKIP_BREW:-0}" != "1" ]; then
  if tn="$(find_tn)"; then
    echo "terminal-notifier found at $tn"
  elif brew="$(first_executable "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew)"; then
    echo "installing terminal-notifier with Homebrew ($brew install terminal-notifier), so a click on a notification brings your editor or terminal to the front"
    if "$brew" install terminal-notifier; then
      tn="$(find_tn || first_executable "$("$brew" --prefix 2>/dev/null)/bin/terminal-notifier" || true)"
    else
      tn_failed=1
      echo "brew install terminal-notifier failed: notifications still show, but a click opens Script Editor until it is installed"
    fi
  else
    echo "terminal-notifier is not installed and Homebrew was not found: notifications still show, but macOS files them under Script Editor, so a click opens Script Editor. Install terminal-notifier (brew install terminal-notifier) for clicks that bring your editor or terminal to the front."
  fi
  # The hook looks on its own PATH and in Homebrew's two bin folders; a notifier anywhere else is
  # written into the settings file so the hook finds it.
  if [ -n "$tn" ]; then
    tn_dir="$(dirname "$tn")"
    case " /opt/homebrew/bin /usr/local/bin " in
      *" $tn_dir "*) ;;
      *) conf="$claude_dir/notify-waiting.conf"
         if ! grep -q '^NOTIFY_TN_DIRS=' "$conf" 2>/dev/null; then
           printf 'NOTIFY_TN_DIRS="%s /opt/homebrew/bin /usr/local/bin"\n' "$tn_dir" >> "$conf"
           echo "terminal-notifier is in $tn_dir, outside the hook's default folders: added NOTIFY_TN_DIRS to $conf"
         fi ;;
    esac
  fi
fi

cat <<EOF

Done. New Claude Code sessions pick the hook up at once; in a session that is already open, run /hooks once to reload.
A notification shows when Claude waits for your permission, has waited 60 seconds for your next message,
a tool asks you a question, or a background agent needs you or finishes.
Optional settings: $claude_dir/notify-waiting.conf (see README.md), for example NOTIFY_ON_STOP=1 to notify on every finished turn.
EOF
if [ -n "$tn" ]; then
  echo "On macOS the first notification asks whether terminal-notifier may show notifications: Allow it. If none appear, run terminal-notifier -diagnose."
fi
if [ "$tn_failed" = "1" ]; then
  exit 1
fi
