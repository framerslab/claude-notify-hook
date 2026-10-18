#!/usr/bin/env bash
# notify-waiting.sh: a desktop notification when Claude Code is waiting on a person.
#
# Wire it as a Notification hook (and, if you want one on every finished turn, a Stop hook)
# in ~/.claude/settings.json; the hook reads the event's JSON on stdin and shows one notification:
#   title: "Claude Code: <project folder>"   body: the event's message, or what the event means.
#
# Works in every surface that runs Claude Code with your settings (the terminal, the VS Code
# extension, the desktop app). Dependency-free: macOS uses terminal-notifier when installed
# (click brings the app forward), else osascript; Linux uses notify-send; Windows (Git Bash,
# WSL with a Windows host) uses a PowerShell toast. No notifier found: exit 0 quietly.
#
# Settings file, optional: ~/.claude/notify-waiting.conf (shell variables)
#   NOTIFY_ON_STOP=1        also notify when a turn ends (the Stop hook); default off, because a
#                           Notification idle_prompt already fires after 60 s idle and many parallel
#                           sessions would otherwise notify on every turn
#   NOTIFY_SOUND=Glass      macOS sound name (default Glass); empty for silent
#   NOTIFY_QUIET_TYPES="auth_success quota_auto_resume_fired"   types to skip (default below)
#   NOTIFY_ACTIVATE=com.microsoft.VSCode   bundle id terminal-notifier brings forward on click
#                           (default: the terminal or editor the session runs in, when known)
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

# Where a click should land: the editor or terminal this session runs in, when it says so.
activate="${NOTIFY_ACTIVATE:-}"
if [ -z "$activate" ]; then
  case "${TERM_PROGRAM:-}" in
    vscode)      activate="com.microsoft.VSCode" ;;
    iTerm.app)   activate="com.googlecode.iterm2" ;;
    Apple_Terminal) activate="com.apple.Terminal" ;;
    ghostty)     activate="com.mitchellh.ghostty" ;;
    WarpTerminal) activate="dev.warp.Warp-Stable" ;;
  esac
fi

# Escape for the AppleScript string literal: backslashes and double quotes.
as_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

notify_macos() {
  if command -v terminal-notifier >/dev/null 2>&1; then
    set -- -title "$title" -message "$body" -group "claude-code-$project"
    [ -n "$NOTIFY_SOUND" ] && set -- "$@" -sound "$NOTIFY_SOUND"
    [ -n "$activate" ] && set -- "$@" -activate "$activate"
    terminal-notifier "$@" >/dev/null 2>&1 &
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
