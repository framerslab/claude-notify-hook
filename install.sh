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

cat <<EOF

Done. New Claude Code sessions pick the hook up at once; in a session that is already open, run /hooks once to reload.
A notification shows when Claude waits for your permission, has waited 60 seconds for your next message,
a tool asks you a question, or a background agent needs you or finishes.
Optional settings: $claude_dir/notify-waiting.conf (see README.md), for example NOTIFY_ON_STOP=1 to notify on every finished turn.
EOF
