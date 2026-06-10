#!/bin/bash
# =============================================================================
# Project-specific post-create — runs once after container build
# This file is owned by the project, NOT the template.
# Template updates will never overwrite this file.
#
# hook-api: 2 (template >= v0.8.15)
# Generic MCP server install/update/launch is handled by the TEMPLATE hooks
# (post-create.sh / post-start.sh) through .devcontainer/lib-mcp.sh, driven
# by the project-owned manifest .devcontainer/mcp-servers.conf.
#   → to add/remove a managed MCP server, edit mcp-servers.conf — not this.
# Keep this hook for genuinely project-specific setup only.
# =============================================================================

WORKSPACE_DIR="${1:-$(pwd)}"

# .env is already sourced by post-create.sh; re-source when run standalone
if [ -f "$WORKSPACE_DIR/.env" ]; then
  set -a; source "$WORKSPACE_DIR/.env"; set +a
fi

# The shared helpers (ensure_mcp_server, start_mcp_server, mcp_link_env, …)
# are available if custom steps need them:
# source "$(dirname "${BASH_SOURCE[0]:-$0}")/lib-mcp.sh"

# =============================================================================
# SAP GUI MCP — remote on the Windows VM (needs COM/pywin32), nothing to
# install locally. Configured in .mcp.json (http://<MCP_VM_HOST>:8001/mcp).
# =============================================================================
echo "[project] sap-gui-mcp is remote on the Windows VM (see .mcp.json) — no local install"

# =============================================================================
# IaC Tooling — Azure CLI, OpenTofu, Bicep (si enable_iac)
# =============================================================================
# echo "[iac] Azure CLI..."
# if command -v az &>/dev/null; then
#   echo "  az already installed"
# else
#   curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash 2>/dev/null
# fi
#
# echo "[iac] OpenTofu..."
# if command -v tofu &>/dev/null; then
#   echo "  tofu already installed"
# else
#   curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh \
#     && chmod +x /tmp/install-opentofu.sh \
#     && sudo /tmp/install-opentofu.sh --install-method deb 2>/dev/null \
#     && rm -f /tmp/install-opentofu.sh
# fi
#
# echo "[iac] Bicep CLI..."
# if command -v az &>/dev/null; then
#   az bicep install 2>/dev/null
# fi
