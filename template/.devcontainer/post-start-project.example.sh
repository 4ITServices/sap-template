#!/bin/bash
# =============================================================================
# Project-specific post-start — runs on every container start
# This file is owned by the project, NOT the template.
# Template updates will never overwrite this file.
#
# hook-api: 2 (template >= v0.8.15)
# Generic MCP server update/self-healing/launch is handled by the TEMPLATE
# hook (post-start.sh) through .devcontainer/lib-mcp.sh, driven by the
# project-owned manifest .devcontainer/mcp-servers.conf — including the
# optional ECC EHP8 second instance (runtime-gated by .env.ecc).
#   → to add/remove a managed MCP server, edit mcp-servers.conf — not this.
# Keep this hook for genuinely project-specific checks only.
# =============================================================================

WORKSPACE_DIR="${1:-$(pwd)}"

# .env is already sourced by post-start.sh; re-source when run standalone
if [ -f "$WORKSPACE_DIR/.env" ]; then
  set -a; source "$WORKSPACE_DIR/.env"; set +a
fi

# The shared helpers (ensure_mcp_server, start_mcp_server, mcp_wait_port, …)
# are available if custom steps need them:
# source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib-mcp.sh"

# =============================================================================
# SAP GUI MCP — remote (Windows VM via HTTP), nothing to start locally
# =============================================================================
echo "[project] sap-gui-mcp is remote (see .mcp.json) — no local start"

# =============================================================================
# IaC — Azure CLI session check
# =============================================================================
# echo "[iac] Azure CLI session check..."
# if command -v az &>/dev/null; then
#   az account show &>/dev/null 2>&1 \
#     && echo "  az logged in: $(az account show --query name -o tsv)" \
#     || echo "  az not logged in — run: just az-login"
# fi
