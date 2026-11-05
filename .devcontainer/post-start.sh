#!/bin/bash
# =============================================================================
# Post-start script — runs on every container start (postStartCommand)
# Loads env, configures Claude, checks credentials & connectivity
# =============================================================================

WORKSPACE_DIR="${containerWorkspaceFolder:-$(pwd)}"
BASHRC="$HOME/.bashrc"

echo "============================================"
echo "  Post-start checks..."
echo "============================================"

# =============================================================================
# 1. Create tmp dirs
# =============================================================================
mkdir -p /tmp/claude-code

# =============================================================================
# 2. Claude alias (belt-and-suspenders alongside .claude/settings.json)
# =============================================================================
echo "[1/6] Claude alias..."
if ! grep -q "alias claude=" "$BASHRC" 2>/dev/null; then
  echo 'alias claude="claude --dangerously-skip-permissions"' >> "$BASHRC"
  echo "  alias added"
else
  echo "  already set"
fi

# =============================================================================
# 3. Project-level .claude.json (allowedTools + permissions)
# =============================================================================
echo "[2/6] Project Claude config..."
CLAUDE_PROJECT="$WORKSPACE_DIR/.claude.json"
if [ ! -f "$CLAUDE_PROJECT" ]; then
  cat > "$CLAUDE_PROJECT" << 'EOF'
{
  "allowedTools": ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "WebFetch", "WebSearch", "Task", "NotebookEdit"],
  "permissions": {
    "allow": ["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)"],
    "deny": []
  }
}
EOF
  echo "  .claude.json created"
else
  echo "  already exists"
fi

# =============================================================================
# 4. Secure sensitive files
# =============================================================================
echo "[3/6] Securing sensitive files..."
chmod 600 "$WORKSPACE_DIR/.env"       2>/dev/null && echo "  .env" || true
chmod 600 "$WORKSPACE_DIR/.mcp.json"  2>/dev/null && echo "  .mcp.json" || true
chmod 600 "$CLAUDE_PROJECT"           2>/dev/null && echo "  .claude.json" || true

# =============================================================================
# 5. Secrets — .env.refs resolved from Key Vault, in memory (dogfood of
#    secrets_source=keyvault). A leftover .env is ignored, never deleted.
# =============================================================================
echo "[4/6] Secrets (Key Vault)..."
export PATH="$HOME/.local/bin:$PATH"
source "$WORKSPACE_DIR/.devcontainer/lib-secrets.sh"
secrets_install "$WORKSPACE_DIR"
secrets_load_env "$WORKSPACE_DIR/.env.refs" || true

# =============================================================================
# 6. AWS credentials
# =============================================================================
echo "[5/6] AWS credentials..."
if command -v aws &>/dev/null; then
  if aws sts get-caller-identity &>/dev/null; then
    echo "  AWS: OK ($(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null))"
  else
    echo "  AWS: credentials not configured"
  fi
else
  echo "  AWS CLI not available, skipping"
fi

# =============================================================================
# 7. Azure credentials
# =============================================================================
echo "[6/6] Azure credentials..."
if command -v az &>/dev/null && [ -n "${AZURE_TENANT_ID:-}" ] && [ -n "${AZURE_CLIENT_SECRET:-}" ]; then
  az login --service-principal \
    --tenant "$AZURE_TENANT_ID" \
    --username "$AZURE_CLIENT_ID" \
    --password "$AZURE_CLIENT_SECRET" \
    --output none 2>/dev/null && \
    az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null && \
    echo "  Azure: SP authenticated" || echo "  Azure: login failed"
else
  echo "  Azure: CLI or credentials not available, skipping"
fi

# =============================================================================
# Project-specific checks (not managed by template — safe from template updates)
# =============================================================================
PROJECT_POST_START="$WORKSPACE_DIR/.devcontainer/post-start-project.sh"
if [ -f "$PROJECT_POST_START" ]; then
  echo ""
  echo "--- Project-specific post-start ---"
  bash "$PROJECT_POST_START" "$WORKSPACE_DIR"
else
  echo "  (no post-start-project.sh — skipping)"
fi

echo ""
echo "============================================"
echo "  Post-start checks complete!"
echo "============================================"
