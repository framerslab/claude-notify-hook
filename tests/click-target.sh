#!/usr/bin/env bash
# Runs the hook's macOS path with stub uname, terminal-notifier, osascript and open on PATH and checks
# what a click depends on: the app it brings forward (-activate) for each way a session can run, the
# -execute command for VS Code (which must reach open intact for a window folder with a space and a
# single quote, and keep a symlinked window folder as VS Code holds it), one notification group per
# session, and the osascript fallback's escaping.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
bin="$work/bin"; mkdir -p "$bin" "$work/home"
win="$work/it's dir"          # the folder a VS Code window holds
dir="$win/sub here"           # the session runs in a folder below it
mkdir -p "$dir" "$work/other"

printf '#!/bin/sh\necho Darwin\n' > "$bin/uname"
printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\0" "$a"; done > "$CAPTURE.tmp" && mv "$CAPTURE.tmp" "$CAPTURE"\n' > "$bin/terminal-notifier"
cp "$bin/terminal-notifier" "$bin/osascript"
cp "$bin/terminal-notifier" "$bin/open-stub"
chmod +x "$bin"/*

payload() { python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"Notification","notification_type":"permission_prompt","message":sys.argv[2],"cwd":sys.argv[1],"session_id":"s-1"}))' "$1" "$2"; }

# VS Code's saved window state: one window per folder given.
state="$work/home/Library/Application Support/Code/User/globalStorage/storage.json"
windows() {
  mkdir -p "$(dirname "$state")"
  python3 - "$state" "$@" <<'PY'
import json, sys
from urllib.parse import quote
uri = lambda p: "file://" + quote(p)
wins = [{"folder": uri(p)} for p in sys.argv[2:]]
json.dump({"windowsState": {"lastActiveWindow": wins[0], "openedWindows": wins}}, open(sys.argv[1], "w"))
PY
}

# run <capture file> <env assignments...>: one hook run with the stubs first on PATH; waits for the capture.
run() {
  local cap="$1"; shift
  rm -f "$cap"
  payload "$dir" 'Claude needs your "permission" to run: a\b' | env -i HOME="$work/home" CLAUDE_NOTIFY_CONF=/nonexistent PATH="$bin:/usr/bin:/bin" CAPTURE="$cap" "$@" bash "$here/notify-waiting.sh"
  for _ in $(seq 1 50); do [ -s "$cap" ] && return 0; sleep 0.1; done
  echo "FAIL: no notifier call captured in $cap; the hook's trace follows"
  payload "$dir" 'trace' | env -i HOME="$work/home" CLAUDE_NOTIFY_CONF=/nonexistent PATH="$bin:/usr/bin:/bin" CAPTURE="$cap" "$@" bash -x "$here/notify-waiting.sh" 2>&1 | tail -n 40
  exit 1
}

# check <capture> <case> [<expected -activate>]
check() { python3 - "$@" <<'PY'
import sys
cap, case = sys.argv[1], sys.argv[2]
want_app = sys.argv[3] if len(sys.argv) > 3 else None
args = [a.decode() for a in open(cap, 'rb').read().split(b'\0')[:-1]]
def val(flag):
    return args[args.index(flag) + 1] if flag in args else None
def fail(msg):
    print(f'FAIL [{case}]: {msg}; argv={args!r}'); sys.exit(1)
if case == 'fallback':
    want = 'display notification "Claude needs your \\"permission\\" to run: a\\\\b" with title "Claude Code: sub here" sound name "Glass"'
    if args != ['-e', want]: fail('osascript script differs from ' + repr(want))
else:
    if val('-activate') != want_app: fail(f'-activate is not {want_app}')
    if val('-title') != 'Claude Code: sub here': fail('title')
    if val('-group') != 'claude-code-s-1': fail('group is not per session')
    has_exec = (val('-execute') or '').startswith('/usr/bin/open -b ')
    if case == 'focus' and not has_exec: fail('no -execute open command')
    if case == 'nofocus' and '-execute' in args: fail('-execute set where no window should be focused')
print(f'ok [{case}]')
PY
}

# opened <capture> <expected folder>: run the -execute command against a stub open and check its arguments.
opened() { python3 - "$1" "$2" "$bin/open-stub" "$work/open" <<'PY'
import os, subprocess, sys
cap, want_folder, stub, out = sys.argv[1:5]
a = open(cap, 'rb').read().split(b'\0')
cmd = a[a.index(b'-execute') + 1].decode().replace('/usr/bin/open', stub, 1)
if os.path.exists(out): os.remove(out)
subprocess.run(['sh', '-c', cmd], env={'CAPTURE': out, 'PATH': '/usr/bin:/bin'}, check=True)
got = [x.decode() for x in open(out, 'rb').read().split(b'\0')[:-1]]
want = ['-b', 'com.microsoft.VSCode', want_folder]
if got != want: print(f'FAIL [execute]: open got {got!r}, want {want!r}'); sys.exit(1)
print(f'ok [execute {want_folder!r}]')
PY
}

windows "$work/other" "$win"

# The VS Code extension: VSCODE_PID set, no TERM_PROGRAM; the window holding the session's parent folder.
run "$work/ext" VSCODE_PID=123 __CFBundleIdentifier=com.microsoft.VSCode
check "$work/ext" focus com.microsoft.VSCode
opened "$work/ext" "$win"

# VS Code started from Terminal with the code command inherits Terminal's bundle id and its TERM_PROGRAM;
# VS Code still wins.
run "$work/ext-inherited" VSCODE_PID=123 __CFBundleIdentifier=com.apple.Terminal
check "$work/ext-inherited" focus com.microsoft.VSCode
run "$work/ext-inherited-term" VSCODE_PID=123 TERM_PROGRAM=Apple_Terminal __CFBundleIdentifier=com.apple.Terminal
check "$work/ext-inherited-term" focus com.microsoft.VSCode
run "$work/integrated" TERM_PROGRAM=vscode __CFBundleIdentifier=com.apple.Terminal
check "$work/integrated" focus com.microsoft.VSCode

# A symlinked window folder: matched by its real path, opened by the path the window holds.
ln -s "$win" "$work/link"
windows "$work/other" "$work/link"
run "$work/symlink" VSCODE_PID=123 __CFBundleIdentifier=com.microsoft.VSCode
check "$work/symlink" focus com.microsoft.VSCode
opened "$work/symlink" "$work/link"

# Focusing switched off: a matching window exists, and still no -execute.
windows "$work/other" "$win"
run "$work/nofocus" VSCODE_PID=123 __CFBundleIdentifier=com.microsoft.VSCode NOTIFY_FOCUS_FOLDER=0
check "$work/nofocus" nofocus com.microsoft.VSCode

# No open window holds the session folder: the click only brings VS Code forward.
rm "$state"
run "$work/nowindow" VSCODE_PID=123 __CFBundleIdentifier=com.microsoft.VSCode
check "$work/nowindow" nofocus com.microsoft.VSCode

# A terminal, and the desktop app (only its bundle id says where it runs).
run "$work/iterm" TERM_PROGRAM=iTerm.app
check "$work/iterm" nofocus com.googlecode.iterm2
run "$work/desktop" __CFBundleIdentifier=com.anthropic.claudefordesktop
check "$work/desktop" nofocus com.anthropic.claudefordesktop

# terminal-notifier off PATH, in a folder whose name has a space, named by NOTIFY_TN_DIRS (colon list).
tnd="$work/tn dir with space"; mkdir -p "$tnd"; mv "$bin/terminal-notifier" "$tnd/terminal-notifier"
run "$work/tndirs" VSCODE_PID=123 __CFBundleIdentifier=com.microsoft.VSCode NOTIFY_TN_DIRS="/nonexistent:$tnd"
check "$work/tndirs" nofocus com.microsoft.VSCode

rm "$tnd/terminal-notifier"
# NOTIFY_TN_DIRS empty: the runner may carry a terminal-notifier of its own in /usr/local/bin.
run "$work/fallback" VSCODE_PID=123 __CFBundleIdentifier=com.microsoft.VSCode NOTIFY_TN_DIRS=
check "$work/fallback" fallback
echo "all click-target checks passed"
