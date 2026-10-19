#!/usr/bin/env bash
# notify-waiting.sh: a desktop notification when Claude Code is waiting on a person.
#
# Wire it as a Notification hook (and, if you want one on every finished turn, a Stop hook)
# in ~/.claude/settings.json; the hook reads the event's JSON on stdin and shows one notification:
#   title: "Claude Code: <project folder>"   body: the event's message, or what the event means.
#
# Works in every surface that runs Claude Code with your settings (the terminal, the VS Code
# extension, the desktop app). macOS uses terminal-notifier when installed: a click brings the app
# the session runs in to the front, and for VS Code the window that holds the session's folder.
# Without it macOS falls back to osascript, whose notifications macOS files under Script Editor, so
# a click on one opens Script Editor (install.sh installs terminal-notifier with Homebrew). Linux
# uses notify-send; Windows (Git Bash, WSL with a Windows host) uses a PowerShell toast. No
# notifier found: exit 0 quietly.
#
# Settings file, optional: ~/.claude/notify-waiting.conf (shell variables)
#   NOTIFY_ON_STOP=1        also notify when a turn ends (the Stop hook); default off, because a
#                           Notification idle_prompt already fires after 60 s idle and many parallel
#                           sessions would otherwise notify on every turn
#   NOTIFY_SOUND=Glass      macOS sound name (default Glass); empty for silent
#   NOTIFY_QUIET_TYPES="auth_success quota_auto_resume_fired"   types to skip (default below)
#   NOTIFY_ACTIVATE=com.microsoft.VSCode   bundle id terminal-notifier brings forward on click
#                           (default: the app the session runs in, from TERM_PROGRAM, then
#                           VSCODE_PID for the VS Code extension, then __CFBundleIdentifier)
#   NOTIFY_FOCUS_FOLDER=0   for VS Code, bring the app forward without asking it to focus the
#                           window that holds the session's folder (default 1)
#   NOTIFY_TN_DIRS="/opt/homebrew/bin:/usr/local/bin"   folders searched for terminal-notifier when
#                           it is not on the hook's PATH, separated by colons like PATH (default
#                           shown; empty: PATH only)
#
# Exit code and output are ignored by Claude Code for Notification hooks; this script never fails
# the event. It writes nothing to the transcript.
set -u

input="$(cat 2>/dev/null || true)"
conf="${CLAUDE_NOTIFY_CONF:-$HOME/.claude/notify-waiting.conf}"
# shellcheck disable=SC1090
[ -f "$conf" ] && . "$conf"
NOTIFY_ON_STOP="${NOTIFY_ON_STOP:-0}"
NOTIFY_SOUND="${NOTIFY_SOUND-Glass}"
NOTIFY_QUIET_TYPES="${NOTIFY_QUIET_TYPES:-auth_success elicitation_complete elicitation_response quota_auto_resume_fired}"
NOTIFY_FOCUS_FOLDER="${NOTIFY_FOCUS_FOLDER:-1}"

# One JSON field, read with python3, then jq, then a plain-text fallback.
field() {
  local key="$1" out=""
  if command -v python3 >/dev/null 2>&1; then
    out="$(printf '%s' "$input" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); v=d.get(sys.argv[1], "")
    print(v if isinstance(v,str) else ("" if v is None else json.dumps(v)))
except Exception:
    print("")' "$key" 2>/dev/null)"
  elif command -v jq >/dev/null 2>&1; then
    out="$(printf '%s' "$input" | jq -r --arg k "$key" '.[$k] // "" | tostring' 2>/dev/null)"
  else
    out="$(printf '%s' "$input" | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1)"
  fi
  printf '%s' "$out"
}

event="$(field hook_event_name)"
ntype="$(field notification_type)"
[ -z "$ntype" ] && ntype="$(field type)"
message="$(field message)"
cwd="$(field cwd)"
session="$(field session_id)"
project="${cwd##*/}"
[ -z "$project" ] && project="${PWD##*/}"

case "$event" in
  Stop)
    [ "$NOTIFY_ON_STOP" = "1" ] || exit 0
    # A Stop that follows another Stop hook's block is not a turn ending.
    [ "$(field stop_hook_active)" = "true" ] && exit 0
    ntype="turn_done"
    ;;
  Notification|"") ;;
  *) exit 0 ;;
esac

for q in $NOTIFY_QUIET_TYPES; do
  [ "$ntype" = "$q" ] && exit 0
done

case "$ntype" in
  permission_prompt)        meaning="Waiting for your permission" ;;
  idle_prompt)              meaning="Waiting for your next message" ;;
  agent_needs_input)        meaning="An agent needs your input" ;;
  agent_completed)          meaning="A background agent finished" ;;
  elicitation_dialog|elicitation_url_dialog) meaning="A tool is asking you something" ;;
  quota_auto_resume_stale)  meaning="The usage limit reset while the Mac slept; press Enter to continue" ;;
  quota_auto_resume_disabled) meaning="Stopped at a usage limit and will not continue on its own" ;;
  turn_done)                meaning="Finished and waiting for you" ;;
  *)                        meaning="Needs your attention" ;;
esac
body="${message:-$meaning}"
# Keep the body to one short line; notifications truncate long text anyway.
body="$(printf '%s' "$body" | tr '\n' ' ' | cut -c1-200)"
title="Claude Code: ${project:-session}"

# Where a click should land: the app this session runs in. TERM_PROGRAM names the terminal a CLI
# session runs in (VS Code's integrated terminal says vscode). The VS Code extension sets none, and
# VSCODE_PID marks it. __CFBundleIdentifier, which macOS sets for every process an app starts, covers
# the rest (the desktop app); it comes last because a process started from a terminal inherits it.
vscode_id() { case "${__CFBundleIdentifier:-}" in com.microsoft.VSCode*) printf '%s' "$__CFBundleIdentifier" ;; *) printf 'com.microsoft.VSCode' ;; esac; }
activate="${NOTIFY_ACTIVATE:-}"
if [ -z "$activate" ]; then
  case "${TERM_PROGRAM:-}" in
    vscode)      activate="$(vscode_id)" ;;
    iTerm.app)   activate="com.googlecode.iterm2" ;;
    Apple_Terminal) activate="com.apple.Terminal" ;;
    ghostty)     activate="com.mitchellh.ghostty" ;;
    WarpTerminal) activate="dev.warp.Warp-Stable" ;;
  esac
fi
[ -z "$activate" ] && [ -n "${VSCODE_PID:-}" ] && activate="$(vscode_id)"
[ -z "$activate" ] && activate="${__CFBundleIdentifier:-}"

# Escape for the AppleScript string literal: backslashes and double quotes.
as_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
# Quote one word for /bin/sh: wrap it in single quotes, each inner quote written as '\''.
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# terminal-notifier on PATH, else in NOTIFY_TN_DIRS, Homebrew's bin folders by default (a hook's PATH
# can be shorter than a shell's). An empty NOTIFY_TN_DIRS looks on PATH only.
NOTIFY_TN_DIRS="${NOTIFY_TN_DIRS-/opt/homebrew/bin:/usr/local/bin}"
find_terminal_notifier() {
  local c d rest
  c="$(command -v terminal-notifier 2>/dev/null)"
  [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  # Split on colons, never on spaces, so a folder name with a space stays whole.
  rest="$NOTIFY_TN_DIRS"
  while [ -n "$rest" ]; do
    d="${rest%%:*}"
    if [ "$d" = "$rest" ]; then rest=""; else rest="${rest#*:}"; fi
    [ -n "$d" ] && [ -x "$d/terminal-notifier" ] && { printf '%s' "$d/terminal-notifier"; return 0; }
  done
  return 1
}

# The folder of the open VS Code window that holds the session: the window folder that is the session's
# folder or its nearest parent, read from VS Code's saved window state (windowsState in its
# storage.json). Prints nothing when focusing is off, nothing matches (a multi-root workspace, a
# folder no window holds) or the state can't be read.
vscode_window_folder() {
  [ "$NOTIFY_FOCUS_FOLDER" = "1" ] && [ -n "$cwd" ] && command -v python3 >/dev/null 2>&1 || return 0
  local state="${NOTIFY_VSCODE_STATE:-$HOME/Library/Application Support/$1/User/globalStorage/storage.json}"
  [ -f "$state" ] || return 0
  python3 - "$state" "$cwd" <<'PY' 2>/dev/null || true
import json, os, sys
from urllib.parse import unquote, urlparse
state, cwd = sys.argv[1], os.path.realpath(sys.argv[2])
try:
    ws = json.load(open(state)).get("windowsState") or {}
except Exception:
    sys.exit(0)
# Compare real paths, but hand back the folder as the window holds it: VS Code matches a symlinked
# folder by its own path. A folder name with a line break is skipped (the shell would cut it).
best, best_len = "", -1
for w in [ws.get("lastActiveWindow") or {}] + list(ws.get("openedWindows") or []):
    u = urlparse(w.get("folder") or "")
    if u.scheme != "file":
        continue
    orig = unquote(u.path)
    if "\n" in orig:
        continue
    p = os.path.realpath(orig)
    if (cwd == p or cwd.startswith(p.rstrip("/") + "/")) and len(p) > best_len:
        best, best_len = orig, len(p)
print(best, end="")
PY
}

notify_macos() {
  local tn
  if tn="$(find_terminal_notifier)"; then
    # One group per session: a session's newer notification replaces its older one, never another's.
    set -- -title "$title" -message "$body" -group "claude-code-${session:-$project}"
    [ -n "$NOTIFY_SOUND" ] && set -- "$@" -sound "$NOTIFY_SOUND"
    [ -n "$activate" ] && set -- "$@" -activate "$activate"
    # VS Code reuses and focuses the window that already holds a folder it is asked to open, so with
    # several windows the click lands on this session's one. Only that window's own folder matches, so
    # the open goes out only when one is found; otherwise the click just brings VS Code forward.
    local folder=""
    case "$activate" in
      com.microsoft.VSCode) folder="$(vscode_window_folder Code)" ;;
      com.microsoft.VSCodeInsiders) folder="$(vscode_window_folder "Code - Insiders")" ;;
    esac
    [ -n "$folder" ] && set -- "$@" -execute "/usr/bin/open -b $(sh_quote "$activate") $(sh_quote "$folder")"
    "$tn" "$@" >/dev/null 2>&1 &
    return 0
  fi
  local t b s=""
  t="$(as_escape "$title")"; b="$(as_escape "$body")"
  [ -n "$NOTIFY_SOUND" ] && s=" sound name \"$(as_escape "$NOTIFY_SOUND")\""
  osascript -e "display notification \"$b\" with title \"$t\"$s" >/dev/null 2>&1 &
}

notify_linux() {
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send --app-name="Claude Code" --urgency=normal "$title" "$body" >/dev/null 2>&1 &
}

notify_windows() {
  local ps=""
  for c in powershell.exe pwsh.exe powershell pwsh; do command -v "$c" >/dev/null 2>&1 && { ps="$c"; break; }; done
  [ -n "$ps" ] || return 0
  local t b
  t="$(printf '%s' "$title" | sed "s/'/''/g")"; b="$(printf '%s' "$body" | sed "s/'/''/g")"
  "$ps" -NoProfile -NonInteractive -Command "
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime];
    \$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);
    \$n = \$x.GetElementsByTagName('text'); \$n.Item(0).AppendChild(\$x.CreateTextNode('$t')) | Out-Null; \$n.Item(1).AppendChild(\$x.CreateTextNode('$b')) | Out-Null;
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Claude Code').Show([Windows.UI.Notifications.ToastNotification]::new(\$x))" >/dev/null 2>&1 &
}

case "$(uname -s 2>/dev/null)" in
  Darwin) notify_macos ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then notify_windows; else notify_linux; fi ;;
  MINGW*|MSYS*|CYGWIN*) notify_windows ;;
  *) : ;;
esac
exit 0
