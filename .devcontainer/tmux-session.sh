#!/usr/bin/env bash
# =============================================================================
# tmux-session.sh — VS Code integrated-terminal launcher that runs the shell
# inside a persistent tmux session. It reconciles two goals:
#
#   PARALLELISM  — every new terminal tab gets its OWN session, named
#                  <prefix>-<pid>. Two live tabs never share a session, so you
#                  can run several Claude Code instances side by side without
#                  them mirroring each other (same window/pane/keystrokes).
#   PERSISTENCE  — a long Claude Code run survives events that would otherwise
#                  kill the terminal process (window reload, full VS Code
#                  restart/revive, Remote-SSH disconnect, host sleep) as long as
#                  the dev container keeps running (shutdownAction: none). On
#                  revival, each reopened tab REATTACHES one DETACHED (orphaned)
#                  session left behind by the previous VS Code life.
#
# Invariant: a session that already has a live client (session_attached != 0) is
# NEVER reclaimed — that is what prevents mirroring. Orphan reclamation is
# atomic (rename-session is the lock): on a multi-tab revival the first rename
# wins and the losers fall back to creating a fresh session.
#
# Reattach from any shell:        tmux attach -t <prefix>-<pid>   (see `tmux ls`)
# Ad-hoc non-tmux shell:          pick the "bash" profile in the + dropdown
# Override the session prefix:    export CLAUDE_TMUX_SESSION=foo
#
# This file is referenced by terminal.integrated.profiles.linux in
# devcontainer.json. It is intentionally defensive: if tmux is missing or we
# are already inside tmux, it falls back to a plain login shell.
# =============================================================================
set -uo pipefail

SESSION_PREFIX="${CLAUDE_TMUX_SESSION:-claude}"

# Fallbacks: no tmux, or already inside a tmux server -> plain login shell.
if ! command -v tmux >/dev/null 2>&1; then exec "${SHELL:-/bin/bash}" -l; fi
if [ -n "${TMUX:-}" ];               then exec "${SHELL:-/bin/bash}" -l; fi

# Global options must be set BEFORE the first pane is created — history-limit
# only applies to panes spawned after it is set.
tmux start-server 2>/dev/null || true
tmux set-option        -g history-limit     50000 2>/dev/null || true
tmux set-option        -g mouse             on    2>/dev/null || true
tmux set-option        -g allow-passthrough on    2>/dev/null || true
tmux set-window-option -g aggressive-resize on    2>/dev/null || true

# VS Code injects per-window IPC handles into the environment; they change on
# every reload/restart. We push them into the tmux server's GLOBAL environment
# (setenv -g) so freshly created sessions inherit live sockets, and we refresh a
# reattached orphan in place (setenv -t) so `code`, git askpass, ssh-agent and
# the Claude IDE link keep pointing at live sockets.
FORWARD_VARS=(
  VSCODE_IPC_HOOK_CLI
  VSCODE_GIT_IPC_HANDLE
  VSCODE_GIT_ASKPASS_MAIN
  VSCODE_GIT_ASKPASS_NODE
  VSCODE_GIT_ASKPASS_EXTRA_ARGS
  GIT_ASKPASS
  SSH_AUTH_SOCK
  CLAUDE_CODE_SSE_PORT
)

for v in "${FORWARD_VARS[@]}"; do
  [ -n "${!v:-}" ] && tmux setenv -g "$v" "${!v}" 2>/dev/null || true
done

# Reclaim a DETACHED session of our prefix and echo its name. rename-session is
# an atomic lock: on a multi-tab revival only the first rename of a given orphan
# succeeds; losers return non-zero and fall back to new-session. A session with
# a live client (session_attached != 0) is never reclaimed (avoids mirroring).
claim_orphan() {
  local attached name claimed
  claimed="${SESSION_PREFIX}-$$"
  while read -r attached name; do
    [ "$attached" = "0" ] || continue
    case "$name" in
      "$SESSION_PREFIX"|"$SESSION_PREFIX"-*) ;;
      *) continue ;;
    esac
    if [ "$name" = "$claimed" ]; then
      printf '%s\n' "$name"; return 0
    fi
    if tmux rename-session -t "$name" "$claimed" 2>/dev/null; then
      printf '%s\n' "$claimed"; return 0
    fi
  done < <(tmux list-sessions -F '#{session_attached} #{session_name}' 2>/dev/null)
  return 1
}

# Persistence: reattach an orphan (revival after restart/disconnect).
orphan="$(claim_orphan)"
if [ -n "$orphan" ]; then
  for v in "${FORWARD_VARS[@]}"; do
    [ -n "${!v:-}" ] && tmux setenv -t "$orphan" "$v" "${!v}"
  done
  exec tmux attach-session -t "$orphan"
fi

# Parallelism: fresh, uniquely named session — this tab is independent.
new_args=()
for v in "${FORWARD_VARS[@]}"; do
  [ -n "${!v:-}" ] && new_args+=( -e "$v=${!v}" )
done
exec tmux new-session -s "${SESSION_PREFIX}-$$" "${new_args[@]}"
