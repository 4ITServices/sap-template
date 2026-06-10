# .devcontainer architecture

## Lifecycle

```
devcontainer.json
  ├── initializeCommand      mkdir ~/.claude (host-side, before build)
  ├── onCreateCommand        git config + claude dirs (once, at image creation)
  ├── postCreateCommand  →   post-create.sh (once, after build)
  │                            ├── MCP servers install (lib-mcp.sh ← mcp-servers.conf)
  │                            └── post-create-project.sh (if exists)
  └── postStartCommand   →   post-start.sh (every container start)
                               ├── MCP servers self-heal + launch (lib-mcp.sh ← mcp-servers.conf)
                               └── post-start-project.sh (if exists)
```

## File ownership

| File | Owner | Updated by |
|---|---|---|
| `devcontainer.json` | template | `copier update` |
| `post-create.sh` | template | `copier update` |
| `post-start.sh` | template | `copier update` |
| `lib-mcp.sh` | template | `copier update` (MCP lifecycle engine) |
| `mcp-servers.conf` | **project** | developer (`_skip_if_exists` — seeded once, never overwritten) |
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
8. Bootstrap `.env` / `.mcp.json` from examples
9. MCP servers install (`lib-mcp.sh` over `mcp-servers.conf`)

**post-start.sh** (runs on every start):
1. Claude alias (`--dangerously-skip-permissions` in .bashrc)
2. `chmod 600` on sensitive files (.env, .mcp.json)
3. Source `.env`
4. MCP servers: self-heal (re-clone if absent/broken), update, launch,
   port health-check (`lib-mcp.sh` over `mcp-servers.conf`)

## Managed MCP servers (mcp-servers.conf)

`.devcontainer/mcp-servers.conf` declares the MCP servers the lifecycle
manages — one `NAME REPO [REF] [PORT]` line per server (`-` = unset). The
file is **project-owned** (`_skip_if_exists`): add or pin servers there,
and the template-owned engine (`lib-mcp.sh`, updated by `copier update`)
takes care of cloning into `/opt/<NAME>`, building (uv/npm), symlinking
`.env`, launching `scripts/mcp-server.sh start` and waiting for the port.

Self-healing: if the first build could not clone (typically an empty
`GITHUB_PERSONAL_ACCESS_TOKEN` in `.env`), fill the token and simply
**restart** the container — post-start repairs the install, no rebuild
needed. Broken half-clones are detected (not a valid git work tree) and
re-cloned. Install/build details are logged to `/tmp/<NAME>.log`.

## Project-specific scripts

To add project-specific setup, create these files:

```bash
# Copy from examples
cp .devcontainer/post-create-project.example.sh .devcontainer/post-create-project.sh
cp .devcontainer/post-start-project.example.sh  .devcontainer/post-start-project.sh
```

These files receive `$WORKSPACE_DIR` as `$1` and are called at the end of the
template scripts. They are **never overwritten** by `copier update`.

Since template v0.8.15 (`hook-api: 2`), generic MCP server lifecycle no
longer belongs in these hooks — it is template-managed via
`mcp-servers.conf`. Keep the hooks for genuinely project-specific extras
(extra tooling, Ansible, IaC…). Hooks that still define their own
`install_mcp_server`/`update_mcp_server` (pre-v0.8.15) keep working but
trigger a migration warning at each start: slim them down to the extras,
using the current `.example.sh` files as reference.

## SAP MCP Servers (ADT + GUI)

- [sap-adt-mcp](https://github.com/4ITServices/sap-adt-mcp) (>= 2.6.1) — SAP
  ABAP Development Tools (ADT REST API + RFC + HANA). Streamable-HTTP transport
  on `http://127.0.0.1:8000/mcp`. Read/write ABAP objects, syntax check,
  activation, transport management, abapGit bridge (Phase D), HANA queries.
  Installed in `/opt/sap-adt-mcp` and launched by the lifecycle via the
  canonical launcher `scripts/mcp-server.sh start` shipped by the repo
  (PID file, log at `/opt/sap-adt-mcp/logs/server.log`, idempotent).
- [sap-gui-mcp](https://github.com/4ITServices/sap-gui-mcp) — SAP GUI
  automation. Requires Windows (COM/pywin32): runs **remote on the Windows
  VM** (`http://<MCP_VM_HOST>:8001/mcp`, see `.mcp.json`), never installed
  locally in the devcontainer.

### Dual-stack: ECC EHP8 second instance (optional)

When the template is generated with `enable_ecc_stack: true`, a second
sap-adt-mcp instance can run side-by-side on port 8001, targeting SAP
ECC EHP8 (NetWeaver 7.50, ~155 tools — RAP / CDS / SRVB excluded). The
two instances cohabit on the same machine:

| Stack | Port | Launcher | Log | PID |
|---|---|---|---|---|
| S/4HANA 2023 FPS03 | 8000 | `scripts/mcp-server.sh` | `logs/server.log` | `.mcp-server.pid` |
| ECC EHP8 | 8001 | `scripts/mcp-server-ecc.sh` | `logs/server-ecc.log` | `.mcp-server-ecc.pid` |

To activate at runtime:

1. Copy `.env.ecc.example` → `.env.ecc` and fill in the ECC credentials.
2. Restart the container (or run `bash .devcontainer/post-start.sh`).
3. `.mcp.json` exposes both instances under names `sap-adt-mcp` (S/4) and
   `sap-adt-ecc` (ECC). Tools are addressable via `mcp__sap-adt-mcp__*`
   and `mcp__sap-adt-ecc__*` respectively.

The ECC launcher reads `/opt/sap-adt-mcp/.env.ecc` (symlinked from the
workspace by the lifecycle), overrides `MCP_PORT=8001`, then delegates to
the same canonical `mcp-server.sh`. To disable: delete `.env.ecc` — the
post-start block becomes a no-op.

Note: local port 8001 (ECC instance) is unrelated to the Windows VM's
port 8001 (remote sap-gui-mcp) — different hosts, easy to mix up in
`.mcp.json`.

ECC quirks (15 SAP-side + 3 ZMCP) are documented upstream in
`/opt/sap-adt-mcp/docs/ecc-ehp8-quirks.md`.

### MCP configuration (.mcp.json)

Copy `.mcp.json.example` to `.mcp.json` :

```bash
cp .mcp.json.example .mcp.json
```

Les credentials SAP (SAP_URL, SAP_USER, SAP_PASSWORD, etc.) sont lus automatiquement
depuis `.env` par pydantic-settings. Le `.mcp.json` ne contient que la config
structurelle (commandes, chemins). Pas de secrets dedans.

## Post-`copier update` checklist

`copier update` rewrites the template-owned files; a few things it cannot
do for you:

1. **Before updating** (one-time hygiene): make sure the tree is clean and
   contains no previously committed conflict markers:
   `grep -rEl '^(<<<<<<<|>>>>>>>)' . --exclude-dir=.git`
2. Run `copier update`, then scan for fresh inline conflicts (copier ≥ 9
   writes them into the files): same grep as above. Resolve them — an
   unresolved marker in `devcontainer.json` means invalid JSON and a
   container that no longer builds.
3. **Re-align `.mcp.json`** with `.mcp.json.example` (gitignored,
   bootstrapped once — copier never updates it): server names, removed or
   added entries.
4. **Resync project hooks** if the start logs show the pre-v0.8.15
   migration warning: slim `post-*-project.sh` down to project extras,
   using the current `.example.sh` files as reference. MCP servers belong
   in `mcp-servers.conf` (project-owned, kept by copier).
5. Smoke-test the lifecycle without rebuilding:
   `bash .devcontainer/post-start.sh` (self-heals /opt installs, launches
   the servers, health-checks the ports).

### Explicit MCP permissions

The template uses `bypassPermissions` by default. If you switch to explicit
permissions in `.claude/settings.json`, add:

```json
{
  "permissions": {
    "allow": [
      "mcp__sap-adt-mcp__*",
      "mcp__sap-adt-ecc__*",
      "mcp__sap-gui-mcp__*"
    ]
  }
}
```
