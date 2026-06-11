# .devcontainer architecture

## Lifecycle

```
devcontainer.json
  ├── initializeCommand      mkdir ~/.claude (host-side, before build)
  ├── onCreateCommand        git config + claude dirs (once, at image creation)
  ├── postCreateCommand  →   post-create.sh (once, after build)
  │                            └── post-create-project.sh (if exists)
  └── postStartCommand   →   post-start.sh (every container start)
                               └── post-start-project.sh (if exists)
```

## File ownership

| File | Owner | Updated by |
|---|---|---|
| `devcontainer.json` | template | `copier update` |
| `post-create.sh` | template | `copier update` |
| `post-start.sh` | template | `copier update` |
| `post-create-project.sh` | **project** | developer (never overwritten by template) |
| `post-start-project.sh` | **project** | developer (never overwritten by template) |
| `*.example.sh` | template | reference/documentation |
| `.mcp.json.example` | template | `copier update` (project root) |

## Template scripts (generic)

**post-create.sh** (runs once after build):
1. Install just (command runner)
2. Git LFS setup
3. Restore Claude auth from backup
4. Install uv + copier (Python toolchain)
5. Install Claude Code CLI
6. Python dependencies (`uv sync`)
7. Git submodules init

**post-start.sh** (runs on every start):
1. Claude alias (`--dangerously-skip-permissions` in .bashrc)
2. `chmod 600` on sensitive files (.env, .mcp.json)
3. Source `.env`

## Project-specific scripts

To add project-specific setup, create these files:

```bash
# Copy from examples
cp .devcontainer/post-create-project.example.sh .devcontainer/post-create-project.sh
cp .devcontainer/post-start-project.example.sh  .devcontainer/post-start-project.sh
```

These files receive `$WORKSPACE_DIR` as `$1` and are called at the end of the
template scripts. They are **never overwritten** by `copier update`.

## Available examples

### SAP MCP Servers (ADT + GUI)

`post-create-project.example.sh` and `post-start-project.example.sh` ship with
support for two MCP servers:

- [sap-adt-mcp](https://github.com/4ITServices/sap-adt-mcp) — SAP ABAP
  Development Tools (ADT REST API + RFC). Lecture/ecriture objets ABAP, syntax
  check, activation, transport management.
- [sap-gui-mcp](https://github.com/4ITServices/sap-gui-mcp) — SAP GUI
  automation. Session management, navigation ecran, execution transactions.

**post-create**: clones both repos and builds them (`npm ci && npm run build`)
into `/opt/sap-adt-mcp` and `/opt/sap-gui-mcp`.

**post-start**: pulls latest changes and rebuilds in background (container
available immediately, logs in `/tmp/sap-adt-mcp.log` and `/tmp/sap-gui-mcp.log`).

### MCP configuration (.mcp.json)

Copy `.mcp.json.example` to `.mcp.json` :

```bash
cp .mcp.json.example .mcp.json
```

Les credentials SAP (SAP_URL, SAP_USER, SAP_PASSWORD, etc.) sont lus automatiquement
depuis `.env` par pydantic-settings. Le `.mcp.json` ne contient que la config
structurelle (commandes, chemins). Pas de secrets dedans.

### Explicit MCP permissions

The template uses `bypassPermissions` by default. If you switch to explicit
permissions in `.claude/settings.json`, add:

```json
{
  "permissions": {
    "allow": [
      "mcp__sap-adt-mcp__*",
      "mcp__sap-gui-mcp__*"
    ]
  }
}
```
