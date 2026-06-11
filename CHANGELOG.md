# Changelog

All notable changes to this template are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Earlier releases (v0.1.0–v0.8.11) are documented in their git tag annotations
and commit messages; this changelog starts at v0.8.12.

## [0.8.16] — 2026-06-11

### Changed

- Repositories moved to the `4ITServices` GitHub organisation: the
  `github_org` copier default is now `4ITServices` (existing projects keep
  the org recorded in their `.copier-answers.yml`), and the usage header
  points at `gh:4ITServices/sap-template`. The template repo's own
  devcontainer hooks/README also clone sap-adt-mcp / sap-gui-mcp from
  `4ITServices`.

## [0.8.15] — 2026-06-10

Hardening release after the `copier update` v0.5.1 → v0.8.14 incident on a
downstream project (sap-adt-mcp unreachable on 127.0.0.1:8000 — see
`4ITServices/sap-gui-mcp@b8a0d11` for the downstream-side fix this release
generalizes).

### Changed

- **MCP server lifecycle is now template-managed.** Install/update/launch
  used to live only in the project-owned `post-*-project.sh` hooks (seeded
  manually from `.example.sh` files), so downstream projects never
  inherited hook fixes via `copier update`. The generic engine now lives
  in template-owned files updated by copier:
  - `.devcontainer/lib-mcp.sh` — ensure/build/launch helpers, called by
    `post-create.sh` and `post-start.sh`.
  - `.devcontainer/mcp-servers.conf` — project-owned declarative manifest
    (`NAME REPO [REF] [PORT]`, `_skip_if_exists`): projects add servers
    as data, the engine stays upgradable.
  - `post-*-project.sh` hooks are now for project extras only
    (`hook-api: 2`); pre-v0.8.15 hooks that still define their own
    `install/update_mcp_server` keep working but trigger a migration
    warning at each start.
- `.mcp.json.example`: ADT server renamed `sap-adt` → `sap-adt-mcp`
  (matches the documented `mcp__sap-adt-mcp__*` permissions); added the
  remote `sap-gui-mcp` entry (type http, Windows VM —
  `http://<MCP_VM_HOST>:8001/mcp`, never installed locally). Existing
  projects: `.mcp.json` is gitignored and bootstrapped once — re-align it
  manually (see post-update checklist).
- `CLAUDE.md`: the MCP servers table no longer claims sap-gui-mcp lives in
  `/opt/sap-gui-mcp` (it requires Windows COM/pywin32 and runs remote on
  the VM); documents the `sap-adt-ecc` instance (undocumented since
  v0.8.14); the ABAP conventions block (package naming + absolute rule
  no 1) is now rendered only for `abap-project` — other project types got
  an unprompted derived package name (e.g. `GUIMCP`) injected into their
  safety rule.
- `devcontainer.json` no longer forces `CLAUDE_CODE_EFFORT_LEVEL`,
  `CLAUDE_CODE_MAX_OUTPUT_TOKENS`, `CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY`
  on every developer through `remoteEnv` (per-user preferences).

### Added

- **Self-healing installs**: post-start re-clones `/opt/<name>` when it is
  absent or broken — a failed first build (typically an empty
  `GITHUB_PERSONAL_ACCESS_TOKEN`) is repaired by a plain container
  restart, no rebuild. Health = valid git work tree + buildable manifest,
  so interrupted half-clones are detected and wiped instead of wedging
  forever.
- Port health-check after launch (S/4 8000, ECC 8001) with server log tail
  on timeout; install/build logs in `/tmp/<name>.log` instead of
  `/dev/null`.
- Post-`copier update` checklist in `.devcontainer/README.md` (conflict
  markers, `.mcp.json` re-alignment, hook resync, no-rebuild smoke test).
- `_skip_if_exists` for `.abapgit.xml`: generated once, then owned by
  abapGit on the SAP side (BOM + IGNORE churn) — copier stops re-rendering
  it on every update.
- Type-specific files (`.abapgit.xml`, `abap/`, `tofu/`, `bicep/`, the
  tofu workflows, `.env.ecc.example`) are now excluded via Jinja
  conditions in their path names instead of `rm` `_tasks`: tasks re-ran on
  every `copier update` and would have deleted such files if a project
  hand-added them after generation.

### Fixed

- Removed the dead `mcp-sap-docs` entry from `.mcp.json.example` (nothing
  installs `/opt/mcp-sap-docs` anymore — fresh clones got a broken MCP
  server on first build).
- The GitHub PAT is no longer persisted into `/opt/*/.git/config` (it was
  written there in cleartext by the per-start `git remote set-url`):
  tokens are injected per git invocation, and the origins are scrubbed
  both before the manifest run and again *after* the project hooks — so
  even an unmigrated pre-v0.8.15 hook that re-bakes the token is cleaned
  up in the same start.
- Generated `.gitignore` now ignores `.env.ecc` (the dual-stack flow
  instructs users to create it with SAP ECC credentials); post-start also
  `chmod 600`s it.
- `SAP_WEBGUI_URL` in `.env.example` is now quoted — the unquoted `&` in
  its query string broke `source .env` in the lifecycle hooks.

## [0.8.14] — 2026-05-11

### Added

- Optional dual-stack deployment of sap-adt-mcp: a second instance can run
  side-by-side targeting **SAP ECC EHP8** (NetWeaver 7.50) on port 8001,
  while the existing S/4HANA 2023 FPS03 instance keeps using port 8000.
  Gated by a new copier question `enable_ecc_stack` (default: false).
- New file `.env.ecc.example.jinja` (rendered only when the dual stack is
  enabled): contains the ECC SAP_* connection block. Users copy it to
  `.env.ecc`, which `mcp-server-ecc.sh` sources to override SAP_URL etc.
- `.mcp.json.example.jinja` adds a conditional `sap-adt-ecc` entry pointing
  at `http://127.0.0.1:8001/mcp`. Tools become addressable as
  `mcp__sap-adt-ecc__*`.
- `post-create-project.example.sh` symlinks `.env.ecc` →
  `/opt/sap-adt-mcp/.env.ecc` (mirrors the existing `.env` symlink).
- `post-start-project.example.sh` launches `mcp-server-ecc.sh start` when
  both the script and `.env.ecc` are present. Drop `.env.ecc` to disable
  ECC at runtime without regenerating the template.
- `.devcontainer/README.md` documents the dual-stack flow (launchers,
  ports, log paths, how to activate / deactivate).

### Notes

- ECC EHP8 stack ID `ecc_ehp8` is auto-detected upstream; no env var
  required. Users who want to force it explicitly can set `SAP_STACK` in
  `.env.ecc` (commented hint shipped in the example).
- The post-start launch is opt-in by file presence rather than Jinja
  gating, so users can flip ECC on/off after generation without re-
  running `copier update`.
- ~155 tools surface on the ECC instance (vs ~190 on S/4): RAP / CDS /
  SRVB are excluded by capability gating, plus 15 SAP-side quirks (501
  on `find_definition`, `usage_references`, etc.) are documented at
  `/opt/sap-adt-mcp/docs/ecc-ehp8-quirks.md`.

## [0.8.13] — 2026-05-10

### Changed

- Bump sap-adt-mcp deployment to **v2.6.1+**. Repository moved from
  `jeanbaptistemack/sap-adt-mcp` to `4ITServices/sap-adt-mcp`.
  - `post-create-project.example.sh` clones the new origin URL.
  - `.devcontainer/README.md` updates URL and describes the new launch
    flow / log path.
- `post-start-project.example.sh` delegates to the canonical launcher
  shipped by sap-adt-mcp itself: `scripts/mcp-server.sh start`. The
  script handles PID file, log file (`/opt/sap-adt-mcp/logs/server.log`),
  health check on `/.well-known/oauth-protected-resource`, and is
  idempotent. Drops our local `setsid -f uv run …` block — the v2.x
  upstream script does the same detachment and adds health-wait + PID
  management.

### Added

- `.env.example.jinja` (mcp-server projects): optional
  `VOYAGE_API_KEY` / `OPENAI_API_KEY` (commented) for sap-adt-mcp's
  offline SAP Docs semantic search. Without them, sap-adt-mcp falls
  back to BM25 (plain-text) automatically.

### Notes

- Phase D (split of `ZCL_MCP_ICF` into 3 classes) is handled SAP-side
  via `bridge_install_offline` / `bridge_migrate_v2` MCP tools — the
  template does not ship ABAP bootstrap scripts for ZMCP, so no change
  needed here. Existing downstream projects with the legacy mono-class
  in their SAP system should run `bridge_migrate_v2 confirm:true`.
- `SAP_STACK` / `SAP_DB` are auto-detected by sap-adt-mcp at lifespan
  startup; not added to `.env.example` to avoid inventing config that
  isn't in the canonical sap-adt-mcp `.env.example`.

## [0.8.12] — 2026-05-04

### Fixed

- `devcontainer.json` now declares `remoteUser: "vscode"`,
  `userEnvProbe: "loginShell"`, and `containerEnv.HOME: "/home/vscode"` so
  `$HOME` is invariant across all lifecycle stages (Feature install, hooks,
  attached terminals, orphaned daemons). The previous reliance on the
  toolchain to inject HOME caused intermittent empty-`$HOME` expansions in
  `postStartCommand`, which broke every PATH lookup downstream.
- `post-start-project.example.sh` refactored: the `update_mcp_server` helper
  now runs **foreground** (was a `(...) &` subshell), and the daemon launch
  uses `setsid -f` (atomic fork+setsid+exec) instead of the
  `setsid nohup ... </dev/null & + disown` chain wrapped in `(...) &`.
  Together this eliminates the race between concurrent `uv sync` and the
  HTTP server start, and the daemon enters its new session **before** the
  parent returns — so SIGHUP/SIGTERM from the postStart wrapper never
  reaches it.

### Notes

- Resolves the chain of cold-rebuild MCP startup failures tracked in
  v0.8.7–v0.8.11. Each prior fix addressed one symptom (transport,
  symlink, setsid, PATH, HOME) but exposed the next; v0.8.12 fixes the
  underlying invariants once.
- General pattern for any future devcontainer daemon: declare invariants
  in `containerEnv` (not `remoteEnv`, which is unset during lifecycle
  hooks), and launch with `setsid -f` (not nested background subshells).
