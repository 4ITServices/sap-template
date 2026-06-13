#!/usr/bin/env bash
# =============================================================================
# tmux-session.sh — VS Code integrated-terminal launcher that runs the shell
# inside a persistent tmux session. A long-running Claude Code session then
# survives events that would otherwise kill the terminal process:
#   - VS Code window reload            (also covered by persistentSessions)
#   - full VS Code restart / revive    (this script reattaches the session)
#   - Remote-SSH disconnect, host sleep
# …as long as the dev container itself keeps running (shutdownAction: none).
#
# Reattach from any shell:        tmux attach -t claude
# Ad-hoc non-tmux shell:          pick the "bash" profile in the + dropdown
# Use a different session name:   export CLAUDE_TMUX_SESSION=foo
#
# This file is referenced by terminal.integrated.profiles.linux in
# devcontainer.json. It is intentionally defensive: if tmux is missing or we
# are already inside tmux, it falls back to a plain login shell.
# =============================================================================
set -uo pipefail

SESSION="${CLAUDE_TMUX_SESSION:-claude}"

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
# every reload/restart. On reattach we refresh them in the running session so
# `code`, git askpass, ssh-agent and the Claude IDE link keep pointing at live
# sockets (panes opened after reattach pick these up; the original pane keeps
# its first values — losing only IDE niceties, never the session itself).
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

if tmux has-session -t "$SESSION" 2>/dev/null; then
  for v in "${FORWARD_VARS[@]}"; do
    [ -n "${!v:-}" ] && tmux setenv -t "$SESSION" "$v" "${!v}"
  done
  exec tmux attach-session -t "$SESSION"
fi

new_args=()
for v in "${FORWARD_VARS[@]}"; do
  [ -n "${!v:-}" ] && new_args+=( -e "$v=${!v}" )
done
exec tmux new-session -s "$SESSION" "${new_args[@]}"
