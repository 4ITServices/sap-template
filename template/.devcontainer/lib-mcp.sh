#!/bin/bash
# =============================================================================
# lib-mcp.sh — generic MCP server lifecycle (TEMPLATE-OWNED)
# Updated by `copier update` — do not edit in projects.
#
# Sourced by post-create.sh and post-start.sh, which drive it from the
# project-owned manifest .devcontainer/mcp-servers.conf. To add/remove a
# managed server, edit the manifest — not the hooks, not this file.
#
# Design constraints:
#   - functions must survive `set -eu` callers: every env read is guarded
#     with ${VAR:-} and every best-effort command has an explicit fallback
#   - never abort the container lifecycle: helpers always return 0
#   - never persist credentials: the GitHub PAT is injected per git
#     invocation (ephemeral -c config), never written to .git/config
#   - self-healing: a broken or missing /opt/<name> install is repaired on
#     plain container restart — no rebuild needed
# =============================================================================

# Include guard (tolerates double-sourcing)
[ -n "${_LIB_MCP_LOADED:-}" ] && return 0
_LIB_MCP_LOADED=1
LIB_MCP_VERSION=2

# Install prefix — overridable for tests (servers land in $MCP_OPT_DIR/<name>)
MCP_OPT_DIR="${MCP_OPT_DIR:-/opt}"

# Create DIR owned by the current user, using sudo only when the parent
# is not writable (devcontainer /opt is root-owned; test dirs are not).
_mcp_provision_dir() {
  local DIR="$1"
  if [ -w "$(dirname "$DIR")" ]; then
    install -d "$DIR"
  elif sudo -n true 2>/dev/null; then
    sudo install -d -o "$(id -un)" -g "$(id -gn)" "$DIR"
  else
    return 1
  fi
}

_mcp_rmtree() {
  local DIR="$1"
  case "$DIR" in
    "$MCP_OPT_DIR"/?*) ;;                                  # only ever wipe under the prefix
    *) echo "  refusing to wipe suspicious path '$DIR'"; return 1 ;;
  esac
  rm -rf "$DIR" 2>/dev/null || sudo rm -rf "$DIR"
}

# Run git with ephemeral PAT auth. The insteadOf rewrite applies only to
# this invocation; the URL stored in .git/config stays tokenless.
# GIT_LFS_SKIP_SMUDGE: the LFS smudge filter calls `git credential fill`,
# ignores the inline PAT and prompts (then fails) on private repos. MCP
# servers ship code, not LFS payloads — skipping is safe.
_mcp_git() {
  if [ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    GIT_LFS_SKIP_SMUDGE=1 git -c "url.https://x-access-token:${GITHUB_PERSONAL_ACCESS_TOKEN}@github.com/.insteadOf=https://github.com/" "$@"
  else
    GIT_LFS_SKIP_SMUDGE=1 git "$@"
  fi
}

# An install is healthy iff it is a real git work tree AND has a buildable
# manifest. A "directory exists and is non-empty" test misses half-clones
# (mkdir succeeded, clone died mid-fetch) which then wedge forever.
_mcp_healthy() {
  local DEST="$1"
  git -C "$DEST" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  [ -f "$DEST/pyproject.toml" ] || [ -f "$DEST/package.json" ]
}

_mcp_build() {
  local DEST="$1" NAME="$2" LOG="/tmp/$2.log"
  if [ -f "$DEST/pyproject.toml" ]; then
    (cd "$DEST" && uv sync) >>"$LOG" 2>&1 \
      && echo "  $NAME built (Python)" \
      || echo "  WARNING: uv sync failed for $NAME (log: $LOG)"
  elif [ -f "$DEST/package.json" ]; then
    (cd "$DEST" && { npm ci --silent || npm install --silent; } && npm run build --silent) >>"$LOG" 2>&1 \
      && echo "  $NAME built (Node.js)" \
      || echo "  WARNING: npm build failed for $NAME (log: $LOG)"
  else
    echo "  WARNING: no pyproject.toml or package.json in $DEST"
  fi
  return 0
}

# ensure_mcp_server NAME REPO [REF]
# Clone /opt/NAME if absent or broken, else update it; then build.
# REF pins a tag/branch ('-' or empty = track the default branch).
ensure_mcp_server() {
  local NAME="${1:-}" REPO="${2:-}" REF="${3:-}"
  [ "$REF" = "-" ] && REF=""
  if [ -z "$NAME" ] || [ -z "$REPO" ]; then
    echo "  ERROR: ensure_mcp_server NAME REPO [REF] — NAME and REPO are required"
    return 0
  fi
  local DEST="$MCP_OPT_DIR/$NAME" LOG="/tmp/$NAME.log"

  echo "[mcp] $NAME..."

  if _mcp_healthy "$DEST"; then
    # Scrub any PAT a pre-v0.8.15 hook baked into origin, then refresh.
    git -C "$DEST" remote set-url origin "$REPO" 2>/dev/null || true
    if [ -n "$REF" ]; then
      if _mcp_git -C "$DEST" fetch --tags --force --quiet >>"$LOG" 2>&1 \
         && git -C "$DEST" checkout --quiet "$REF" >>"$LOG" 2>&1; then
        echo "  pinned to $REF"
      else
        echo "  WARNING: checkout of '$REF' failed for $NAME — keeping current version (log: $LOG)"
      fi
    else
      _mcp_git -C "$DEST" pull --quiet >>"$LOG" 2>&1 \
        || echo "  WARNING: git pull failed for $NAME — keeping current version (log: $LOG)"
    fi
    _mcp_build "$DEST" "$NAME"
    return 0
  fi

  # --- self-healing install path ---
  if [ -d "$DEST" ]; then
    echo "  broken install detected (interrupted clone?) — wiping $DEST for re-install"
    _mcp_rmtree "$DEST" || return 0
  fi
  if [ -z "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]; then
    case "$REPO" in
      https://github.com/*)
        echo "  NOTE: GITHUB_PERSONAL_ACCESS_TOKEN is empty — cloning a private repo will fail."
        echo "        Fill it in ${WORKSPACE_DIR:-the workspace}/.env, then RESTART the container (no rebuild needed)."
        ;;
    esac
  fi
  if ! _mcp_provision_dir "$DEST"; then
    echo "  ERROR: cannot create $DEST (passwordless sudo unavailable?)"
    return 0
  fi
  if _mcp_git clone ${REF:+--branch "$REF"} "$REPO" "$DEST" >>"$LOG" 2>&1; then
    echo "  cloned $REPO${REF:+ @ $REF}"
    _mcp_build "$DEST" "$NAME"
  else
    # Leave no half-clone behind so self-healing stays armed for next start.
    _mcp_rmtree "$DEST"
    echo "  ERROR: clone failed for $NAME (details: $LOG)"
    echo "         Most common cause: missing/expired GITHUB_PERSONAL_ACCESS_TOKEN in .env."
    echo "         Fix .env, then restart the container — no rebuild needed."
  fi
  return 0
}

# mcp_link_env NAME — symlink the workspace .env (and .env.ecc when present)
# into the server dir so pydantic-settings finds SAP credentials.
mcp_link_env() {
  local NAME="${1:-}" DEST="$MCP_OPT_DIR/${1:-}"
  [ -n "$NAME" ] && [ -d "$DEST" ] || return 0
  [ -f "${WORKSPACE_DIR:-}/.env" ] && ln -sf "$WORKSPACE_DIR/.env" "$DEST/.env"
  [ -f "${WORKSPACE_DIR:-}/.env.ecc" ] && ln -sf "$WORKSPACE_DIR/.env.ecc" "$DEST/.env.ecc"
  return 0
}

# start_mcp_server NAME [PORT]
# Delegates to the canonical launcher scripts/mcp-server.sh shipped inside
# the server repo (PID file, logs/server.log, idempotent start). When PORT
# is given, waits for the streamable-http endpoint and prints the log tail
# on timeout instead of failing silently.
start_mcp_server() {
  local NAME="${1:-}" PORT="${2:-}"
  [ "$PORT" = "-" ] && PORT=""
  local DEST="$MCP_OPT_DIR/$NAME" LAUNCHER="$MCP_OPT_DIR/$NAME/scripts/mcp-server.sh"

  [ -d "$DEST" ] || return 0   # install failed — ensure_mcp_server already explained
  if [ ! -x "$LAUNCHER" ]; then
    echo "[mcp] $NAME: scripts/mcp-server.sh missing — repo too old? (sap-adt-mcp needs >= 2.6.1)"
    return 0
  fi
  "$LAUNCHER" start
  [ -n "$PORT" ] && mcp_wait_port "$NAME" "$PORT" "$DEST/logs/server.log"
  return 0
}

# mcp_wait_port NAME PORT [LOGFILE] — poll http://127.0.0.1:PORT/mcp for up
# to 30 s. Any HTTP response (even 4xx) proves a listener; connection
# refused does not.
mcp_wait_port() {
  local NAME="${1:-}" PORT="${2:-}" LOGFILE="${3:-$MCP_OPT_DIR/${1:-}/logs/server.log}" i=0
  command -v curl >/dev/null 2>&1 || return 0
  while [ "$i" -lt 30 ]; do
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:$PORT/mcp"; then
      echo "  $NAME answering on 127.0.0.1:$PORT"
      return 0
    fi
    i=$((i + 1)); sleep 1
  done
  echo "  WARNING: $NAME not answering on 127.0.0.1:$PORT after 30s — log tail:"
  tail -n 20 "$LOGFILE" 2>/dev/null | sed 's/^/    | /'
  return 0
}

# mcp_process_manifest MANIFEST MODE
# MANIFEST lines: NAME REPO [REF] [PORT]  ('-' = unset, '#' starts a comment)
# MODE 'create' → ensure + link env ; MODE 'start' → ensure + link + launch.
mcp_process_manifest() {
  local MANIFEST="${1:-}" MODE="${2:-start}"
  if [ ! -f "$MANIFEST" ]; then
    echo "[mcp] no mcp-servers.conf — no template-managed MCP servers"
    return 0
  fi
  local NAME REPO REF PORT REST
  # fd 9 keeps the manifest stream away from stdin-hungry children (git, npm)
  while read -r NAME REPO REF PORT REST <&9 || [ -n "${NAME:-}" ]; do
    case "${NAME:-}" in ''|'#'*) NAME=""; continue ;; esac
    ensure_mcp_server "$NAME" "${REPO:-}" "${REF:-}"
    mcp_link_env "$NAME"
    [ "$MODE" = "start" ] && start_mcp_server "$NAME" "${PORT:-}"
    NAME=""
  done 9< "$MANIFEST"
  return 0
}

# warn_legacy_mcp_hooks HOOKFILE
# Pre-v0.8.15 project hooks carried their own install/update_mcp_server
# copies. They still run (in their own child shell — no collision with this
# lib) but duplicate work and may persist a PAT into /opt/*/.git/config.
warn_legacy_mcp_hooks() {
  local HOOK="${1:-}"
  [ -f "$HOOK" ] || return 0
  if grep -Eq '^[[:space:]]*(install|update)_mcp_server[[:space:]]*\(\)' "$HOOK"; then
    echo ""
    echo "  NOTE: $(basename "$HOOK") defines its own install/update_mcp_server (pre-v0.8.15)."
    echo "        The template now installs, self-heals and launches MCP servers from"
    echo "        .devcontainer/mcp-servers.conf (see .devcontainer/lib-mcp.sh)."
    echo "        Slim this hook down to project-specific extras — reference:"
    echo "        $(basename "$HOOK" .sh).example.sh"
  fi
  return 0
}
