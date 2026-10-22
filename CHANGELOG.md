# Changelog

All notable changes to this template are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Earlier releases (v0.1.0–v0.8.11) are documented in their git tag annotations
and commit messages; this changelog starts at v0.8.12.

## [Unreleased]

### Added

- **New `dbt-project` project type (`project_type: dbt-project`): take over an
  existing dbt BigQuery project and migrate it from dbt Core 1.x to dbt v2,
  both versions side by side in one container.** The repository's `main`
  branch only carries the tooling. The dbt code lives in two git worktrees of
  the same repository, ignored by `main`: `v1/` (branch `v1`, the original
  project) and `v2/` (branch `v2`, the migration, then the refactoring).
  Driven by a template-owned engine, `.devcontainer/lib-dbt.sh`, and a
  project-owned manifest, `.devcontainer/dbt.conf` (seeded once from the
  copier answers, `_skip_if_exists`) — the same split as `lib-mcp.sh` /
  `mcp-servers.conf`. On create and on every start it:
  - makes the **upstream** repository readable and impossible to push to: the
    host key is pinned in `.devcontainer/upstream_known_hosts` (`~/.ssh` is
    mounted read-only), `https://<host>/` is fetched over SSH for private dbt
    packages, and a push is refused twice — a global
    `url."DISABLED://".pushInsteadOf` (explicit URLs, submodules) plus
    `remote.upstream.pushurl DISABLED`;
  - creates the worktrees, from `origin` when the branches are published,
    else `v1` from the upstream branch and `v2` from `v1`. They are **locked**
    (their links are container paths, which a host-side `git worktree prune`
    would drop) and **repaired** on every start (a renamed workspace folder is
    harmless). Hooks never push and never delete;
  - installs **both engines**: dbt Core 1.x in the `/opt/dbt-v1` venv, built
    from the pins the project itself ships (`pyproject.toml`, else
    `requirements.txt`; rebuilt when they change; interpreter fallbacks 3.11
    and 3.9 for old releases) and exposed as `dbt1`; dbt v2 at
    `~/.local/bin/dbt` through the official installer, exposed as `dbtf` —
    the path the official dbt extension expects. In an interactive shell `dbt`
    picks the engine from the directory;
  - enforces a **fail-closed profile hub**: `containerEnv` sets
    `DBT_PROFILES_DIR` to `<workspace>/profiles` for every process, so the
    `profiles.yml` shipped inside the worktrees (they target the real
    projects) are never read. `profiles/profiles.yml` is seeded once from the
    sandbox declared in `dbt.conf`; with none declared, dbt stays locked.
- **Write guard, `.devcontainer/dbt-run.sh`** (behind `just v1 …`,
  `just v2 …` and the `dbt` shell function). A `run`/`build`/`seed`/`snapshot`
  needs an explicit selection, and every selected node must resolve — through
  an offline `dbt ls` — to the sandbox project, and to a dataset carrying the
  configured prefix. `run-operation` is refused, and a project with hooks
  cannot write until they are reviewed. `just destinations` lists where each
  engine would write every node and where v1 and v2 disagree.
- **`just doctor`** (`.devcontainer/dbt-doctor.sh`): engines, worktrees,
  upstream lock (a dry-run push must fail), profile hub, BigQuery auth, MCP
  ports. It checks and repairs nothing; `just setup` replays the lifecycle.
- **BigQuery access**: host `~/.config/gcloud` bind-mounted (one login for all
  the containers mounting it, no service-account key in the image) and a
  **local** devcontainer feature for gcloud + bq, since the public
  `ghcr.io/dhoeric/features/google-cloud-cli` is abandoned and fails on
  current Debian images (`apt-key` removed).
- **Editors**: the official dbt extension (dbt v2) and dbt Power User (dbt
  Core, restricted to `v1/` by `dbt.allowListFolders`, running on
  `/opt/dbt-v1/bin/python`). `redhat.vscode-yaml` is left out for this type,
  as dbt Labs recommends. A root `.ignore` gives the worktrees back to
  ripgrep-based search (VS Code, Claude Code), which `.gitignore` hides.
- **SAP**: `sap-adt-mcp` is seeded as for the other SAP types (no SAP GUI
  entry); `enable_ecc_stack` is now offered for `dbt-project` too.
- **New copier questions**, asked for `dbt-project` only: `upstream_repo_url`
  (required), `upstream_branch`, `dbt_project_subdir`, `bq_sandbox_project`,
  `bq_sandbox_dataset`, `bq_dataset_prefix`, `bq_location`, `dbt_target_name`.
- **Tests.** New `scripts/test-lib-dbt.sh`: about a hundred offline checks of the lifecycle
  and of the write guard, on throwaway repositories with stubbed engines and
  a fake `HOME`. `scripts/test-template-render.sh` now also covers the
  `dbt-project` render and checks that nothing of it leaks into the other
  types.

- **New `dbt-fleet` project type: several data products in one repository,
  to migrate and refactor them together.** The dbt-project engine
  (`lib-dbt.sh`, `dbt-run.sh`, `dbt-doctor.sh`) now works on a *current
  product*: the single product of a dbt-project, or each line of the
  project-owned `.devcontainer/products.conf` in a fleet. Per product:
  worktrees `v1/<product>/` and `v2/<product>/` on branches `<product>/v1`
  and `<product>/v2`, remote `up-<product>` (push-locked), mirror
  `<product>/upstream` on origin.
  - **One dbt Core version for every v1** (`DBT_V1_PINS`, copier question
    `fleet_v1_pins`, default `dbt-core==1.11.11 dbt-bigquery==1.11.1`):
    dbt Power User has one interpreter per window. `just doctor` lists the
    products whose own pins still differ.
  - **`global/`**, a dbt v2 project seeded once, pulls in the v2 of the
    products flagged `GLOBAL` as local packages (managed block of
    `global/packages.yml`, rewritten at each start). A naming macro gives
    each product its own dataset namespace; writes are refused on relations
    that two nodes would write, and `just destinations global` lists them.
  - `just product-add`, `just products`, and every recipe takes the product:
    `just v1 <product> …`, `just v2 <product> …`, `just global …`.
  - Copier: a computed `dbt_workspace` flag (not stored in the answers)
    selects the files shared by both dbt types; `fleet_v1_pins` is asked for
    `dbt-fleet` only, the sandbox questions for both.
- **Coordinator model** (column `HOME` of `products.conf`): a product's
  branches can live in its **own** repository — a plain dbt-project repo,
  usable alone. The fleet then only holds `main` (tooling, `products.conf`,
  `global/`); worktree branches `<product>/v1|v2` track `home-<product>/v1|v2`
  and `push.default=upstream` sends `git push` there; the upstream mirror is
  the product repo's `upstream-<branch>`. `just sync` (also at each start,
  `DBT_SYNC_ON_START`) fetches every home and fast-forwards the clean
  worktrees — dirty, ahead or diverged ones are reported, never touched.
  Hooks fetch the homes with the workspace token, for that invocation only.
- **`just product-new <name> <url> …`**: renders the product's dbt-project
  repository from the fleet's template version and sandbox answers, fills it
  from upstream (`main`, `upstream-<branch>`, `v1` = `v2`, hub seeded),
  creates `<github_org>/<DBT_PRODUCT_REPO_PREFIX><name>` — private, checked
  before anything is pushed — then declares it.
- **The fleet lock, `.devcontainer/products.lock`**: `just lock` records the
  exact commit of every product's v1 and v2 (pushed commits only, worktrees
  on their branches), to be committed with the change of `global/` it goes
  with — which product versions each state of `global/` was validated with,
  without submodules. `just lock-status` / `just doctor` / `just sync` report
  the drift, `just lock-checkout` replays a locked state, `just lock-release`
  returns to the branches.
- **The coordinator and its products talk through git and `CLAUDE.md`.** A
  product repository is often worked on by its own session, which does not
  know the coordinator exists. New question `fleet_coordinator`
  (`dbt-project` only, empty = standalone product): when set, the product's
  `CLAUDE.md` gains a « Coordination » section — the role of `global/`, the
  shared `v1`/`v2` branches, the lock pointing at its commits, the shared
  `dbt.env` and `DATASET_PREFIX` convention, and what follows (pull before,
  push after, no rewrite of published history, cross-product work goes to
  `global/`, structural changes are said in the commit message) — and its
  README points to it. `product-new` fills it with the coordinator's `origin`
  URL; an existing product gets it with `copier update --data
  fleet_coordinator=<url>`. In the other direction, `just sync` now prints the
  subjects of the commits it fast-forwards (eight at most) and names the
  branches of a product repository the coordinator does not follow (a `v3`
  opened there is a structural change to report).
- **Tests**: 101 offline fleet checks in `scripts/test-lib-dbt.sh` (227 in
  all), and `dbt-fleet` and coordinated-product renders in
  `scripts/test-template-render.sh`.
- **A v4 generation and products born here (fleet).** v4 is dbt v2 again: a
  refactoring branch on top of a product's v2, opt-in per product and never
  part of `DBT_WORKTREES` (`dbt_versions` gives the worktrees of the current
  product). A product listed in `DBT_V4_PRODUCTS` (dbt.conf) also gets
  `v4/<product>/`, branch `<product>/v4` — opened where its branches live,
  from the published v2, and only ever **tracked** (never created from v1 or
  upstream; an unopened v4 is reported, not built). A **referent** — a product
  born here, declared in `.devcontainer/referents.conf` (`NAME SUBDIR HOME`,
  `just referent-add`) — has no upstream remote, no mirror, no v1/v2: one
  `v4/<name>/` worktree that tracks its own repository. `just v4 <product> …`
  and `just global-v4 …` (the v4 assembly) run dbt v2 behind the same guard;
  sync, lock (`<product> v4` lines), destinations, products, doctor, profile
  hub and editor files follow the v4 worktrees.
- **The v4 space, kept apart both ways.** The v2 and the v4 of a product share
  package names: under one prefix they would write the same tables.
  `DBT_BQ_DATASET_PREFIX_V4` (`<DBT_BQ_DATASET_PREFIX>_<x>`, checked) is the
  v4's own prefix; `profiles/v4.env` is generated from `profiles/dbt.env` with
  it. The guard loads it for `v4`/`global-v4` — chosen by the mode, never by
  an inherited variable — and checks, on every command (parse included), that
  `DATASET_PREFIX` is the v4's there and never the v4's elsewhere, and that the
  `.env` the dbt extension reads points to the right file (re-pointed by the
  lifecycle). A write of `v4/` or `global-v4/` must resolve under the v4
  prefix (`=` or `_*`), a write of `v1/`, `v2/` or `global/` never there.
  `global-v4/` gets `global/`'s refusals: `DBT_SANDBOX_NEVER_BUILD` names
  qualified by package, no relation written by two nodes. `just destinations`
  compares v2 with v4 (the v4 prefix, and the v2 prefix left on
  `target.schema`, ignored) and checks every v4 node stays in its space.
- **Fail-closed hooks in the v4 space**: `dbt_hook_commands` gives an unknown
  generation the widest list (`check`, dbt 2.0.8, counted in for v4); the v4
  has no approved-hooks list (`DBT_HOOKS_REVIEWED_V2` never opens it), and
  `DBT_HOOKS_COMPILE_OK` names it apart (`v4/<product>`, `global-v4`): listing
  a product's v2 never opens its v4.
- **`global-v4` compiles under a proof of its hooks, sealed and checked by the
  guard.** Listed in `DBT_HOOKS_COMPILE_OK`, `global-v4` gets compile/show only
  while the proof named by a new fleet setting, `DBT_HOOKS_V4_PROOF` (a file
  of the workspace, written by the fleet's own proof tool), holds for the
  files on disk: its one anchored verdict line, `VERDICT HOOKS GLOBAL-V4 :
  PREUVE OK ; TÉMOINS OK ; sceau <hex>`, carries a seal that `dbt-run.sh`
  recomputes at every compile/show (`lib-dbt.sh`: `dbt_hooks_v4_seal`,
  `dbt_hooks_v4_verdict`). The seal covers what decides which hooks run there
  and what they do — `global-v4/`'s project, package and lock files, all of
  `macros/` and `vendor/`, what deps really installed in `dbt_packages/`
  (each downloaded package file by file outside its `.git`, each link by its
  target), `hooks.approved`, `profiles/v4.env`, `profiles/profiles.yml`, the
  members' project and package files, and the dbt v2 engine's version. A
  changed seal, a state it cannot read (a `local` package in another form, a
  link or special file in a sealed tree, `dbt_packages/` not exactly what
  `package-lock.yml` locks), no proof, a second verdict, another seal quoted
  or a verdict without both OKs: compile/show refused; parse still runs, to
  prove again. A `v4/<product>` has no seal of its own: listed, it is now
  refused. `just doctor` says whether the proof holds. `global/`, the v2
  worktrees and single projects are unchanged.
- **`dbt` typed in a dbt project of the workspace the guard does not know** (a
  copy, a probe) is refused instead of running plain dbt v2.
- **Tests**: 147 more offline checks in `scripts/test-lib-dbt.sh` (413 in all).

### Fixed (on the unreleased dbt-project type)

- **No push by git reaches an upstream host, however it is written or
  reached.** The lock rested on three textual `pushInsteadOf` prefixes per
  host (`git@<host>:`, `ssh://git@<host>/`, `https://<host>/`) plus the
  remote's `pushurl`: of 23 ways of pushing to a GitLab host, 20 still
  reached it with the user's key or asked for an https identifier —
  `git+ssh://`, `ssh+git://`, `ssh://…:22/`, no user, another user, upper
  case, a trailing dot, `http://`, `https://…:443/`, any remote with an
  explicit pushurl (pushInsteadOf ignores it, and the https -> ssh rewrite
  turns `https://<host>/…` into `git@<host>:`), and `git send-pack`, which
  never reads pushInsteadOf. `dbt_git_setup` now adds three layers,
  idempotent and replayed on every start, removing nothing it did not write:
  (a) git's `core.sshCommand` is a new template-owned script,
  `.devcontainer/git-ssh-garde.sh`, run from its copy in
  `~/.local/libexec/` (a `git checkout` of an older commit, `just
  lock-checkout`, cannot take it away): to an upstream host only
  `git-upload-pack` and `git-upload-archive` with one quoted path go through
  — `git-receive-pack`, `git-lfs-authenticate`, a read followed by anything
  else are refused before ssh runs. The host is recognised by name — the
  destination, and what `ssh -G` reads from `~/.ssh/config` and the options:
  HostName, HostKeyAlias, the ProxyJump hops, the words of ProxyCommand, the
  CanonicalDomains suffixes — and, for a write, by address: every one of
  those names resolved by `getent ahosts`, an IPv4-mapped `::ffff:a.b.c.d`
  brought back to `a.b.c.d`, against the upstream hosts' addresses (an IP
  address in any writing, another name of the same server, a search domain);
  an upstream host that does not resolve makes an IP address refused (fail
  closed). A read without a terminal runs with `BatchMode=yes`. The pinned
  host keys ride along; every other host and git's `ssh -G` probe go to ssh
  unchanged.
  (b) an upstream host read over ssh gets no https: `http.https://<host>.proxy`
  and `http.http://<host>.proxy` are a dead proxy (`http://127.0.0.1:9`; the
  most specific urlmatch key wins whatever the order, so a general
  `http.proxy`, a reset of the credential helpers, a password in the URL or
  an `http.extraHeader` do not get round it), and behind it
  `credential.https://<host>.helper` = `""` then a quitter (`quit=1`): no
  other helper is asked, no prompt opens. An upstream read over https keeps
  its credentials and its proxy.
  (c) ten more `pushInsteadOf` prefixes per host, which still hold for
  `git push` (not `git send-pack`) when an exported `GIT_SSH_COMMAND`
  replaces the guard.
  A customised `core.sshCommand` is left as is and reported.
  `DBT_UPSTREAM_PUSH_LOCK=0` removes the three layers of its hosts (the
  pinned keys come back alone). `just doctor` checks each layer and proves it
  offline (ssh stubbed: a `git-receive-pack` to `git@<host>`, `jb@<HOST>`,
  `<host>.`, `git@[::ffff:<address>]` refused, a `git-upload-pack` let
  through; `git ls-remote https://…@<host>/…` and `http://…` meet the dead
  proxy on 127.0.0.1), checks the installed copy against the worktree's, and
  reports an exported `GIT_SSH_COMMAND` (❌), `GIT_SSH` (information only:
  git prefers `core.sshCommand`), `GIT_CONFIG_PARAMETERS` / `GIT_CONFIG_COUNT`
  touching the lock, `GIT_CONFIG_GLOBAL`, a `NO_PROXY` covering the host, a
  workspace-level `core.sshCommand`, proxy or credential helper.
  **Limits, said in the guard, the README and CLAUDE.md** — "no push by git"
  is not "no push": the key that can write stays available to every process
  (ssh outside git: a `git-receive-pack` typed by hand, gitlab-shell's
  `personal_access_token` then an https push with that token); a pure tunnel
  (`ssh -L`, socat to 127.0.0.1) without a HostKeyAlias naming the host, a
  shared `ControlPath`, https on another port; a deliberate override of git's
  configuration (`GIT_SSH_COMMAND`, `-c core.sshCommand=…`,
  `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, a repository's own
  `core.sshCommand`, `ext::` with `protocol.ext.allow=always`,
  `GIT_CONFIG_GLOBAL=/dev/null` or another `HOME`). Only a read-only access
  on the server covers those. Tests: the 23 forms one by one, one mutant per
  layer (and the lib-dbt.sh of before: 20 leaks), the guard by address and by
  ssh configuration (10 cases, one mutant per mechanism: the `::ffff:`
  normalisation, the resolution, HostKeyAlias, ProxyCommand, ProxyJump,
  CanonicalDomains, BatchMode), the dead proxy against six ways round the
  quitter, reads (ls-remote, fetch, clone, archive), GitHub untouched, the
  guard missing from the worktree, the doctor line by line — 113 more
  offline checks in `scripts/test-lib-dbt.sh` (539 in all).
- **`dbt-run.sh`: what the seal of global-v4's hook proof cannot see is
  refused there, and dbt can no longer load packages from elsewhere.** On
  global-v4's compile/show under a proof of its hooks, `--vars` (it overrides
  the vars of the sealed `dbt_project.yml`, elementary's `disable_*` among
  them), `--profile` and an exported `DBT_PROFILE` (another profile than the
  sealed one) are refused; parse, global/, the v2 worktrees and a v4/<product>
  without hooks still take `--vars`. Everywhere, `--packages-install-path`
  (and `=…`) and an exported `DBT_PACKAGES_INSTALL_PATH` are refused like
  `--project-dir`: the guard reads the hooks of `dbt_packages/` (and global-v4
  seals it), and dbt would have loaded other packages.
- **`dbt-run.sh` write guard: dbt can no longer be pointed at another project,
  and an env file can no longer change the guard.** `--project-dir` (and
  `--project-dir=…`) is refused like `--profiles-dir`, and an exported
  `DBT_PROJECT_DIR` is refused: the guard checks the destinations of the
  project it resolved, and dbt would have run a different one. Every env file
  `export_env` sources (`profiles/dbt.env`, `profiles/v4.env`,
  `profiles/env/<product>.env`) is compared before and after: one that adds or
  changes a `DBT_*` variable (`DBT_SANDBOX_NEVER_BUILD`, `DBT_HOOKS_REVIEWED`,
  `DBT_BQ_DATASET_PREFIX`, `DBT_PROFILES_DIR`…) is refused —
  `DBT_SEND_ANONYMOUS_USAGE_STATS` aside. No generated env file sets one.

- **The dbt engines are installed before the editor connects.** Both live in
  the container filesystem and were rebuilt by `postCreateCommand`, which runs
  once VS Code is already connected: after a rebuild, dbt Power User started
  first and failed with `Python bridge could not start: spawn
  /opt/dbt-v1/bin/python ENOENT` until the window was reloaded. A new
  `onCreateCommand` entry, `dbt-engines` (`lib-dbt.sh` → `dbt_engines`),
  installs uv if needed, then the dbt Core venv and dbt v2; post-create finds
  them up to date and skips them.
- **A v1 whose packages are incomplete gets `dbt deps` again on create.**
  The install was skipped as soon as `dbt_packages/` existed, but a failed
  deps (a private git host refusing the SSH key) leaves the hub packages
  there: no rebuild ever completed it, and dbt Power User kept reporting
  "found 3 package(s) specified in packages.yml, but only 2 package(s)
  installed". It now runs when fewer packages are installed than declared —
  the count dbt itself compares.
- **The write guard now sees the hooks of installed packages.** It only
  scanned the project's own files, so the on-run-start/end hooks that a
  package such as elementary declares in its `dbt_project.yml` went
  unnoticed. Commented-out lines (`# on-run-start:`) no longer count.
- **Hooks gate every command that executes them, per engine,** not only the
  writes. dbt Core runs them for its `RunTask` family — run, build, seed,
  snapshot, test, source freshness (read from dbt-core 1.11). dbt v2 also
  runs on-run-start hooks for compile and show (observed with 2.0.6). Until
  `DBT_HOOKS_REVIEWED=1`, those commands are refused, with the list of the
  files that declare hooks. A project whose packages are not installed yet is
  refused too: their hooks cannot be read (`just v1|v2 deps` first).
- `just doctor` gains a `[hooks]` section: where the hooks are, and which
  commands they block.
- **`just destinations` no longer counts the sandbox prefix as a move.** A v1
  faithful to upstream may not read `DATASET_PREFIX` while its v2 does, so
  every v2 node was reported « written elsewhere ». The comparison now strips
  the sandbox prefix (`DBT_BQ_DATASET_PREFIX`, `DATASET_PREFIX`, with or
  without its trailing `_`) on both sides; the listing still shows the real
  names, and case still counts (BigQuery datasets are case-sensitive).

### Changed

- `dbt-project` is not a Python package: the shared `pyproject.toml`, `src/`,
  `tests/`, `Dockerfile`, `.python-version` and CI workflow are skipped for it
  through a templated `_exclude` in `copier.yml`.
- Template-internal renames, without effect on rendered projects:
  `post-start.sh` is now a Jinja template, and `CLAUDE.md`, `README.md` and
  `justfile` each exist in two variants selected by a condition in their
  file name.

### Notes

- **No behaviour change for the existing types.** For `mcp-server`,
  `abap-project`, `fabric-pipeline` and `base`, every rendered file is
  byte-identical to v0.11.0, except `.devcontainer/README.md`, which gains
  the *dbt workspace* section.
- The official dbt extension has no folder filter and shares `Ctrl/Cmd+Enter`
  with dbt Power User. For one extension per window, open `v1/` or `v2/`
  alone; `lib-dbt.sh` seeds the settings for that in each worktree.

## [0.11.0] — 2026-09-29

### Added

- **One Claude account per container: copier question `claude_profile`
  (default empty).** Every container used to bind-mount the same host
  `~/.claude`, which holds the one `.credentials.json`. A `/login` in any
  container therefore switched **all** of them: running sessions watch that
  file and reload it when it changes. Answering a profile name (e.g.
  `sap-testing`) mounts the host dir `~/.claude-profiles/<profile>` on
  `/home/vscode/.claude` instead. The mount *target* is unchanged, so nothing
  else in the template moves (`PATH`, `claude-dirs`, scripts). The profile
  stays host-side: its login, chat history (`projects/<slug>/*.jsonl`,
  `history.jsonl`) and memory survive every rebuild, including without cache.
  `initializeCommand` creates the profile dir on the host first, because a
  missing bind source makes `docker run --mount` fail. Repos answering the same
  profile share its account. The name must match `^[a-z0-9][a-z0-9_-]{0,62}$`:
  no `..`, `/`, `,` or uppercase (APFS is case-insensitive).
- **The `~/.claude.json` restore (post-create step 3) becomes per-profile.**
  It restores the newest `~/.claude/backups/` entry. With a profile, those are
  the profile's own backups, instead of whichever container saved last
  (whatever its account).
- **`scripts/claude-profile-migrate.sh`** seeds a profile for one repo. It
  runs on the host with the container stopped, and is a dry run unless
  `--apply` is given. It only **copies** from `~/.claude`, which it never
  writes to:
  - user config (settings, skills, plugins…), when the profile lacks it;
  - the repo's `projects/<slug>/`: transcripts, subagents and memory, plus the
    `<session>/` artefacts its sessions left under worktree or subdirectory
    slugs. Ownership is decided by the recorded `cwd` and the session id, not
    by the lossy slug name;
  - its `history.jsonl` lines (merged, de-duplicated, sorted by timestamp);
  - its `file-history/`.

  It never copies `.credentials.json*`, `backups/`, `.device-keys.json` or
  runtime state, and it checks every copied file with `cmp`.
- **Tests.** New `scripts/test-claude-profile-migrate.sh`: 45 checks on a
  throwaway fake `~/.claude`, under POSIX `sh`/`dash`/`bash`.
  `scripts/test-template-render.sh` now also covers `claude_profile`:
  - empty: the legacy mount is byte-identical;
  - set: the profile mount and `initializeCommand` are present;
  - both renders are valid JSONC;
  - `../x` is rejected.

### Notes

- **No behaviour change unless you opt in.** With `claude_profile` empty, the
  rendered `devcontainer.json` and every script are byte-identical to v0.10.1.
  A `copier update` only touches `.copier-answers.yml` (new key
  `claude_profile: ''`) and the docs in `.devcontainer/README.md`.
- **Opting in an existing repo** (see `.devcontainer/README.md`, *Claude
  profiles*):
  1. run `copier update`, answering `claude_profile`, and commit;
  2. **close the window**, which stops the container;
  3. run `scripts/claude-profile-migrate.sh` on the host (dry run, then
     `--apply`);
  4. rebuild, then `/login` with the profile's account.

  Rebuilding before migrating shows an empty history. Nothing is lost: it is
  still in `~/.claude`, so migrate and rebuild again.
- A profile's first start finds no `~/.claude.json` backup, so onboarding,
  folder trust and `.mcp.json` approvals are asked once.
- To roll back, set `claude_profile` back to empty and rebuild: `~/.claude`
  was never modified.
- The sap-template root dev env itself keeps the shared `~/.claude`.

## [0.10.1] — 2026-07-01

### Fixed

- **`shutdownAction` is now `stopContainer` instead of `none`** in both the
  generated project's `.devcontainer/devcontainer.json` and the template's own
  root dev env. `none` kept the container running even after its VS Code
  window/project was **closed**, so containers from closed projects piled up and
  exhausted the Docker VM's RAM; the kernel OOM-killer then took down the active
  window's extension host, producing the recurring
  `command 'claude-vscode.terminal.open' not found` error. With `stopContainer`,
  a closed project releases its container, while an **open** project still keeps
  the container and its detached tmux session alive across window reloads,
  reconnects and host sleep (only a real close/quit stops it). The tmux terminal
  profile and all persistent-session settings are unchanged.

  Behavior change on `copier update`: existing projects re-render this file back
  to `stopContainer`; a container that was previously immortal will now stop when
  its window closes. Already-running immortal containers must be stopped once by
  hand (`docker ps` → `docker stop …`, or `docker container prune`). For a
  deliberately always-on service, run it as a plain `docker run` daemon rather
  than reverting to `none`.

## [0.10.0] — 2026-06-30

### Added

- **New `base` project type (`project_type: base`).** A neutral, cloud- and
  SAP-free socle: it ships the full common base (devcontainer + tmux/terminal
  hardening, uv/ruff/pytest tooling, `justfile`, CI) and a bare Python skeleton
  (`src/<slug>/` with a plain `main()` entry point, empty pydantic-settings
  `config.py`), but wires no SAP, Azure or MCP integration. Intended as a
  starting point for projects that will be specialised by hand (e.g. a GCP
  pipeline). Concretely, for `base`:
  - `pyproject.toml` depends only on `pydantic` / `pydantic-settings` /
    `python-dotenv`;
  - `.env.example` carries no `SAP_*` block, only `GITHUB_PERSONAL_ACCESS_TOKEN`;
  - `.mcp.json.example` has an empty `mcpServers`, and the (now templated)
    `.devcontainer/mcp-servers.conf` seeds **no** server, so nothing SAP runs;
  - `CLAUDE.md` / `README.md` drop the SAP/MCP sections;
  - CI emits no secret `env:` block.
- **`.devcontainer/mcp-servers.conf` is now rendered from a Jinja template**
  (`mcp-servers.conf.jinja`) so the seeded server set depends on
  `project_type`. It stays project-owned via `_skip_if_exists`, so existing
  projects are untouched on `copier update`.

## [0.9.0] — 2026-06-15

### Added

- **Optional, opt-in tmux config for Claude Code long sessions
  (`enable_tmux_claude_code_config`, default `false`).** When enabled, the
  generated project gets a standalone, source-it-yourself tmux snippet
  (`.config/tmux/claude-code.tmux.conf`) plus a guide
  (`docs/claude-code-tmux.md`) covering reliable scrolling, copy-mode
  (`Ctrl+b [` … `q`), the alternate-screen trade-off
  (`CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`) and `/tui fullscreen`. The snippet
  adds `mouse on`, `history-limit 50000`, `allow-passthrough on`,
  `extended-keys on` and `terminal-features 'xterm*:extkeys'`. It never touches
  the user's `~/.tmux.conf` — it is meant to be sourced manually
  (`tmux source-file …`). Disabled by default, so existing projects are
  unaffected until they opt in on their next `copier update`.
- **`scripts/test-template-render.sh`** — local smoke test that renders the
  template with the option off and on and asserts the conditional files appear
  (or not) and that the base render is unchanged.

## [0.8.18] — 2026-06-14

### Fixed

- **One tmux session per terminal tab — parallel Claude Code without
  mirroring.** `tmux-session.sh` previously used a fixed session name
  (`claude`): the first tab created it and every later tab *attached* to the
  same session, so two tabs mirrored each other (same window, pane and
  keystrokes) and you could not run several Claude Code instances in parallel.
  The launcher now treats `CLAUDE_TMUX_SESSION` as a session *prefix* (default
  `claude`) and:
  - gives every new tab its OWN session named `<prefix>-<pid>` (parallelism);
  - on revival after a window reload / VS Code restart / SSH drop, reattaches a
    DETACHED (orphaned) session of the prefix instead of creating a new one
    (persistence);
  - never reclaims a session that already has a live client
    (`session_attached != 0`), which is what kills the mirroring;
  - reclaims orphans atomically — `rename-session` acts as a lock, so on a
    multi-tab revival the first tab wins an orphan and the losers fall back to
    a fresh session (anti-race);
  - pushes the per-window VS Code IPC handles into the tmux server's GLOBAL
    environment (`setenv -g`) so new sessions inherit live sockets, and
    refreshes a reattached orphan in place (`setenv -t`).

  `devcontainer.json` terminal comment updated accordingly (sessions are now
  `claude-<pid>`; list/reattach with `tmux ls` then `tmux attach -t <name>`).

## [0.8.17] — 2026-06-13

### Added

- **Long-session stability for Claude Code in VS Code.** Marathon (multi-hour)
  Claude Code sessions now survive the events that used to kill the terminal
  process, and the extension "relaunch the terminal" prompt no longer
  interrupts a running session:
  - `.devcontainer/tmux-session.sh` (new, template-owned) — the integrated
    terminal's default profile now runs inside a persistent `tmux` session
    (`claude`). It survives window reload, full VS Code restart/revive,
    Remote-SSH disconnect and host sleep as long as the container is up;
    reattach with `tmux attach -t claude`. Forwards the per-window VS Code
    IPC env so `code`, git askpass and the Claude IDE link keep working on
    reattach, and falls back to a plain login shell if tmux is unavailable.
  - `devcontainer.json` terminal settings: `tmux`/`bash` profiles + a plain
    `automationProfile`; `environmentChangesRelaunch: false` (no extension
    can auto-relaunch/kill the terminal); `enablePersistentSessions: true`;
    `persistentSessionReviveProcess: onExitAndWindowClose`; larger
    `scrollback` (20000) and `persistentSessionScrollback` (1000);
    `python.terminal.activateEnvironment: false` + `python.envFile: ""` to
    stop the Python extension's env-collection churn (the relaunch trigger).
  - `devcontainer.json`: `shutdownAction: none` (the container — and the
    detached tmux session — survives closing the VS Code window) and
    `init: true` (tini reaps zombie background processes and avoids the
    process-group signal cascade that can crash Claude with exit 137).
  - `post-create.sh` installs `tmux`.

  Project-owned knobs that pair with this (not template-managed, set per
  project in `.claude/settings.json` `env` and `post-*-project.sh`):
  `BASH_DEFAULT_TIMEOUT_MS` / `BASH_MAX_TIMEOUT_MS`, `API_TIMEOUT_MS`,
  `MCP_TIMEOUT`, `MAX_MCP_OUTPUT_TOKENS`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`,
  `DISABLE_AUTOUPDATER`, and `NODE_OPTIONS=--max-old-space-size=4096`.

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
