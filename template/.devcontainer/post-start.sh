#!/bin/bash
# =============================================================================
# Post-start script — runs on every container start (postStartCommand)
# =============================================================================

# postStartCommand is launched via `docker exec -u vscode ...` and the base
# devcontainer image does not declare ENV HOME, so $HOME is often empty here.
# An empty $HOME silently expands `$HOME/.local/bin` to `/.local/bin` and
# breaks every PATH lookup downstream (uv, cargo, claude). Resolve from
# /etc/passwd before anything else uses $HOME.
HOME="${HOME:-$(getent passwd "$(whoami)" | cut -d: -f6)}"
export HOME

WORKSPACE_DIR="${containerWorkspaceFolder:-$(pwd)}"
BASHRC="$HOME/.bashrc"

# postStartCommand inherits a minimal system PATH and does not source ~/.bashrc,
# so user-installed CLIs (uv, cargo, claude) are invisible here and to any
# subprocess we launch (notably post-start-project.sh and the MCP servers it
# spawns). Re-export the same PATH that post-create.sh sets up.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.claude/bin:$PATH"

echo "============================================"
echo "  Post-start checks..."
echo "============================================"

mkdir -p /tmp/claude-code

# --- Claude alias ---
echo "[1/3] Claude alias..."
if ! grep -q "alias claude=" "$BASHRC" 2>/dev/null; then
  echo 'alias claude="claude --dangerously-skip-permissions"' >> "$BASHRC"
  echo "  alias added"
else
  echo "  already set"
fi

# --- Sécurisation des fichiers sensibles ---
echo "[2/3] Securing sensitive files..."
chmod 600 "$WORKSPACE_DIR/.env"      2>/dev/null && echo "  .env" || true
chmod 600 "$WORKSPACE_DIR/.mcp.json" 2>/dev/null && echo "  .mcp.json" || true

# --- Chargement du .env ---
echo "[3/3] Loading .env..."
if [ -f "$WORKSPACE_DIR/.env" ]; then
  set -a; source "$WORKSPACE_DIR/.env"; set +a
  echo "  .env loaded"
else
  echo "  .env not found — copy from .env.example if needed"
fi

# =============================================================================
# MCP servers (template-managed — lib-mcp.sh + mcp-servers.conf)
# Self-healing: a failed post-create install (e.g. missing
# GITHUB_PERSONAL_ACCESS_TOKEN at first build) is repaired here on a plain
# container restart — no rebuild needed.
# =============================================================================
echo ""
echo "--- MCP servers (mcp-servers.conf) ---"
source "$WORKSPACE_DIR/.devcontainer/lib-mcp.sh"
mcp_process_manifest "$WORKSPACE_DIR/.devcontainer/mcp-servers.conf" start

# Optional second sap-adt-mcp instance targeting SAP ECC EHP8 on port 8001.
# Runtime-gated, not Jinja-gated: starts only when both .env.ecc and the ECC
# launcher exist, so ECC can be flipped on/off without re-running copier.
SAP_ADT_ECC_LAUNCHER="/opt/sap-adt-mcp/scripts/mcp-server-ecc.sh"
if [ -f "/opt/sap-adt-mcp/.env.ecc" ] && [ -x "$SAP_ADT_ECC_LAUNCHER" ]; then
  "$SAP_ADT_ECC_LAUNCHER" start
  mcp_wait_port "sap-adt-ecc" 8001 "/opt/sap-adt-mcp/logs/server-ecc.log"
fi

# =============================================================================
# Project-specific checks (not managed by template — safe from copier update)
# =============================================================================
PROJECT_POST_START="$WORKSPACE_DIR/.devcontainer/post-start-project.sh"
if [ -f "$PROJECT_POST_START" ]; then
  echo ""
  echo "--- Project-specific post-start ---"
  warn_legacy_mcp_hooks "$PROJECT_POST_START"
  bash "$PROJECT_POST_START" "$WORKSPACE_DIR"
else
  echo "  (no post-start-project.sh — see post-start-project.example.sh)"
fi

echo ""
echo "============================================"
echo "  Post-start complete!"
echo "============================================"
