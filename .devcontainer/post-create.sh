#!/bin/bash
# =============================================================================
# Post-create script — runs once after container build (postCreateCommand)
# =============================================================================
# No set -e — each step handles its own errors to avoid cascading failures

WORKSPACE_DIR="${containerWorkspaceFolder:-$(pwd)}"
cd "$WORKSPACE_DIR"

echo "============================================"
echo "  Post-create setup starting..."
echo "============================================"

# =============================================================================
# 1. Install Claude Code CLI
# =============================================================================
echo "[1/6] Installing Claude Code CLI..."

# Restore ~/.claude.json from backup BEFORE installer runs (avoids repeated warnings)
if [ ! -f "$HOME/.claude.json" ]; then
  BACKUP=$(ls "$HOME/.claude/backups/.claude.json.backup."* 2>/dev/null | sort | tail -1)
  if [ -n "$BACKUP" ]; then
    cp "$BACKUP" "$HOME/.claude.json"
    echo "  ~/.claude.json restored from backup"
  fi
fi

if command -v claude &>/dev/null; then
  echo "  claude found at $(which claude)"
else
  echo "  claude not found, installing..."
  curl -fsSL https://claude.ai/install.sh | bash || \
    npm install -g @anthropic-ai/claude-code 2>/dev/null || \
    echo "  WARNING: install failed — run manually"
fi
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$HOME/.claude/bin:$PATH"' >> ~/.bashrc

# =============================================================================
# 2. uv + copier — Python toolchain
# =============================================================================
echo "[2/6] uv + copier (Python toolchain)..."
if command -v uv &>/dev/null; then
  echo "  uv found at $(which uv)"
else
  echo "  installing uv..."
  curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null && \
    echo "  uv installed" || echo "  WARNING: uv install failed"
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"' >> ~/.bashrc

if command -v copier &>/dev/null; then
  echo "  copier found at $(which copier)"
else
  echo "  installing copier..."
  pip install copier --quiet 2>/dev/null && \
    echo "  copier installed" || echo "  WARNING: copier install failed"
fi

# =============================================================================
# 3. GitHub CLI
# =============================================================================
echo "[3/6] GitHub CLI..."
if command -v gh &>/dev/null; then
  echo "  gh found at $(which gh) — $(gh --version | head -1)"
else
  echo "  installing gh..."
  (type -p wget >/dev/null || sudo apt-get install wget -y -qq) && \
  sudo mkdir -p -m 755 /etc/apt/keyrings && \
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null && \
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
    sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null && \
  sudo apt-get update -qq && sudo apt-get install gh -y -qq && \
  echo "  gh installed" || echo "  WARNING: gh install failed"
fi

# =============================================================================
# 4. npm install (if package.json exists)
# =============================================================================
echo "[4/6] Project dependencies..."
if [ -f "$WORKSPACE_DIR/package.json" ]; then
  npm install --silent 2>/dev/null && echo "  npm install done" || echo "  WARNING: npm install failed"
else
  echo "  no package.json — skipping"
fi

# =============================================================================
# 5. Git submodules (no-op if no .gitmodules)
# =============================================================================
echo "[5/6] Git submodules..."
if [ -f "$WORKSPACE_DIR/.gitmodules" ]; then
  git submodule update --init --recursive 2>/dev/null && \
    echo "  submodules initialized" || echo "  WARNING: submodule init failed"
else
  echo "  no .gitmodules — skipping"
fi

# =============================================================================
# 6. npm install + build in submodules (if any have package.json)
# =============================================================================
echo "[6/6] Submodule dependencies..."
if [ -f "$WORKSPACE_DIR/.gitmodules" ]; then
  git submodule foreach --quiet \
    'if [ -f package.json ]; then echo "  Building $name..."; npm install --silent && npm run build 2>/dev/null && echo "    OK" || echo "    WARNING: build failed"; fi' \
    2>/dev/null || true
else
  echo "  no submodules — skipping"
fi

# =============================================================================
# Long-session stability — tmux (decouples Claude Code from the VS Code pty so
# a session survives window reload / restart / disconnect). The integrated-
# terminal tmux profile lives in devcontainer.json + tmux-session.sh.
# =============================================================================
echo "[stability] tmux..."
if command -v tmux &>/dev/null; then
  echo "  tmux $(tmux -V)"
else
  sudo apt-get update -qq 2>/dev/null \
    && sudo apt-get install -y -qq tmux 2>/dev/null \
    && echo "  tmux installed ($(tmux -V))" \
    || echo "  WARNING: tmux install failed"
fi

# =============================================================================
# Project-specific setup (not managed by template — safe from template updates)
# =============================================================================
PROJECT_POST_CREATE="$WORKSPACE_DIR/.devcontainer/post-create-project.sh"
if [ -f "$PROJECT_POST_CREATE" ]; then
  echo ""
  echo "--- Project-specific post-create ---"
  bash "$PROJECT_POST_CREATE" "$WORKSPACE_DIR"
else
  echo "  (no post-create-project.sh — skipping)"
fi

echo ""
echo "============================================"
echo "  Post-create setup complete!"
echo "============================================"
