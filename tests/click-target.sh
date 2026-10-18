#!/usr/bin/env bash
# Runs the hook's macOS path with stub uname, terminal-notifier, osascript and open on PATH and checks
# what a click depends on: the -activate bundle id, the -execute command for VS Code (which must reach
# open intact for a folder name with spaces and a single quote), and the osascript fallback's escaping.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
bin="$work/bin"; mkdir -p "$bin" "$work/home"
dir="$work/demo dir/it's here"; mkdir -p "$dir"

printf '#!/bin/sh\necho Darwin\n' > "$bin/uname"
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\0" "$a"; done > "$CAPTURE.tmp" && mv "$CAPTURE.tmp" "$CAPTURE"\n' > "$bin/terminal-notifier"
cp "$bin/terminal-notifier" "$bin/osascript"
cp "$bin/terminal-notifier" "$bin/open-stub"
chmod +x "$bin"/*

payload() { python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Notification","notification_type":"permission_prompt","message":sys.argv[2],"cwd":sys.argv[1]}))' "$1" "$2"; }

# run <capture file> <env assignments...>: one hook run with the stubs first on PATH; waits for the capture.
run() {
  local cap="$1"; shift
  rm -f "$cap"
  payload "$dir" 'Claude needs your "permission" to run: a\b' | env -i HOME="$work/home" CLAUDE_NOTIFY_CONF=/nonexistent PATH="$bin:/usr/bin:/bin" CAPTURE="$cap" "$@" bash "$here/notify-waiting.sh"
  for _ in $(seq 1 50); do [ -s "$cap" ] && return 0; sleep 0.1; done
  echo "FAIL: no notifier call captured in $cap; the hook's trace follows"
  ls -la "$bin" /opt/homebrew/bin/terminal-notifier /usr/local/bin/terminal-notifier 2>&1 || true
  payload "$dir" 'trace' | env -i HOME="$work/home" CLAUDE_NOTIFY_CONF=/nonexistent PATH="$bin:/usr/bin:/bin" CAPTURE="$cap" "$@" bash -x "$here/notify-waiting.sh" 2>&1 | tail -n 40
  sleep 2; ls -la "$(dirname "$cap")"
  exit 1
}

check() { python3 - "$@" <<'PY'
import sys
cap, case = sys.argv[1], sys.argv[2]
args = open(cap, 'rb').read().split(b'\0')[:-1]
args = [a.decode() for a in args]
def val(flag):
    return args[args.index(flag) + 1] if flag in args else None
def fail(msg):
    print(f'FAIL [{case}]: {msg}; argv={args!r}'); sys.exit(1)
if case == 'vscode':
    if val('-activate') != 'com.microsoft.VSCode': fail('-activate is not the VS Code bundle id')
    if not (val('-execute') or '').startswith('/usr/bin/open -b '): fail('no -execute open command')
    if val('-title') != "Claude Code: it's here": fail('title')
    if val('-group') != "claude-code-it's here": fail('group')
elif case == 'iterm':
    if val('-activate') != 'com.googlecode.iterm2': fail('-activate is not iTerm')
    if '-execute' in args: fail('-execute set for a terminal')
elif case == 'nofocus':
    if val('-activate') != 'com.microsoft.VSCode': fail('-activate is not the VS Code bundle id')
    if '-execute' in args: fail('-execute set with NOTIFY_FOCUS_FOLDER=0')
elif case == 'fallback':
    want = 'display notification "Claude needs your \\"permission\\" to run: a\\\\b" with title "Claude Code: it\'s here" sound name "Glass"'
    if args != ['-e', want]: fail('osascript script differs from ' + repr(want))
print(f'ok [{case}]')
PY
}

# VS Code's saved window state: one window on the session folder's parent, one elsewhere.
state="$work/home/Library/Application Support/Code/User/globalStorage/storage.json"
mkdir -p "$(dirname "$state")"
python3 - "$state" "$work/demo dir" "$work/other" <<'PY'
import json, sys
from urllib.parse import quote
uri = lambda p: "file://" + quote(p)
json.dump({"windowsState": {"lastActiveWindow": {"folder": uri(sys.argv[3])},
           "openedWindows": [{"folder": uri(sys.argv[3])}, {"folder": uri(sys.argv[2])}]}}, open(sys.argv[1], "w"))
PY
run "$work/vscode" __CFBundleIdentifier=com.microsoft.VSCode
check "$work/vscode" vscode
# The -execute command must hand open exactly three arguments, the folder whole.
cmd="$(python3 -c 'import sys; a=open(sys.argv[1],"rb").read().split(b"\0"); print(a[a.index(b"-execute")+1].decode())' "$work/vscode")"
rm -f "$work/open"
CAPTURE="$work/open" sh -c "${cmd/\/usr\/bin\/open/$bin/open-stub}"
python3 - "$work/open" "$dir" <<'PY'
import sys
args = [a.decode() for a in open(sys.argv[1], 'rb').read().split(b'\0')[:-1]]
want = ['-b', 'com.microsoft.VSCode', sys.argv[2].rsplit('/', 1)[0]]  # the window's folder, the session folder's parent
if args != want: print(f'FAIL [execute]: open got {args!r}, want {want!r}'); sys.exit(1)
print('ok [execute]')
PY

# No open window holds the session folder: the click only brings VS Code forward.
rm "$state"
run "$work/nowindow" __CFBundleIdentifier=com.microsoft.VSCode
check "$work/nowindow" nofocus

run "$work/iterm" TERM_PROGRAM=iTerm.app
check "$work/iterm" iterm

run "$work/nofocus" __CFBundleIdentifier=com.microsoft.VSCode NOTIFY_FOCUS_FOLDER=0
check "$work/nofocus" nofocus

rm "$bin/terminal-notifier"
# NOTIFY_TN_DIRS empty: the runner may carry a terminal-notifier of its own in /usr/local/bin.
run "$work/fallback" __CFBundleIdentifier=com.microsoft.VSCode NOTIFY_TN_DIRS=
check "$work/fallback" fallback
echo "all click-target checks passed"
