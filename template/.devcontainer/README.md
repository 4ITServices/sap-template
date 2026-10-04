# .devcontainer architecture

## Lifecycle

```
devcontainer.json
  ├── initializeCommand      mkdir ~/.claude or ~/.claude-profiles/<profile> (host-side, before build)
  ├── onCreateCommand        git config + claude dirs (once, at image creation)
  ├── postCreateCommand  →   post-create.sh (once, after build)
  │                            ├── MCP servers install (lib-mcp.sh ← mcp-servers.conf)
  │                            ├── dbt workspace (lib-dbt.sh ← dbt.conf) — dbt-project only
  │                            └── post-create-project.sh (if exists)
  └── postStartCommand   →   post-start.sh (every container start)
                               ├── MCP servers self-heal + launch (lib-mcp.sh ← mcp-servers.conf)
                               ├── dbt workspace self-heal (lib-dbt.sh ← dbt.conf) — dbt-project only
                               └── post-start-project.sh (if exists)
```

## File ownership

| File | Owner | Updated by |
|---|---|---|
| `devcontainer.json` | template | `copier update` |
| `post-create.sh` | template | `copier update` |
| `post-start.sh` | template | `copier update` |
| `lib-mcp.sh` | template | `copier update` (MCP lifecycle engine) |
| `tmux-session.sh` | template | `copier update` (integrated-terminal tmux launcher) |
| `lib-dbt.sh`, `dbt-run.sh`, `dbt-doctor.sh`, `features/google-cloud-cli/` | template | `copier update` (dbt-project only — dbt workspace engine) |
| `dbt.conf`, `upstream_known_hosts` | **project** | developer (dbt-project only — `dbt.conf` is seeded once from the copier answers, `_skip_if_exists`; the pinned host keys are scanned once, then reviewed and committed) |
| `mcp-servers.conf` | **project** | developer (`_skip_if_exists` — seeded once, never overwritten; to opt out, comment out every line — a *deleted* file is re-seeded by the next `copier update`) |
| `post-create-project.sh` | **project** | developer (never overwritten by template) |
| `post-start-project.sh` | **project** | developer (never overwritten by template) |
| `*.example.sh` | template | reference/documentation |
| `.mcp.json.example` | template | `copier update` (project root) |
| `~/.claude/` (host) | **Claude Code** — shared by every container without a profile | never touched by copier; mounted on `/home/vscode/.claude` when `claude_profile` is empty |
| `~/.claude-profiles/<profile>/` (host) | **Claude Code** — one per profile | never touched by copier; created empty by `initializeCommand`, mounted on `/home/vscode/.claude` when `claude_profile` is set |

## Template scripts (generic)

**post-create.sh** (runs once after build):
1. Install just (command runner)
2. Git LFS setup
3. Restore `~/.claude.json` from the newest `~/.claude/backups/` entry (the
   profile's own backups when `claude_profile` is set)
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

## Claude profiles (one Claude account per container)

By default (`claude_profile` empty) every container bind-mounts the same host
`~/.claude`. It holds the one `.credentials.json`, so a `/login` in any
container switches **all** of them. The `backups/` there are written by every
container too, so step 3 of `post-create.sh` restores whichever container
saved last, whatever its account.

Answering the copier question `claude_profile` (e.g. `sap-testing`) mounts
`~/.claude-profiles/<profile>` from the host instead. The target is unchanged
(`/home/vscode/.claude`), so nothing else in the template moves. The profile
dir stays on the host: login, chat history (`projects/<slug>/*.jsonl`,
`history.jsonl`), memory (`projects/<slug>/memory/`) and `backups/` survive
any rebuild, including without cache. `~/.claude.json` still lives in the
container and is restored from the **profile's** backups. Repos given the
same profile share its account: that is how two repos share a login.

Everything under `~/.claude` becomes per-profile, including user settings,
skills and plugins. They are seeded once when a repo is migrated and diverge
afterwards.

**Migrating an existing repo** (the step where history could be lost):
`scripts/claude-profile-migrate.sh` in the sap-template repo, run **on the
host** with the repo's container **stopped**. It is a dry run unless you pass
`--apply`, and it only **copies** (the host-wide `~/.claude` is only ever read):

- user config: settings, skills, plugins…
- the repo's `projects/<slug>/` (transcripts and memory)
- its `history.jsonl` lines
- its `file-history/`

It never copies `.credentials.json` (you `/login` again), `backups/` or
runtime state. Then `copier update` with the profile, rebuild, `/login`, and
check with `claude --resume`. To roll back, set `claude_profile` back to empty
and rebuild: `~/.claude` was never modified.

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

## dbt workspace (`project_type: dbt-project`)

The container takes over an existing dbt project (the *upstream* repository)
and keeps two versions of it side by side: the original on dbt Core 1.x and
its migration to dbt v2. The repository's `main` branch only carries the
tooling; the dbt code lives in two git worktrees of the same repository,
ignored by `main`:

| Path | Branch | Engine | Command |
|---|---|---|---|
| `v1/` | `v1` (starts at the upstream branch) | dbt Core 1.x, venv `/opt/dbt-v1` built from the pins the project ships | `dbt1`, `just v1 …` |
| `v2/` | `v2` (starts at `v1`) | dbt v2, `~/.local/bin/dbt` (official installer) | `dbtf`, `just v2 …` |

`lib-dbt.sh` (template-owned) drives everything from `dbt.conf`
(project-owned), on create and again on every start, since both engines,
`~/.gitconfig` and `~/.bashrc` live in the container filesystem:

1. **Upstream access, read-only.** The upstream host key is pinned in
   `.devcontainer/upstream_known_hosts` (`~/.ssh` is mounted read-only, so ssh
   cannot record it). `https://<upstream host>/` is fetched over SSH (private
   dbt packages). Pushing to that host is impossible: a global
   `url."DISABLED://".pushInsteadOf` covers explicit URLs and submodules, and
   `remote.upstream.pushurl` is `DISABLED`. `DBT_UPSTREAM_PUSH_LOCK=0` lifts
   both.
2. **Worktrees.** Branches come from `origin` when already published, else
   `v1` is created from the upstream branch (fetched once) and `v2` from
   `v1`. The worktrees are **locked**: their git links are container paths
   that do not exist on the host, and an unlocked worktree would be dropped by
   a `git worktree prune` or an automatic gc run host-side. `git worktree
   repair` runs on every start, so renaming the workspace folder is harmless.
   Nothing is ever pushed or deleted by the hooks.
3. **Engines.** dbt v2 must sit at `~/.local/bin/dbt`: it is the only path the
   official dbt extension looks at without a `dbt.dbtPath` override, and where
   it can keep the binary in step with itself. It is installed once per build
   and never upgraded on a restart. dbt Core is only reachable as `dbt1`. In
   an interactive shell `dbt` is a function that picks the engine from the
   directory.
4. **Profile hub.** `containerEnv` sets `DBT_PROFILES_DIR` to
   `<workspace>/profiles` for every process — terminals, both dbt extensions,
   hooks, `docker exec`. The `profiles.yml` shipped inside the worktrees
   target the real projects and are never read; a profile missing from the hub
   is an error. `profiles/profiles.yml` is seeded once from `dbt.conf`
   (`DBT_BQ_*`) and then project-owned; with no sandbox declared, none is
   generated and dbt stays locked.
5. **Write guard** (`dbt-run.sh`, behind `just v1|v2` and the `dbt` function).
   A `run`/`build`/`seed`/`snapshot` needs an explicit selection, and every
   selected node must resolve (`dbt ls`, offline) to `DBT_BQ_PROJECT` — and to
   a dataset starting with `DBT_BQ_DATASET_PREFIX` when set. `run-operation`
   is refused, and a project with hooks cannot write until
   `DBT_HOOKS_REVIEWED=1`. The raw engines and the extensions' Run/Build
   buttons only get the hub, not this guard.

BigQuery authentication uses the host's `~/.config/gcloud` (bind mount):
`gcloud auth login` + `gcloud auth application-default login` once, valid for
every container mounting it. gcloud comes from a **local** feature
(`features/google-cloud-cli`): the public `ghcr.io/dhoeric` one is abandoned
and fails on current Debian images (`apt-key` is gone).

Editors: the official dbt extension drives dbt v2; dbt Power User drives dbt
Core through `/opt/dbt-v1/bin/python` and is restricted to `v1/`
(`dbt.allowListFolders`). The official extension has no folder filter and
both bind `Ctrl/Cmd+Enter`; for one extension per window, open `v1/` or `v2/`
alone (`code v1`) — `lib-dbt.sh` seeds a `.vscode/settings.json` in each
worktree for that. `.ignore` at the root gives the worktrees back to
ripgrep-based search (VS Code, Claude Code), which `.gitignore` hides.

`just doctor` checks all of the above and repairs nothing; `just setup`
replays the lifecycle.

### Starting a new dbt-project repository

1. `copier copy gh:4ITServices/sap-template <dir> --data project_type=dbt-project`
   and answer the upstream URL, branch and sandbox questions.
2. `git init -b main`, commit, create the (private) repository, push `main`.
3. Open the container. The hooks scan and pin the upstream host key, fetch the
   upstream branch (it needs the SSH key and, if any, the VPN) and create
   `v1/` and `v2/`. Check the fingerprints, review the seeded hub, then commit
   `.devcontainer/upstream_known_hosts` and `profiles/profiles.yml` on `main`.
4. Publish the three branches to `origin` — the hooks never push:
   `just upstream-pull` (the `upstream-<branch>` mirror), then
   `git -C v1 push -u origin v1` and `git -C v2 push -u origin v2`.

A later clone gets everything from `origin`: its first start needs no access
to the upstream.

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
  VM** (`http://192.168.50.119:8001/mcp` by default — edit the
  `sap-gui-mcp` entry in `.mcp.json` if the VM IP changes), never installed
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

The post-start ECC block is **runtime-gated for every project**, not only
those generated with `enable_ecc_stack: true`. On a project generated
without the flag, activate ECC by hand: create `.env.ecc` yourself (the
field list ships as `.env.ecc.example` in ECC-enabled renders, or see
`/opt/sap-adt-mcp/docs/`) and add the `sap-adt-ecc` http entry
(`http://127.0.0.1:8001/mcp`) to `.mcp.json`.

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
   in `mcp-servers.conf` (project-owned, kept by copier). Do it promptly:
   until slimmed, the legacy helper re-writes your GitHub PAT in cleartext
   into `/opt/<name>/.git/config` at each start (the template scrubs it
   back out right after, but the cycle only stops with the resync).
5. **Inside the devcontainer**, smoke-test the lifecycle without
   rebuilding: `bash .devcontainer/post-start.sh` (self-heals /opt
   installs, launches the servers, health-checks the ports). Do not run
   it on the host: it appends to `~/.bashrc` and provisions `/opt`.
6. **First time `claude_profile` is set**: stop the container and migrate
   the history (see *Claude profiles*) **before** rebuilding. Otherwise the
   rebuilt container starts with an empty history. Nothing is lost: it is
   still in the host's `~/.claude`, and migrating later works too.

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
