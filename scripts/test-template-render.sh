#!/usr/bin/env bash
# =============================================================================
# test-template-render.sh — smoke test du rendu Copier
# -----------------------------------------------------------------------------
# Rend le template deux fois (option tmux OFF puis ON) et vérifie :
#   - OFF : ni .config/tmux/claude-code.tmux.conf ni docs/claude-code-tmux.md ;
#   - ON  : les deux fichiers présents, sans suffixe .jinja résiduel ;
#   - dans les deux cas : le rendu de base (README.md, .copier-answers.yml) est
#     généré et ne contient pas de marqueur Jinja non résolu.
# Puis claude_profile : vide = montage ~/.claude historique à l'identique ;
# renseigné = ~/.claude-profiles/<profil> monté et créé par initializeCommand ;
# devcontainer.json toujours valide (JSONC) ; un profil « ../x » est refusé.
# Puis project_type=dbt-project, et dbt-fleet (une flotte de produits) : pas
# de squelette Python, l'outillage dbt (lib-dbt.sh, git-ssh-garde.sh, dbt.conf, feature gcloud,
# hub de profils, products.conf et global/ pour la flotte) présent et valide,
# et rien de tout cela ne fuit dans les autres types.
# Puis secrets_source : env = rien de Key Vault (identité stricte avec une réf.
# antérieure si ENV_BASE_REF est donné) ; keyvault = lanceur, .env.refs sans
# valeur secrète, aucun `source .env`, scripts et JSON valides.
#
# Copier rend depuis une réf git : par défaut HEAD du repo courant. Les fichiers
# NON COMMITÉS ne sont pas pris en compte -> committez avant de tester, ou
# passez une réf : VCS_REF=ma-branche scripts/test-template-render.sh
#
# Usage :  scripts/test-template-render.sh
# Prérequis : copier (>=9), git.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
VCS_REF="${VCS_REF:-HEAD}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

# headings_ok FILE HEADING... : each heading starts its own line, after a blank line
headings_ok() {
  local f="$1" h; shift
  for h in "$@"; do
    grep -qx "$h" "$f" || return 1
    awk -v h="$h" '$0 == h { exit (prev != "") } { prev = $0 }' "$f" || return 1
  done
}

render() {  # render <enable_bool> <out_dir> [extra copier args...]
  local enable=$1 out=$2; shift 2
  copier copy --vcs-ref "$VCS_REF" --defaults --quiet \
    --data project_name=render-test \
    --data project_description="Render smoke test" \
    --data "enable_tmux_claude_code_config=$enable" \
    "$@" "$REPO_ROOT" "$out"
}

# devcontainer.json is JSONC: strip comments (outside strings), then parse.
jsonc_ok() {
  python3 - "$1" <<'PY'
import json, sys
s, out, i, in_str = open(sys.argv[1]).read(), [], 0, False
while i < len(s):
    c = s[i]
    if in_str:
        out.append(c)
        if c == '\\': out.append(s[i + 1]); i += 2; continue
        in_str = c != '"'; i += 1; continue
    if c == '"': in_str = True
    elif s.startswith('//', i):
        j = s.find('\n', i); i = len(s) if j < 0 else j; continue
    out.append(c); i += 1
json.loads(''.join(out))
PY
}

SNIPPET=".config/tmux/claude-code.tmux.conf"
DOC="docs/claude-code-tmux.md"

echo "== Rendu OFF (enable_tmux_claude_code_config=false) =="
if render false "$WORK/off"; then
  [ -e "$WORK/off/$SNIPPET" ] && bad "OFF: $SNIPPET ne devrait PAS exister" || pass "OFF: pas de snippet"
  [ -e "$WORK/off/$DOC" ]     && bad "OFF: $DOC ne devrait PAS exister"     || pass "OFF: pas de doc"
  [ -d "$WORK/off/.config" ]  && bad "OFF: .config/ ne devrait PAS exister (dir vide)" || pass "OFF: pas de .config/"
  [ -d "$WORK/off/docs" ]     && bad "OFF: docs/ ne devrait PAS exister (dir vide)"     || pass "OFF: pas de docs/"
  [ -f "$WORK/off/README.md" ] && pass "OFF: README.md généré" || bad "OFF: README.md manquant"
else
  bad "OFF: copier a échoué"
fi

echo "== Rendu ON (enable_tmux_claude_code_config=true) =="
if render true "$WORK/on"; then
  [ -f "$WORK/on/$SNIPPET" ] && pass "ON: $SNIPPET présent" || bad "ON: $SNIPPET manquant"
  [ -f "$WORK/on/$DOC" ]     && pass "ON: $DOC présent"     || bad "ON: $DOC manquant"
  # Aucun .jinja résiduel ni nom de fichier dégénéré (ex: un fichier nommé ".md")
  if find "$WORK/on" -name '*.jinja' | grep -q .; then
    bad "ON: suffixe .jinja résiduel"; find "$WORK/on" -name '*.jinja'
  else pass "ON: aucun .jinja résiduel"; fi
  # Contenu attendu dans le snippet : les 5 directives doivent toutes être là
  snippet_ok=1
  for directive in \
    'set -g mouse on' \
    'set -g history-limit 50000' \
    'set -g allow-passthrough on' \
    'set -s extended-keys on' \
    "set -as terminal-features 'xterm*:extkeys'"; do
    grep -qF "$directive" "$WORK/on/$SNIPPET" 2>/dev/null || { bad "ON: snippet manque « $directive »"; snippet_ok=0; }
  done
  [ "$snippet_ok" -eq 1 ] && pass "ON: snippet contient les 5 directives tmux"
  # Le projet name a bien été interpolé dans la doc
  grep -q "render-test" "$WORK/on/$DOC" 2>/dev/null \
    && pass "ON: doc interpolée (project_name)" || bad "ON: doc non interpolée"
else
  bad "ON: copier a échoué"
fi

DC=".devcontainer/devcontainer.json"
LEGACY_MOUNT='"source=${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind",'
LEGACY_INIT='"initializeCommand": "mkdir -p ${HOME}/.claude",'

echo "== claude_profile vide (rendu OFF) : montage historique, à l'identique =="
grep -qxF "    $LEGACY_MOUNT" "$WORK/off/$DC" && pass "OFF: montage ~/.claude historique" || bad "OFF: montage historique absent/modifié"
grep -qxF "  $LEGACY_INIT" "$WORK/off/$DC" && pass "OFF: initializeCommand historique" || bad "OFF: initializeCommand modifié"
grep -q 'claude-profiles' "$WORK/off/$DC" && bad "OFF: référence à .claude-profiles" || pass "OFF: aucune référence à .claude-profiles"
[ -e "$WORK/off/.devcontainer/claude-profile-host.sh" ] && bad "OFF: claude-profile-host.sh rendu sans profil" || pass "OFF: pas de claude-profile-host.sh sans profil"
[ -e "$WORK/off/.devcontainer/claude-profile-migrate.sh" ] && bad "OFF: claude-profile-migrate.sh rendu sans profil" || pass "OFF: pas de claude-profile-migrate.sh sans profil"
jsonc_ok "$WORK/off/$DC" && pass "OFF: devcontainer.json valide (JSONC)" || bad "OFF: devcontainer.json invalide"

echo "== claude_profile=render-profile : montage du profil =="
if render false "$WORK/prof" --data claude_profile=render-profile; then
  PROF_SRC='${localEnv:HOME}/.claude-profiles/render-profile'
  grep -qF "\"source=$PROF_SRC,target=/home/vscode/.claude,type=bind\"" "$WORK/prof/$DC" \
    && pass "PROFIL: ~/.claude-profiles/render-profile monté sur ~/.claude" || bad "PROFIL: montage du profil absent"
  grep -qF "\"initializeCommand\": \"mkdir -p \\\"$PROF_SRC\\\" && sh \\\"\${localWorkspaceFolder}/.devcontainer/claude-profile-host.sh\\\" \\\"render-profile\\\" \\\"\${localWorkspaceFolderBasename}\\\"\"" "$WORK/prof/$DC" \
    && pass "PROFIL: initializeCommand crée CE dossier puis lance claude-profile-host.sh (profil, dépôt)" || bad "PROFIL: initializeCommand incomplet"
  # claude-profile-host.sh, sur un faux HOME d'hôte : settings.json propre au container
  CPH="$WORK/prof/.devcontainer/claude-profile-host.sh"
  [ -f "$CPH" ] && sh -n "$CPH" && pass "PROFIL: claude-profile-host.sh présent, sh -n OK" || bad "PROFIL: claude-profile-host.sh absent ou invalide"
  hh="$WORK/hote"; pd="$hh/.claude-profiles/render-profile"
  mkdir -p "$hh/dotfiles/claude" "$hh/.claude"
  echo '{"model":"dotfiles"}' >"$hh/dotfiles/claude/settings.json"
  ln -s "$hh/dotfiles/claude/settings.json" "$hh/.claude/settings.json"
  HOME="$hh" sh "$CPH" render-profile >/dev/null; rc=$?
  [ "$rc" = 0 ] && [ -f "$pd/settings.json" ] && [ ! -L "$pd/settings.json" ] && grep -q dotfiles "$pd/settings.json" \
    && pass "PROFIL/host: profil neuf → settings.json créé depuis ~/.claude (lien suivi)" || bad "PROFIL/host: création du settings.json"
  echo '{"model":"opus","effortLevel":"high"}' >"$pd/settings.json"
  HOME="$hh" sh "$CPH" render-profile >/dev/null
  grep -q '"effortLevel":"high"' "$pd/settings.json" && pass "PROFIL/host: vrai fichier jamais touché (/model du container gardé)" || bad "PROFIL/host: settings.json du profil écrasé"
  rm "$pd/settings.json"; ln -s "$hh/dotfiles/claude/settings.json" "$pd/settings.json"
  HOME="$hh" sh "$CPH" render-profile >/dev/null
  [ ! -L "$pd/settings.json" ] && grep -q dotfiles "$pd/settings.json" && [ -L "$hh/.claude/settings.json" ] && grep -q dotfiles "$hh/dotfiles/claude/settings.json" \
    && pass "PROFIL/host: lien valide → copie de sa cible (dotfiles intacts)" || bad "PROFIL/host: lien valide mal traité"
  rm "$pd/settings.json"; ln -s /Users/absent/dotfiles/claude/settings.json "$pd/settings.json"
  HOME="$hh" sh "$CPH" render-profile >/dev/null
  [ ! -L "$pd/settings.json" ] && grep -q dotfiles "$pd/settings.json" && pass "PROFIL/host: lien cassé → retiré puis recréé depuis ~/.claude" || bad "PROFIL/host: lien cassé mal traité"
  rm -rf "$hh/.claude" "$pd"; HOME="$hh" sh "$CPH" render-profile >/dev/null
  [ "$(cat "$pd/settings.json" 2>/dev/null)" = "{}" ] && pass "PROFIL/host: sans ~/.claude → {}" || bad "PROFIL/host: pas de settings.json vide"
  HOME="$hh" sh "$CPH" ../x >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$hh/.claude-profiles/../x" ] && [ ! -e "$hh/x" ] && pass "PROFIL/host: profil « ../x » ignoré, sortie 0" || bad "PROFIL/host: « ../x » mal traité"
  # Migration automatique de l'historique (2e argument = dossier du dépôt)
  CPM="$WORK/prof/.devcontainer/claude-profile-migrate.sh"
  [ -f "$CPM" ] && [ ! -L "$CPM" ] && cmp -s "$CPM" "$REPO_ROOT/scripts/claude-profile-migrate.sh" \
    && pass "PROFIL: claude-profile-migrate.sh livré (vrai fichier = scripts/)" || bad "PROFIL: claude-profile-migrate.sh absent ou différent"
  hm="$WORK/hote-mig"; pm="$hm/.claude-profiles/render-profile"; sp="$hm/.claude/projects/-workspaces-repo-a"
  mkdir -p "$sp/memory" "$hm/.claude/projects/-workspaces-repo-b"
  printf '{"cwd":"/workspaces/repo-a","n":1}\n' >"$sp/s1.jsonl"
  printf '# mémoire\n' >"$sp/memory/MEMORY.md"
  printf '{"cwd":"/workspaces/repo-b"}\n' >"$hm/.claude/projects/-workspaces-repo-b/b1.jsonl"
  printf '{"display":"a","timestamp":1,"project":"/workspaces/repo-a"}\n{"display":"b","timestamp":2,"project":"/workspaces/repo-b"}\n' >"$hm/.claude/history.jsonl"
  printf '{}\n' >"$hm/.claude/settings.json"
  find "$hm/.claude" -exec touch -t 202001010000 {} +
  avant=$(cd "$hm/.claude" && find . -type f -exec cksum {} + | sort)
  out=$(HOME="$hm" CLAUDE_PROFILE_WAIT=0 sh "$CPH" render-profile repo-a 2>&1); rc=$?
  [ "$rc" = 0 ] && [ -f "$pm/projects/-workspaces-repo-a/s1.jsonl" ] && [ -f "$pm/projects/-workspaces-repo-a/memory/MEMORY.md" ] \
    && [ ! -e "$pm/projects/-workspaces-repo-b" ] && grep -q '"display":"a"' "$pm/history.jsonl" && ! grep -q '"display":"b"' "$pm/history.jsonl" \
    && [ -e "$pm/.migrated-repo-a" ] && echo "$out" | grep -q "migré" \
    && pass "MIGR: 1er démarrage → sessions, mémoire, historique de CE dépôt seulement, marqueur posé" \
    || bad "MIGR: 1er démarrage (rc=$rc) : $out"
  [ "$avant" = "$(cd "$hm/.claude" && find . -type f -exec cksum {} + | sort)" ] && pass "MIGR: ~/.claude de l'hôte inchangé" || bad "MIGR: ~/.claude de l'hôte modifié"
  printf '{"cwd":"/workspaces/repo-a","n":2}\n' >"$sp/s2.jsonl"; touch -t 202001010000 "$sp/s2.jsonl"
  HOME="$hm" sh "$CPH" render-profile repo-a >/dev/null 2>&1
  [ ! -e "$pm/projects/-workspaces-repo-a/s2.jsonl" ] && pass "MIGR: 2e démarrage → marqueur présent, rien de recopié" || bad "MIGR: migration rejouée malgré le marqueur"
  rm -f "$pm/.migrated-repo-a"; printf '{"cwd":"/workspaces/repo-a","n":"profil"}\n' >"$pm/projects/-workspaces-repo-a/s1.jsonl"
  find "$pm" -exec touch -t 202001010000 {} +   # profil au repos (aucun container ne l'écrit)
  HOME="$hm" sh "$CPH" render-profile repo-a >/dev/null 2>&1
  grep -q '"profil"' "$pm/projects/-workspaces-repo-a/s1.jsonl" && [ -f "$pm/projects/-workspaces-repo-a/s2.jsonl" ] && [ -e "$pm/.migrated-repo-a" ] \
    && pass "MIGR: profil déjà rempli → fusion, rien d'écrasé" || bad "MIGR: fusion incorrecte"
  rm -rf "$pm"; touch "$sp/s1.jsonl"
  out=$(HOME="$hm" CLAUDE_PROFILE_WAIT=0 sh "$CPH" render-profile repo-a 2>&1); rc=$?
  [ "$rc" = 0 ] && [ ! -e "$pm/.migrated-repo-a" ] && echo "$out" | grep -q "attente" && echo "$out" | grep -q "nouvel essai" && grep -q "stop the container" "$pm/.migrate-repo-a.log" \
    && pass "MIGR: session encore active → attente, puis report au démarrage suivant (sortie 0, pas de marqueur)" || bad "MIGR: session active mal traitée (rc=$rc) : $out"
  touch -t 202001010000 "$sp/s1.jsonl"
  HOME="$hm" sh "$CPH" render-profile repo-a >/dev/null 2>&1
  [ -e "$pm/.migrated-repo-a" ] && [ -f "$pm/projects/-workspaces-repo-a/s1.jsonl" ] && pass "MIGR: démarrage suivant → migré" || bad "MIGR: pas de reprise après report"
  rm -f "$pm/.migrated-repo-a"; touch "$pm/history.jsonl"
  out=$(HOME="$hm" CLAUDE_PROFILE_WAIT=0 sh "$CPH" render-profile repo-a 2>&1)
  [ ! -e "$pm/.migrated-repo-a" ] && echo "$out" | grep -q "attente" && echo "$out" | grep -q "nouvel essai" \
    && pass "MIGR: profil écrit à l'instant (sap-excel) → attente puis report" || bad "MIGR: profil vivant mal traité : $out"
  touch -t 202001010000 "$pm/history.jsonl"; HOME="$hm" sh "$CPH" render-profile repo-a >/dev/null 2>&1
  [ -e "$pm/.migrated-repo-a" ] && pass "MIGR: profil au repos → fusion faite" || bad "MIGR: pas de fusion après report"
  rm -rf "$pm"; HOME="$hm" sh "$CPH" render-profile >/dev/null 2>&1
  [ ! -e "$pm/projects" ] && [ -f "$pm/settings.json" ] && pass "MIGR: sans 2e argument (ancien devcontainer.json) → pas de migration" || bad "MIGR: migration sans dépôt"
  HOME="$hm" sh "$CPH" render-profile ../x >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$pm/projects" ] && pass "MIGR: dépôt « ../x » ignoré" || bad "MIGR: dépôt « ../x » accepté"
  [ "$(stat -c %a "$pm")" = 700 ] && pass "MIGR: dossier du profil en 700 sur l'hôte" || bad "MIGR: profil en $(stat -c %a "$pm")"
  rm -f "$pm/.migrated-repo-a"; mkdir -p "$hm/.claude/plugins" "$pm/plugins/marketplaces"
  printf '{"version":2,"plugins":{}}\n' >"$hm/.claude/plugins/installed_plugins.json"; find "$hm/.claude" "$pm" -exec touch -t 202001010000 {} +
  HOME="$hm" sh "$CPH" render-profile repo-a >/dev/null 2>&1
  grep -q 'plugins installed on the host are NOT in the profile' "$pm/.migrate-repo-a.log" && [ ! -e "$pm/plugins/installed_plugins.json" ] \
    && pass "MIGR: plugins/ du profil gardé → avertissement dans le journal" || bad "MIGR: pas d'avertissement plugins"
  grep -q '== Done' "$pm/.migrate-repo-a.log" && ! grep -q 'Next:' "$pm/.migrate-repo-a.log" \
    && pass "MIGR: journal auto sans « Next: copier update … »" || bad "MIGR: journal auto : « Next » présent ou « Done » absent"
  rm -rf "$hm/.claude/plugins"
  rm -rf "$pm"; mkdir -p "$pm"; : >"$pm/.migrated-repo-a"
  HOME="$hm" sh "$CPH" render-profile repo-a >/dev/null 2>&1
  [ ! -e "$pm/projects" ] && pass "MIGR: marqueur posé à la main → jamais migré" || bad "MIGR: marqueur manuel ignoré"
  grep -qF "$LEGACY_MOUNT" "$WORK/prof/$DC" && bad "PROFIL: le ~/.claude partagé est encore monté" || pass "PROFIL: ~/.claude partagé non monté"
  jsonc_ok "$WORK/prof/$DC" && pass "PROFIL: devcontainer.json valide (JSONC)" || bad "PROFIL: devcontainer.json invalide"
else
  bad "PROFIL: copier a échoué"
fi
if render false "$WORK/node24" --data node_version=24 >/dev/null 2>&1; then
  [ "$(cat "$WORK/node24/.nvmrc")" = 24 ] && grep -qF '"ghcr.io/devcontainers/features/node:1": { "version": "24" },' "$WORK/node24/$DC" && jsonc_ok "$WORK/node24/$DC" \
    && pass "NODE: node_version=24 → .nvmrc et feature node à 24" || bad "NODE: node_version=24 mal rendu"
else bad "NODE: rendu node_version=24 échoué"; fi
if render false "$WORK/nodebad" --data node_version=latest >/dev/null 2>&1; then bad "NODE: « latest » accepté"; else pass "NODE: « latest » refusé (version majeure exigée)"; fi
if render false "$WORK/badprof" --data 'claude_profile=../x' >/dev/null 2>&1; then
  bad "PROFIL: '../x' accepté (traversée de chemin)"
else
  pass "PROFIL: '../x' refusé par le validateur"
fi

echo "== project_type=dbt-project : reprise dbt (v1 + v2) =="
DBT_URL='git@git.example.com:data/my-dwh.git'
if render false "$WORK/dbt" --data project_type=dbt-project --data "upstream_repo_url=$DBT_URL" \
     --data upstream_branch=prod --data dbt_project_subdir=dbt \
     --data bq_sandbox_project=sandbox-prj --data bq_sandbox_dataset=JDOE_run \
     --data bq_dataset_prefix=JDOE --data dbt_target_name=prd; then
  D="$WORK/dbt"
  # le type n'est pas un package Python : la racine ne porte que l'outillage
  for absent in pyproject.toml .python-version Dockerfile src tests .github; do
    [ -e "$D/$absent" ] && bad "DBT: $absent ne devrait PAS exister" || pass "DBT: pas de $absent"
  done
  if find "$D" -type d -empty | grep -q .; then bad "DBT: dossier vide généré"; find "$D" -type d -empty; else pass "DBT: aucun dossier vide"; fi
  for present in .devcontainer/lib-dbt.sh .devcontainer/dbt-run.sh .devcontainer/dbt-doctor.sh .devcontainer/git-ssh-garde.sh \
                 .devcontainer/dbt.conf .devcontainer/features/google-cloud-cli/devcontainer-feature.json \
                 .devcontainer/lib-mcp.sh .devcontainer/mcp-servers.conf .ignore profiles/dbt.env \
                 justfile CLAUDE.md README.md .env.example; do
    [ -f "$D/$present" ] && pass "DBT: $present présent" || bad "DBT: $present manquant"
  done
  [ -x "$D/.devcontainer/features/google-cloud-cli/install.sh" ] \
    && pass "DBT: install.sh du feature gcloud exécutable" || bad "DBT: install.sh du feature gcloud non exécutable"
  sh_ok=1
  for f in "$D"/.devcontainer/*.sh "$D"/.devcontainer/features/google-cloud-cli/install.sh; do
    bash -n "$f" 2>/dev/null || { bad "DBT: erreur de syntaxe bash dans ${f#"$D"/}"; sh_ok=0; }
  done
  [ "$sh_ok" -eq 1 ] && pass "DBT: tous les scripts passent bash -n"

  # le manifeste du projet porte les réponses copier
  conf_ok=1
  for line in "DBT_UPSTREAM_URL=\"$DBT_URL\"" 'DBT_UPSTREAM_BRANCH="prod"' 'DBT_PROJECT_SUBDIR="dbt"' \
              'DBT_BQ_PROJECT="sandbox-prj"' 'DBT_BQ_DATASET="JDOE_run"' 'DBT_BQ_DATASET_PREFIX="JDOE"' \
              'DBT_BQ_LOCATION="EU"' 'DBT_TARGET_NAME="prd"' 'DBT_UPSTREAM_PUSH_LOCK=1'; do
    grep -qxF "$line" "$D/.devcontainer/dbt.conf" || { bad "DBT: dbt.conf manque « $line »"; conf_ok=0; }
  done
  [ "$conf_ok" -eq 1 ] && pass "DBT: dbt.conf amorcé depuis les réponses (push verrouillé par défaut)"
  ( set -u; . "$D/.devcontainer/dbt.conf" ) 2>/dev/null && pass "DBT: dbt.conf est du shell valide" || bad "DBT: dbt.conf non sourçable"

  # devcontainer.json : gcloud côté hôte, verrou du hub de profils, les deux extensions
  jsonc_ok "$D/$DC" && pass "DBT: devcontainer.json valide (JSONC)" || bad "DBT: devcontainer.json invalide"
  grep -qF '"source=${localEnv:HOME}/.config/gcloud,target=/home/vscode/.config/gcloud,type=bind"' "$D/$DC" \
    && pass "DBT: ~/.config/gcloud de l'hôte monté" || bad "DBT: montage gcloud absent"
  grep -qxF '  "initializeCommand": "mkdir -p ${HOME}/.claude ${HOME}/.config/gcloud",' "$D/$DC" \
    && pass "DBT: initializeCommand crée aussi la source du montage gcloud" || bad "DBT: initializeCommand ne crée pas ~/.config/gcloud"
  grep -qF '"./features/google-cloud-cli": {}' "$D/$DC" && pass "DBT: feature gcloud LOCAL" || bad "DBT: feature gcloud absent"
  grep -qE '^[[:space:]]*"ghcr\.io/dhoeric' "$D/$DC" && bad "DBT: feature dhoeric (abandonné) référencé" || pass "DBT: pas de feature dhoeric"
  grep -qF '"DBT_PROFILES_DIR": "${containerWorkspaceFolder}/profiles",' "$D/$DC" \
    && pass "DBT: DBT_PROFILES_DIR dans containerEnv (tous les processus)" || bad "DBT: verrou du hub absent de containerEnv"
  grep -qF '"dbtLabsInc.dbt",' "$D/$DC" && grep -qF '"innoverio.vscode-dbt-power-user",' "$D/$DC" \
    && pass "DBT: extension officielle + dbt Power User" || bad "DBT: extensions dbt absentes"
  grep -qF '"redhat.vscode-yaml"' "$D/$DC" && bad "DBT: redhat.vscode-yaml installé (déconseillé avec l'extension dbt)" || pass "DBT: pas de redhat.vscode-yaml"
  grep -qF '"dbt.dbtPythonPathOverride": "/opt/dbt-v1/bin/python",' "$D/$DC" \
    && pass "DBT: dbt Power User branché sur le venv dbt Core" || bad "DBT: dbt.dbtPythonPathOverride absent"
  python3 -c "import json,sys; d=json.load(open('$D/.vscode/settings.json')); sys.exit(0 if d['dbt.allowListFolders']==['v1'] and d['dbt.dbtMajorVersion']=='v2' else 1)" \
    && pass "DBT: .vscode/settings.json — Power User cantonné à v1/" || bad "DBT: .vscode/settings.json inattendu"

  # les hooks appellent le cycle de vie dbt, après les serveurs MCP
  grep -qF 'dbt_process "$WORKSPACE_DIR" create' "$D/.devcontainer/post-create.sh" && pass "DBT: post-create lance le cycle dbt" || bad "DBT: post-create sans cycle dbt"
  grep -qF 'dbt_process "$WORKSPACE_DIR" start' "$D/.devcontainer/post-start.sh" && pass "DBT: post-start rejoue le cycle dbt (self-healing)" || bad "DBT: post-start sans cycle dbt"

  # v1/ et v2/ : ignorés par git, rendus aux outils de recherche
  grep -qxF '/v1/' "$D/.gitignore" && grep -qxF '/v2/' "$D/.gitignore" && pass "DBT: .gitignore ignore v1/ et v2/" || bad "DBT: .gitignore n'ignore pas les worktrees"
  grep -qxF '!/v1/' "$D/.ignore" && grep -qxF '!/v2/' "$D/.ignore" && pass "DBT: .ignore les rend à ripgrep" || bad "DBT: .ignore incomplet"

  # MCP : SAP ADT seul (pas de VM SAP GUI)
  python3 -c "import json,sys; d=json.load(open('$D/.mcp.json.example'))['mcpServers']; sys.exit(0 if list(d)==['sap-adt-mcp'] else 1)" \
    && pass "DBT: .mcp.json.example — sap-adt-mcp seul" || bad "DBT: .mcp.json.example inattendu"
  grep -q '^sap-adt-mcp ' "$D/.devcontainer/mcp-servers.conf" && pass "DBT: sap-adt-mcp dans mcp-servers.conf" || bad "DBT: sap-adt-mcp non semé"
  grep -q "$DBT_URL" "$D/CLAUDE.md" && grep -q 'v1/dbt/' "$D/CLAUDE.md" && pass "DBT: CLAUDE.md interpolé (origine, dossier du projet)" || bad "DBT: CLAUDE.md non interpolé"
  grep -q '^## Coordination' "$D/CLAUDE.md" && bad "DBT: section Coordination sans coordinateur" || pass "DBT: produit autonome — pas de section Coordination"
  headings_ok "$D/CLAUDE.md" '## Règles absolues' && pass "DBT: …et « Règles absolues » reste un titre à part entière" || bad "DBT: titre « Règles absolues » collé ($(grep -n 'Règles absolues' "$D/CLAUDE.md" | head -1))"
  if grep -rlE '\{\{|\{%' "$D" 2>/dev/null | grep -q .; then
    bad "DBT: marqueurs Jinja non résolus :"; grep -rlE '\{\{|\{%' "$D"
  else pass "DBT: aucun marqueur Jinja non résolu (tous fichiers)"; fi
else
  bad "DBT: copier a échoué"
fi
COORD='https://github.com/acme/my-fleet'
if render false "$WORK/dbt-coord" --data project_type=dbt-project --data "upstream_repo_url=$DBT_URL" \
     --data "fleet_coordinator=$COORD" >/dev/null 2>&1; then
  D="$WORK/dbt-coord"
  grep -q '^## Coordination' "$D/CLAUDE.md" && grep -qF "$COORD" "$D/CLAUDE.md" \
    && pass "DBT: produit d'une flotte — section Coordination, coordinateur nommé" || bad "DBT: section Coordination absente"
  grep -q 'global/' "$D/CLAUDE.md" && grep -q 'products.lock' "$D/CLAUDE.md" \
    && pass "DBT: …rôle (global/) et mécanique (verrou) expliqués" || bad "DBT: Coordination incomplète"
  awk '/^## Coordination/{c=NR} /^## Règles absolues/{r=NR} END{exit !(c && r && c < r)}' "$D/CLAUDE.md" \
    && pass "DBT: …avant les règles absolues" || bad "DBT: Coordination mal placée"
  headings_ok "$D/CLAUDE.md" '## Coordination — ce produit fait partie d'"'"'une flotte' '## Règles absolues' \
    && pass "DBT: …titres séparés de ce qui précède par une ligne vide" || bad "DBT: titres collés autour de Coordination"
  awk '/^Ce produit est suivi par un coordinateur/{ exit (prev != "") } { prev = $0 }' "$D/README.md" && grep -qx '## Prérequis sur l.hôte' "$D/README.md" \
    && pass "DBT: …README : paragraphe et titre suivant bien séparés" || bad "DBT: README mal découpé autour du coordinateur"
  grep -qF "$COORD" "$D/README.md" && pass "DBT: README renvoie au coordinateur" || bad "DBT: README sans coordinateur"
  grep -qF "fleet_coordinator: '$COORD'" "$D/.copier-answers.yml" && pass "DBT: fleet_coordinator mémorisé (copier update le garde)" || bad "DBT: fleet_coordinator non mémorisé"
  if grep -rlE '\{\{|\{%' "$D" 2>/dev/null | grep -q .; then bad "DBT: marqueurs Jinja non résolus (coordination)"; else pass "DBT: aucun marqueur Jinja non résolu (coordination)"; fi
else
  bad "DBT: copier a échoué (fleet_coordinator)"
fi
if render false "$WORK/dbt-nourl" --data project_type=dbt-project >/dev/null 2>&1; then
  bad "DBT: rendu accepté sans upstream_repo_url"
else
  pass "DBT: upstream_repo_url obligatoire"
fi
if render false "$WORK/dbt-badsub" --data project_type=dbt-project --data "upstream_repo_url=$DBT_URL" --data 'dbt_project_subdir=../x' >/dev/null 2>&1; then
  bad "DBT: dbt_project_subdir « ../x » accepté"
else
  pass "DBT: dbt_project_subdir « ../x » refusé"
fi

echo "== project_type=dbt-fleet : flotte de data products (v1 commune, v2, global) =="
if render false "$WORK/fleet" --data project_type=dbt-fleet \
     --data bq_sandbox_project=sandbox-prj --data bq_sandbox_dataset=JDOE_run \
     --data bq_dataset_prefix=JDOE --data dbt_target_name=prd; then
  D="$WORK/fleet"
  for absent in pyproject.toml .python-version Dockerfile src tests .github; do
    [ -e "$D/$absent" ] && bad "FLEET: $absent ne devrait PAS exister" || pass "FLEET: pas de $absent"
  done
  for present in .devcontainer/lib-dbt.sh .devcontainer/dbt-run.sh .devcontainer/dbt-doctor.sh .devcontainer/git-ssh-garde.sh \
                 .devcontainer/dbt.conf .devcontainer/products.conf \
                 .devcontainer/features/google-cloud-cli/install.sh .ignore profiles/dbt.env \
                 global/dbt_project.yml global/packages.yml global/macros/generate_schema_name.sql \
                 global/.gitignore justfile CLAUDE.md README.md; do
    [ -f "$D/$present" ] && pass "FLEET: $present présent" || bad "FLEET: $present manquant"
  done
  grep -qxF 'DBT_FLEET=1' "$D/.devcontainer/dbt.conf" && pass "FLEET: dbt.conf en mode flotte" || bad "FLEET: DBT_FLEET absent"
  grep -qxF 'DBT_V1_PINS="dbt-core==1.11.11 dbt-bigquery==1.11.1"' "$D/.devcontainer/dbt.conf" && pass "FLEET: version dbt Core commune par défaut" || bad "FLEET: DBT_V1_PINS inattendu"
  grep -q '^DBT_UPSTREAM_URL' "$D/.devcontainer/dbt.conf" && bad "FLEET: DBT_UPSTREAM_URL ne devrait pas exister (products.conf)" || pass "FLEET: pas d'upstream unique dans dbt.conf"
  ( set -u; . "$D/.devcontainer/dbt.conf" ) 2>/dev/null && pass "FLEET: dbt.conf est du shell valide" || bad "FLEET: dbt.conf non sourçable"
  [ -z "$(sed -e 's/#.*//' "$D/.devcontainer/products.conf" | awk 'NF')" ] && pass "FLEET: products.conf amorcé sans produit actif" || bad "FLEET: products.conf contient un produit"
  grep -qxF '  # >>> products (managed by .devcontainer/lib-dbt.sh from products.conf — edit products.conf, not this block) >>>' "$D/global/packages.yml" \
    && pass "FLEET: global/packages.yml porte le bloc géré" || bad "FLEET: bloc géré absent de global/packages.yml"
  grep -qx 'name: render_test' "$D/global/dbt_project.yml" && grep -qx 'profile: render-test' "$D/global/dbt_project.yml" \
    && pass "FLEET: global/dbt_project.yml interpolé (nom, profil)" || bad "FLEET: global/dbt_project.yml non interpolé"
  jsonc_ok "$D/$DC" && pass "FLEET: devcontainer.json valide (JSONC)" || bad "FLEET: devcontainer.json invalide"
  grep -qF '"./features/google-cloud-cli": {}' "$D/$DC" && grep -qF '"DBT_PROFILES_DIR": "${containerWorkspaceFolder}/profiles",' "$D/$DC" \
    && grep -qF '"dbtLabsInc.dbt",' "$D/$DC" && pass "FLEET: gcloud, hub de profils et extensions dbt" || bad "FLEET: devcontainer.json incomplet"
  python3 -c "import json,sys; d=json.load(open('$D/.vscode/settings.json')); w=d['files.watcherExclude']; sys.exit(0 if d['dbt.allowListFolders']==['v1'] and w.get('**/global/dbt_packages/**') else 1)" \
    && pass "FLEET: settings — Power User sur v1/, liens de global/dbt_packages non surveillés" || bad "FLEET: .vscode/settings.json inattendu"
  grep -q 'dbt_workspace' "$D/.copier-answers.yml" && bad "FLEET: la variable calculée dbt_workspace est enregistrée" || pass "FLEET: dbt_workspace (calculée) absente des réponses"
  grep -q 'just product-add' "$D/justfile" && grep -q '^v1 product \*args:' "$D/justfile" && pass "FLEET: justfile de flotte (product-add, v1 <produit>)" || bad "FLEET: justfile de flotte inattendu"
  grep -q 'dbt-fleet' "$D/CLAUDE.md" && grep -q 'global/' "$D/CLAUDE.md" && pass "FLEET: CLAUDE.md de flotte" || bad "FLEET: CLAUDE.md inattendu"
  sh_ok=1
  for f in "$D"/.devcontainer/*.sh; do bash -n "$f" 2>/dev/null || { bad "FLEET: erreur de syntaxe dans ${f#"$D"/}"; sh_ok=0; }; done
  [ "$sh_ok" -eq 1 ] && pass "FLEET: tous les scripts passent bash -n"
  if grep -rlE '\{\{|\{%' "$D" --exclude='generate_schema_name.sql' 2>/dev/null | grep -q .; then
    bad "FLEET: marqueurs Jinja non résolus :"; grep -rlE '\{\{|\{%' "$D" --exclude='generate_schema_name.sql'
  else pass "FLEET: aucun marqueur Jinja non résolu (hors macro dbt, Jinja par nature)"; fi
else
  bad "FLEET: copier a échoué"
fi
grep -q 'dbt_workspace' "$WORK/off/.copier-answers.yml" && bad "OFF: dbt_workspace enregistrée dans les réponses" || pass "OFF: dbt_workspace absente des réponses"
for leak in .devcontainer/products.conf global; do
  [ -e "$WORK/dbt/$leak" ] && bad "DBT: $leak (flotte) ne devrait PAS exister en dbt-project" || pass "DBT: pas de $leak"
done

echo "== Les autres types n'héritent de rien du type dbt-project (rendu OFF = mcp-server) =="
for leak in .devcontainer/lib-dbt.sh .devcontainer/dbt-run.sh .devcontainer/dbt-doctor.sh .devcontainer/git-ssh-garde.sh .devcontainer/dbt.conf \
            .devcontainer/features .ignore profiles; do
  [ -e "$WORK/off/$leak" ] && bad "OFF: $leak ne devrait PAS exister" || pass "OFF: pas de $leak"
done
grep -qiE 'gcloud|DBT_|dbtLabs|power-user' "$WORK/off/$DC" && bad "OFF: devcontainer.json référence dbt/gcloud" || pass "OFF: devcontainer.json sans dbt ni gcloud"
grep -q 'lib-dbt' "$WORK/off/.devcontainer/post-create.sh" "$WORK/off/.devcontainer/post-start.sh" \
  && bad "OFF: les hooks référencent lib-dbt.sh" || pass "OFF: hooks sans cycle dbt"
for kept in pyproject.toml Dockerfile src/render_test/__init__.py tests/__init__.py .github/workflows/ci.yml CLAUDE.md README.md justfile; do
  [ -f "$WORK/off/$kept" ] && pass "OFF: $kept toujours généré" || bad "OFF: $kept a disparu"
done

echo "== secrets_source=env (défaut) : rien de Key Vault =="
grep -q 'secrets_source: env' "$WORK/off/.copier-answers.yml" && pass "ENV: secrets_source=env enregistré" || bad "ENV: secrets_source absent des réponses"
for leak in .env.refs .devcontainer/lib-secrets.sh .devcontainer/secrets; do
  [ -e "$WORK/off/$leak" ] && bad "ENV: $leak ne devrait PAS exister" || pass "ENV: pas de $leak"
done
grep -qE 'AZURE_CONFIG_DIR|azure-profils|azure-cli' "$WORK/off/$DC" && bad "ENV: devcontainer.json référence Key Vault/az" || pass "ENV: devcontainer.json sans az ni volume"
grep -q 'source "$WORKSPACE_DIR/.env"' "$WORK/off/.devcontainer/post-start.sh" && pass "ENV: post-start lit toujours .env" || bad "ENV: post-start ne lit plus .env"
grep -qE 'nuget|dotnet' "$WORK/off/$DC" && bad "ENV: devcontainer.json référence .NET sans enable_dotnet" || pass "ENV: pas de .NET sans enable_dotnet"
grep -qE 'Key Vault|\.env\.refs|post-start\.log|relance-mcp' "$WORK/off/.devcontainer/README.md" "$WORK/off/.devcontainer/lib-mcp.sh" "$WORK/off/.devcontainer/post-start.sh" \
  && bad "ENV: doc ou scripts parlent de Key Vault" || pass "ENV: doc et scripts sans Key Vault"
# Identité stricte avec une réf. antérieure (opt-in : ENV_BASE_REF=origin/main) :
# en mode env, le rendu ne doit différer QUE par .copier-answers.yml.
if [ -n "${ENV_BASE_REF:-}" ]; then
  copier copy --vcs-ref "$ENV_BASE_REF" --defaults --quiet --data project_name=render-test \
    --data project_description="Render smoke test" --data enable_tmux_claude_code_config=false \
    "$REPO_ROOT" "$WORK/envbase" >/dev/null 2>&1
  # Différences VOULUES pour tous les projets (v0.12.0), et rien d'autre :
  #  - .nvmrc (nouveau) et la version de la feature node (node_version) ;
  #  - .devcontainer/README.md : des lignes AJOUTÉES seulement (étape 7).
  d="$(diff -rq "$WORK/envbase" "$WORK/off" | grep -v 'copier-answers' \
        | grep -vxF "Only in $WORK/off: .nvmrc" \
        | grep -vxF "Files $WORK/envbase/$DC and $WORK/off/$DC differ" \
        | grep -vxF "Files $WORK/envbase/.devcontainer/README.md and $WORK/off/.devcontainer/README.md differ" \
        | grep -vxF "Files $WORK/envbase/.devcontainer/post-start.sh and $WORK/off/.devcontainer/post-start.sh differ" \
        | grep -vE "^Only in $WORK/off/.devcontainer: (lib-tunnels\.sh|tunnel\.sh|mcp-instance\.sh|tunnels\.conf|tunnels\.known_hosts|mcp-instances\.conf)$" || true)"
  [ -z "$d" ] && pass "ENV: rendu identique à $ENV_BASE_REF hors différences voulues (.nvmrc, node, README, tunnels, instances)" || { bad "ENV: le rendu diffère de $ENV_BASE_REF :"; echo "$d"; }
  moins="$(diff "$WORK/envbase/$DC" "$WORK/off/$DC" | sed -n 's/^< *//p')"
  plus="$(diff "$WORK/envbase/$DC" "$WORK/off/$DC" | sed -n 's/^> *//p' | grep -v '^//' || true)"
  [ "$moins" = '"ghcr.io/devcontainers/features/node:1": {},' ] && [ "$plus" = '"ghcr.io/devcontainers/features/node:1": { "version": "22" },' ] \
    && pass "ENV: devcontainer.json ne change que par la version de node (22) et son commentaire" || { bad "ENV: devcontainer.json change autrement :"; diff "$WORK/envbase/$DC" "$WORK/off/$DC"; }
  diff "$WORK/envbase/.devcontainer/README.md" "$WORK/off/.devcontainer/README.md" | grep -q '^<' && bad "ENV: README : des lignes retirées ou modifiées" || pass "ENV: README : des ajouts seulement"
  diff "$WORK/envbase/.devcontainer/post-start.sh" "$WORK/off/.devcontainer/post-start.sh" | grep -q '^<' && bad "ENV: post-start.sh : des lignes retirées ou modifiées" || pass "ENV: post-start.sh : des ajouts seulement (tunnels, instances)"
  [ "$(cat "$WORK/off/.nvmrc")" = 22 ] && pass "ENV: .nvmrc = 22 (node_version par défaut)" || bad "ENV: .nvmrc = $(cat "$WORK/off/.nvmrc")"
else
  echo "  (identité stricte avec une réf. antérieure : ENV_BASE_REF=<réf> pour l'activer)"
fi

kv_checks() {  # kv_checks LABEL DIR
  local L="$1" D="$2" f sh_ok=1 bad_refs
  for f in .env.refs .env.example .devcontainer/lib-secrets.sh .devcontainer/secrets/personnes.conf \
           .devcontainer/secrets/SOURCE; do
    [ -f "$D/$f" ] && pass "$L: $f présent" || bad "$L: $f absent"
  done
  for f in secrets git-credential-secrets; do
    [ -x "$D/.devcontainer/secrets/$f" ] && pass "$L: secrets/$f exécutable" || bad "$L: secrets/$f absent ou non exécutable"
  done
  for f in "$D"/.devcontainer/*.sh "$D/.devcontainer/secrets/secrets" "$D/.devcontainer/secrets/git-credential-secrets"; do
    bash -n "$f" 2>/dev/null || { bad "$L: erreur de syntaxe dans ${f#"$D"/}"; sh_ok=0; }
  done
  [ "$sh_ok" -eq 1 ] && pass "$L: tous les scripts passent bash -n"
  jsonc_ok "$D/$DC" && pass "$L: devcontainer.json valide (JSONC)" || bad "$L: devcontainer.json invalide"
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$D/.mcp.json.example" 2>/dev/null \
    && pass "$L: .mcp.json.example valide" || bad "$L: .mcp.json.example invalide"
  [ "$(grep -c 'features/azure-cli' "$D/$DC")" = 1 ] && pass "$L: feature azure-cli (une fois)" || bad "$L: feature azure-cli absente ou en double"
  grep -q '"AZURE_CONFIG_DIR": "/home/vscode/.azure-profils/defaut"' "$D/$DC" && grep -q 'target=/home/vscode/.azure-profils,type=volume' "$D/$DC" \
    && pass "$L: sessions az dans un volume (AZURE_CONFIG_DIR)" || bad "$L: volume/AZURE_CONFIG_DIR manquant"
  if grep -rnE '(source|\.)[[:space:]]+[^#]*\.env"?[[:space:]]*(;|$)' "$D/.devcontainer" | grep -q .; then
    bad "$L: un script lit encore .env :"; grep -rnE '(source|\.)[[:space:]]+[^#]*\.env"?[[:space:]]*(;|$)' "$D/.devcontainer"
  else pass "$L: aucun source .env dans .devcontainer/"; fi
  grep -q 'secrets_override_mcp_link_env' "$D/.devcontainer/post-start.sh" && pass "$L: serveurs MCP sans lien .env" || bad "$L: lien .env des serveurs MCP non neutralisé"
  # .env.refs : chaque référence est bien formée, et aucune variable « secrète » n'a de valeur en clair
  bad_refs="$(grep -vE '^[[:space:]]*(#|$)' "$D/.env.refs" | awk -F= '
    { v = substr($0, index($0, "=") + 1) }
    v ~ /^(kv|gh):\/\// && v !~ /^(kv:\/\/[A-Za-z0-9-]+\/[A-Za-z0-9-]+|gh:\/\/token)$/ { print "réf. mal formée : " $1 }
    $1 ~ /(PASSWORD|SECRET|TOKEN|_KEY)$/ && v != "" && v !~ /^(kv|gh):\/\// { print "valeur en clair : " $1 }')"
  [ -z "$bad_refs" ] && pass "$L: .env.refs sans valeur secrète, références bien formées" || { bad "$L: .env.refs :"; echo "$bad_refs"; }
  grep -qE '\{\{|\{%' "$D/.env.refs" "$D/.env.example" "$D"/.devcontainer/*.sh "$D/$DC" \
    && bad "$L: marqueurs Jinja non résolus" || pass "$L: aucun marqueur Jinja non résolu"
  (cd "$D" && git init -q . 2>/dev/null && ! git check-ignore -q .env.refs && git check-ignore -q .env) \
    && pass "$L: .env.refs versionnable, .env ignoré" || bad "$L: .gitignore : .env.refs ignoré ou .env suivi"
  # défaut 3 : un .env mis de côté est ignoré, les modèles et .env.refs non
  (cd "$D" && git check-ignore -q .env.avant-keyvault && git check-ignore -q .env.bak && git check-ignore -q .env.ecc \
     && ! git check-ignore -q .env.example && ! git check-ignore -q .env.ecc.example && ! git check-ignore -q .envrc) \
    && pass "$L: .gitignore : .env.* ignorés sauf .env.refs et *.example" || bad "$L: .gitignore : motifs .env.* incorrects"
  # défaut 4 : plus aucun texte qui renvoie au .env
  if grep -nE 'Fill it in .*\.env[^.]|in \.env\.|Fix \.env|depuis `\.env` par pydantic|reads \.env at runtime|symlinking$' \
       "$D/.devcontainer/lib-mcp.sh" "$D/.devcontainer/README.md" "$D/$DC" "$D/.devcontainer/post-create.sh" | grep -q .; then
    bad "$L: textes qui renvoient encore au .env :"; grep -nE 'Fill it in .*\.env[^.]|in \.env\.|Fix \.env|depuis `\.env` par pydantic|reads \.env at runtime|symlinking$' \
       "$D/.devcontainer/lib-mcp.sh" "$D/.devcontainer/README.md" "$D/$DC" "$D/.devcontainer/post-create.sh"
  else pass "$L: aucun texte ne renvoie au .env (lib-mcp, README, devcontainer.json, post-create)"; fi
  grep -q 'Bootstrap .env' "$D/.devcontainer/post-create.sh" && bad "$L: post-create annonce un bootstrap .env" || pass "$L: post-create sans bootstrap .env"
  grep -q 'chmod 600 "$WORKSPACE_DIR/.env" ' "$D/.devcontainer/post-start.sh" && bad "$L: post-start vise encore .env seul" || pass "$L: post-start protège tout .env* restant"
}

echo "== secrets_source=keyvault (mcp-server) =="
if render false "$WORK/kv" --data secrets_source=keyvault; then
  kv_checks KV "$WORK/kv"
  grep -q 'kv://perso/github-pat' "$WORK/kv/.env.refs" && pass "KV: jeton GitHub = kv://perso/github-pat" || bad "KV: jeton GitHub non référencé"
  grep -q 'secrets_sans_refs' "$WORK/kv/.devcontainer/post-start.sh" && pass "KV: instance ECC lancée sans les variables S/4" || bad "KV: instance ECC hérite des variables S/4"
  # lib-secrets.sh en vrai : az simulé, .env.refs en clair -> secrets_load_env exporte
  # exactement les variables du fichier, sans toucher au reste
  mkdir -p "$WORK/kvbin"
  printf '#!/bin/sh\necho essai@example.com\n' >"$WORK/kvbin/az"; chmod +x "$WORK/kvbin/az"
  printf 'ESSAI_A=1\nESSAI_B="deux mots"\n' >"$WORK/kv/essai.refs"
  out="$(PATH="$WORK/kvbin:$WORK/kv/.devcontainer/secrets:$PATH" HOME="$WORK/kvhome" SECRETS_COFFRE_PERSO=x bash -c '
    mkdir -p "$HOME"; source "$1/.devcontainer/lib-secrets.sh"
    secrets_load_env "$1/essai.refs" >/dev/null && printf "%s|%s|%s" "$ESSAI_A" "$ESSAI_B" "${PATH_ESSAI_ABSENT:-}"' _ "$WORK/kv")"
  [ "$out" = "1|deux mots|" ] && pass "KV: secrets_load_env exporte les variables de .env.refs" || bad "KV: secrets_load_env a rendu « $out »"

  # --- défaut 1 : jeton GitHub par projet ---
  H="$WORK/kv/.devcontainer/secrets/git-credential-secrets"
  ref_de() { (cd "$1" && env -u SECRETS_GITHUB_REF -u SECRETS_WORKSPACE "$H" ref); }
  [ "$(ref_de "$WORK/kv")" = "kv://perso/github-pat" ] && pass "KV/1: .env.refs du modèle → kv://perso/github-pat" || bad "KV/1: réf. du modèle : $(ref_de "$WORK/kv")"
  mkdir -p "$WORK/gh1" "$WORK/gh2" "$WORK/gh3" "$WORK/gh4"
  printf 'GITHUB_PERSONAL_ACCESS_TOKEN=kv://perso/github-pat-sap-excel\nGH_TOKEN="kv://perso/github-pat-sap-excel"  # PAT fin\n' >"$WORK/gh1/.env.refs"
  printf 'GITHUB_PERSONAL_ACCESS_TOKEN=kv://kv-4it-dev-partage/pat-projet\n' >"$WORK/gh2/.env.refs"
  printf 'GH_TOKEN=pas-une-reference\nexport GITHUB_PERSONAL_ACCESS_TOKEN=kv://perso/autre\n' >"$WORK/gh3/.env.refs"
  [ "$(ref_de "$WORK/gh1")" = "kv://perso/github-pat-sap-excel" ] && pass "KV/1: GH_TOKEN (guillemets, commentaire) retenu" || bad "KV/1: gh1 → $(ref_de "$WORK/gh1")"
  [ "$(ref_de "$WORK/gh2")" = "kv://kv-4it-dev-partage/pat-projet" ] && pass "KV/1: GITHUB_PERSONAL_ACCESS_TOKEN à défaut de GH_TOKEN" || bad "KV/1: gh2 → $(ref_de "$WORK/gh2")"
  [ "$(ref_de "$WORK/gh3")" = "kv://perso/autre" ] && pass "KV/1: valeur en clair ignorée, export accepté" || bad "KV/1: gh3 → $(ref_de "$WORK/gh3")"
  [ "$(ref_de "$WORK/gh4")" = "kv://perso/github-pat" ] && pass "KV/1: sans .env.refs → kv://perso/github-pat" || bad "KV/1: gh4 → $(ref_de "$WORK/gh4")"
  [ "$(cd "$WORK/gh4" && SECRETS_WORKSPACE="$WORK/gh1" "$H" ref)" = "kv://perso/github-pat-sap-excel" ] && pass "KV/1: repli sur le .env.refs de SECRETS_WORKSPACE" || bad "KV/1: SECRETS_WORKSPACE ignoré"
  [ "$(cd "$WORK/gh1" && SECRETS_GITHUB_REF=kv://perso/essai "$H" ref)" = "kv://perso/essai" ] && pass "KV/1: SECRETS_GITHUB_REF l'emporte" || bad "KV/1: SECRETS_GITHUB_REF ignoré"
  # get : lanceur simulé (mcp-headers renvoie un faux jeton dérivé de la réf.)
  mkdir -p "$WORK/ghbin"
  cat >"$WORK/ghbin/secrets" <<'STUB'
#!/bin/sh
[ "$1" = mcp-headers ] || exit 2
printf '{"t":"faux-%s"}\n' "${2#t=}"
STUB
  chmod +x "$WORK/ghbin/secrets"
  out="$(cd "$WORK/gh1" && printf 'protocol=https\nhost=github.com\n\n' | env -u GH_TOKEN PATH="$WORK/ghbin:$PATH" "$H" get)"
  [ "$out" = "$(printf 'username=x-access-token\npassword=faux-kv://perso/github-pat-sap-excel')" ] && pass "KV/1: git get → jeton de la réf. du projet" || bad "KV/1: git get a rendu « $out »"
  out="$(cd "$WORK/gh1" && printf 'protocol=https\nhost=gitlab.com\n\n' | env -u GH_TOKEN PATH="$WORK/ghbin:$PATH" "$H" get)"
  [ -z "$out" ] && pass "KV/1: git get muet hors github.com" || bad "KV/1: git get répond pour gitlab.com"
  grep -q 'github.refs' "$WORK/kv/.devcontainer/lib-secrets.sh" "$H" && bad "KV/1: github.refs encore référencé" || pass "KV/1: plus de github.refs"
  # Enveloppe gh (~/.local/bin/gh) : jeton du projet hors terminal interactif
  W="$WORK/kv/.devcontainer/secrets/gh"
  mkdir -p "$WORK/vraigh" "$WORK/lbin"
  cat >"$WORK/vraigh/gh" <<'STUB'
#!/bin/sh
printf 'jeton=%s|args=%s|n=%s\n' "${GH_TOKEN:-}" "$*" "$#"
[ "${1:-}" = echec ] && exit 3
exit 0
STUB
  chmod +x "$WORK/vraigh/gh"; chmod +x "$W" "$H"
  ln -sfn "$W" "$WORK/lbin/gh"; ln -sfn "$H" "$WORK/lbin/git-credential-secrets"
  PW="$WORK/lbin:$WORK/ghbin:$WORK/vraigh:/usr/bin:/bin"
  gw() { env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN -u SECRETS_WORKSPACE -u SECRETS_GITHUB_REF PATH="$PW" "$@"; }
  sh -n "$W" && grep -qF 'ln -sfn "$SECRETS_DIR/gh" "$HOME/.local/bin/gh"' "$WORK/kv/.devcontainer/lib-secrets.sh" \
    && pass "KV/gh: enveloppe rendue, liée en ~/.local/bin/gh par secrets_install" || bad "KV/gh: enveloppe absente ou non liée"
  [ "$(cd "$WORK/gh1" && gw GH_TOKEN=abc gh api user)" = "jeton=abc|args=api user|n=2" ] && pass "KV/gh: GH_TOKEN déjà là → inchangé" || bad "KV/gh: GH_TOKEN modifié"
  [ "$(cd "$WORK/gh2" && gw GITHUB_PERSONAL_ACCESS_TOKEN=pat gh api user)" = "jeton=pat|args=api user|n=2" ] && pass "KV/gh: réf. venue de GITHUB_PERSONAL_ACCESS_TOKEN, variable déjà là → reprise sans lire le coffre" || bad "KV/gh: GITHUB_PERSONAL_ACCESS_TOKEN ignoré"
  [ "$(cd "$WORK/gh1" && gw GITHUB_PERSONAL_ACCESS_TOKEN=pat gh api user)" = "jeton=faux-kv://perso/github-pat-sap-excel|args=api user|n=2" ] && pass "KV/gh: réf. venue de GH_TOKEN (.env.refs) → elle, pas GITHUB_PERSONAL_ACCESS_TOKEN (comme git)" || bad "KV/gh: ordre différent de git (GH_TOKEN de .env.refs)"
  [ "$(cd "$WORK/gh2" && gw GITHUB_PERSONAL_ACCESS_TOKEN=pat SECRETS_GITHUB_REF=kv://perso/essai gh api user)" = "jeton=faux-kv://perso/essai|args=api user|n=2" ] && pass "KV/gh: SECRETS_GITHUB_REF l'emporte sur la variable (comme git)" || bad "KV/gh: SECRETS_GITHUB_REF ignoré"
  [ "$(cd "$WORK/gh1" && gw GITHUB_TOKEN=gt gh api user)" = "jeton=faux-kv://perso/github-pat-sap-excel|args=api user|n=2" ] && pass "KV/gh: GITHUB_TOKEN seul → réf. du projet en GH_TOKEN (comme git)" || bad "KV/gh: GITHUB_TOKEN"
  for d in gh1 gh2 gh4; do
    [ "$(cd "$WORK/$d" && env -u SECRETS_GITHUB_REF -u SECRETS_WORKSPACE "$H" source)" = "$(case $d in gh1) echo GH_TOKEN;; gh2) echo GITHUB_PERSONAL_ACCESS_TOKEN;; gh4) echo defaut;; esac)" ] \
      && pass "KV/gh: git-credential-secrets source ($d)" || bad "KV/gh: source ($d) → $(cd "$WORK/$d" && "$H" source)"
  done
  [ "$(cd "$WORK/gh1" && gw gh pr list)" = "jeton=faux-kv://perso/github-pat-sap-excel|args=pr list|n=2" ] && pass "KV/gh: sans variable → jeton de la réf. du projet (shell de Claude Code)" || bad "KV/gh: jeton du projet non lu : $(cd "$WORK/gh1" && gw gh pr list)"
  out="$(cd "$WORK/gh1" && env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_PERSONAL_ACCESS_TOKEN PATH="$WORK/lbin:$WORK/vraigh:/usr/bin:/bin" gh api 'a b' "")"
  [ "$out" = "jeton=|args=api a b |n=3" ] && pass "KV/gh: lecture impossible → gh sans jeton, arguments intacts" || bad "KV/gh: repli : $out"
  (cd "$WORK/gh1" && gw GH_TOKEN=x gh echec >/dev/null); [ $? = 3 ] && pass "KV/gh: code de sortie de gh transmis" || bad "KV/gh: code de sortie perdu"
  out="$(cd "$WORK/gh1" && env -u GH_TOKEN PATH="$WORK/lbin:$WORK/kv/.devcontainer/secrets:/usr/bin:/bin" GH_TOKEN=y timeout 5 gh --version 2>&1 | head -1)"
  case "$out" in "gh version"*) pass "KV/gh: sans autre gh avant /usr/bin, pas de boucle (vrai gh trouvé)" ;; *) bad "KV/gh: boucle ou gh introuvable : $out" ;; esac

  # --- défaut 2 : droits, même rendu sous umask 0000 ---
  chmod 666 "$WORK/kv/.devcontainer/lib-secrets.sh" "$WORK/kv/.devcontainer/secrets"/*; chmod 777 "$WORK/kv/.devcontainer/secrets"
  chmod 777 "$WORK/kv/.devcontainer/secrets/secrets" "$H"
  PATH="$WORK/kvbin:$PATH" HOME="$WORK/kvhome2" bash -c 'mkdir -p "$HOME"; source "$1/.devcontainer/lib-secrets.sh"; secrets_install "$1" >/dev/null' _ "$WORK/kv"
  ww="$(find "$WORK/kv/.devcontainer/lib-secrets.sh" "$WORK/kv/.devcontainer/secrets" -perm /022)"
  [ -z "$ww" ] && pass "KV/2: secrets_install retire l'écriture groupe/autres" || { bad "KV/2: encore modifiables par d'autres :"; echo "$ww"; }
  [ -x "$WORK/kvhome2/.local/bin/secrets" ] && [ -x "$WORK/kvhome2/.local/bin/git-credential-secrets" ] && pass "KV/2: lanceurs liés et exécutables" || bad "KV/2: liens ~/.local/bin absents"
  grep -q 'SECRETS_WORKSPACE=' "$WORK/kvhome2/.bashrc" && pass "KV/2: bloc ~/.bashrc posé" || bad "KV/2: bloc ~/.bashrc absent"
  sed -n '/^# >>> secrets (sap-template) >>>$/,/^# <<< secrets/p' "$WORK/kvhome2/.bashrc" | sed -n 2p | grep -q '^umask 022' \
    && pass "KV/umask: bloc ~/.bashrc commence par umask 022" || bad "KV/umask: pas d'umask 022 en tête du bloc ~/.bashrc"
  grep -q '^function gh\b' "$WORK/kv/.devcontainer/lib-secrets.sh" && bad "KV/gh: fonction gh encore dans lib-secrets.sh" || pass "KV/gh: plus de fonction gh (l'enveloppe sert partout)"
  for f in post-create.sh post-start.sh; do
    n=$(grep -n '^umask 022$' "$WORK/kv/.devcontainer/$f" | head -1 | cut -d: -f1)
    [ -n "$n" ] && [ "$n" -lt 40 ] && bash -n "$WORK/kv/.devcontainer/$f" && pass "KV/umask: $f pose umask 022 dès le début (ligne $n)" || bad "KV/umask: $f sans umask 022 en tête"
    grep -q '^umask 022' "$WORK/off/.devcontainer/$f" 2>/dev/null && bad "KV/umask: umask dans $f du rendu par défaut" || pass "KV/umask: rendu par défaut sans umask dans $f"
  done

  # --- défaut 8 : relance des serveurs MCP qui tournent ---
  mkdir -p "$WORK/opt/srv/scripts" "$WORK/rl"
  printf '#!/bin/sh\necho "$1" >>"%s/opt/srv/appels"\n' "$WORK" >"$WORK/opt/srv/scripts/mcp-server.sh"
  chmod +x "$WORK/opt/srv/scripts/mcp-server.sh"
  printf '# commentaire\nsrv https://example.invalid/srv.git - 8000\nabsent https://example.invalid/x.git\n' >"$WORK/rl/mcp-servers.conf"
  printf 'A=kv://perso/a\n' >"$WORK/rl/.env.refs"
  relance() { MCP_OPT_DIR="$WORK/opt" HOME="$WORK/rlhome" bash -c 'source "$1/.devcontainer/lib-secrets.sh"; secrets_mcp_relance "$2/mcp-servers.conf" "$2/.env.refs" "$3"' _ "$WORK/kv" "$WORK/rl" "$1"; }
  appels() { cat "$WORK/opt/srv/appels" 2>/dev/null | wc -l | tr -d ' '; }
  relance 0 >/dev/null; [ "$(appels)" = 0 ] && pass "KV/8: premier passage : rien n'est arrêté" || bad "KV/8: arrêt au premier passage"
  relance 0 >/dev/null; [ "$(appels)" = 0 ] && pass "KV/8: .env.refs inchangé : serveur gardé" || bad "KV/8: arrêt sans changement"
  printf 'A=kv://perso/b\n' >"$WORK/rl/.env.refs"
  out="$(relance 0)"; [ "$(appels)" = 1 ] && [ "$(cat "$WORK/opt/srv/appels")" = stop ] && pass "KV/8: .env.refs modifié → stop ($out)" || bad "KV/8: pas d'arrêt après modification"
  relance 0 >/dev/null; [ "$(appels)" = 1 ] && pass "KV/8: une seule relance par modification" || bad "KV/8: arrêts répétés"
  relance 1 >/dev/null; [ "$(appels)" = 2 ] && pass "KV/8: --relance-mcp force l'arrêt" || bad "KV/8: --relance-mcp sans effet"
  grep -q 'secrets_mcp_relance' "$WORK/kv/.devcontainer/post-start.sh" && grep -q -- '--relance-mcp' "$WORK/kv/.devcontainer/post-start.sh" \
    && pass "KV/8: post-start appelle la relance (option --relance-mcp)" || bad "KV/8: post-start sans relance"

  # --- défauts 2, 7 : post-start rendu, lancé pour de vrai (az simulé, refs en clair, aucun serveur) ---
  cp -a "$WORK/kv" "$WORK/ps"
  printf 'ESSAI_A=1\nESSAI_B=deux\n' >"$WORK/ps/.env.refs"
  sed -i 's/^[^#]/# &/' "$WORK/ps/.devcontainer/mcp-servers.conf"
  (umask 0000; : >"$WORK/ps/.env.avant-keyvault")
  ps_run() { (cd "$WORK/ps" && env -u WORKSPACE_DIR containerWorkspaceFolder="$WORK/ps" PATH="$WORK/kvbin:/usr/bin:/bin" HOME="$WORK/pshome" \
               AZURE_CONFIG_DIR="$WORK/pshome/az" bash .devcontainer/post-start.sh "$@" >/dev/null 2>&1); }
  mkdir -p "$WORK/pshome"; ps_run; ps_run
  LOGF="$WORK/pshome/.local/state/devcontainer/post-start.log"
  [ -f "$LOGF" ] && [ -f "$LOGF.1" ] && pass "KV/7: post-start.log écrit (et le précédent en .1)" || bad "KV/7: post-start.log absent"
  grep -q '2 variable(s) chargée(s) en mémoire' "$LOGF" && pass "KV/7: le journal dit « 2 variable(s) chargée(s) »" || { bad "KV/7: journal incomplet :"; tail -5 "$LOGF"; }
  grep -q 'Post-start complete' "$LOGF" && pass "KV/7: le journal va jusqu'au bout" || bad "KV/7: journal tronqué"
  [ "$(stat -c %a "$LOGF")" = 600 ] && pass "KV/7: journal en 600" || bad "KV/7: journal en $(stat -c %a "$LOGF")"
  [ "$(stat -c %a "$WORK/ps/.env.avant-keyvault")" = 600 ] && pass "KV/4: .env mis de côté passé en 600" || bad "KV/4: .env.avant-keyvault en $(stat -c %a "$WORK/ps/.env.avant-keyvault")"
  grep -qE 'ATTENTION : [1-9][0-9]* fichier\(s\) ou dossier\(s\) modifiables par tous' "$LOGF" && grep -q 'chmod -R go-w' "$LOGF" \
    && pass "KV/umask: post-start compte les fichiers modifiables par tous (rendu copier en 0000) et donne la correction" || bad "KV/umask: pas d'avertissement"
  ln -sfn /tmp "$WORK/ps/lien-essai"; chmod -R go-w "$WORK/ps"; ps_run
  grep -A1 '^\[umask\]' "$LOGF" | grep -q 'aucun' && pass "KV/umask: après chmod -R go-w → « aucun » (liens ignorés, rien recréé en 0666 par post-start)" || { bad "KV/umask: encore des fichiers :"; grep -A7 '^\[umask\]' "$LOGF"; }
else
  bad "KV: copier a échoué"
fi
echo "== secrets_source=keyvault + IaC (azure-cli pas en double) =="
if render false "$WORK/kviac" --data secrets_source=keyvault --data enable_iac=true --data iac_short_name=rt; then
  [ "$(grep -c 'features/azure-cli' "$WORK/kviac/$DC")" = 1 ] && pass "KV+IAC: feature azure-cli une seule fois" || bad "KV+IAC: feature azure-cli en double"
  jsonc_ok "$WORK/kviac/$DC" && pass "KV+IAC: devcontainer.json valide" || bad "KV+IAC: devcontainer.json invalide"
else
  bad "KV+IAC: copier a échoué"
fi
echo "== secrets_source=keyvault (base) =="
if render false "$WORK/kvbase" --data secrets_source=keyvault --data project_type=base; then
  kv_checks KV-BASE "$WORK/kvbase"
  grep -q 'SAP_' "$WORK/kvbase/.env.refs" && bad "KV-BASE: variables SAP dans .env.refs" || pass "KV-BASE: pas de variable SAP"
else
  bad "KV-BASE: copier a échoué"
fi

echo "== enable_dotnet (SDK + volume du cache NuGet) =="
if render false "$WORK/net" --data enable_dotnet=true --data dotnet_version=8.0; then
  grep -q '"ghcr.io/devcontainers/features/dotnet:2": { "version": "8.0" }' "$WORK/net/$DC" && pass "NET: feature dotnet 8.0" || bad "NET: feature dotnet absente"
  grep -q 'source=devcontainer-nuget-packages,target=/home/vscode/.nuget/packages,type=volume' "$WORK/net/$DC" && pass "NET: volume ~/.nuget/packages" || bad "NET: volume NuGet absent"
  grep -q '"nuget-packages": "sudo chown vscode:vscode /home/vscode/.nuget /home/vscode/.nuget/packages"' "$WORK/net/$DC" && pass "NET: volume rendu à vscode (onCreate)" || bad "NET: chown du volume absent"
  jsonc_ok "$WORK/net/$DC" && pass "NET: devcontainer.json valide" || bad "NET: devcontainer.json invalide"
  grep -q '^## .NET (`enable_dotnet`)' "$WORK/net/.devcontainer/README.md" && pass "NET: section .NET du README" || bad "NET: section .NET absente"
else
  bad "NET: copier a échoué"
fi
if render false "$WORK/netkv" --data enable_dotnet=true --data secrets_source=keyvault --data enable_iac=true --data iac_short_name=rt; then
  jsonc_ok "$WORK/netkv/$DC" && pass "NET+KV+IAC: devcontainer.json valide" || bad "NET+KV+IAC: devcontainer.json invalide"
else
  bad "NET+KV+IAC: copier a échoué"
fi

echo "== dbt-fleet + keyvault + claude_profile (forme du pilote mh-dbt-global-vault) =="
if render false "$WORK/fleetkv" --data project_type=dbt-fleet --data secrets_source=keyvault --data claude_profile=fleet-kv \
     --data bq_sandbox_project=sandbox-prj --data bq_sandbox_dataset=JDOE_run --data bq_dataset_prefix=JDOE --data dbt_target_name=prd; then
  ok=1; for f in "$WORK/fleetkv/.devcontainer/"*.sh; do bash -n "$f" || ok=0; done
  [ "$ok" = 1 ] && pass "FLEETKV: tous les scripts .devcontainer passent bash -n" || bad "FLEETKV: script invalide"
  P="$WORK/fleetkv/.devcontainer/post-start.sh"
  a=$(grep -n 'secrets_load_env' "$P" | head -1 | cut -d: -f1); b=$(grep -n 'tunnels_start' "$P" | head -1 | cut -d: -f1)
  c=$(grep -n 'mcp-instance.sh" start' "$P" | head -1 | cut -d: -f1); d=$(grep -n 'dbt_process' "$P" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ -n "$d" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && [ "$c" -lt "$d" ] \
    && pass "FLEETKV: post-start : secrets → tunnels → MCP et instances → dbt" || bad "FLEETKV: ordre post-start ($a $b $c $d)"
  [ -f "$WORK/fleetkv/.env.refs" ] && [ -f "$WORK/fleetkv/.devcontainer/claude-profile-host.sh" ] && jsonc_ok "$WORK/fleetkv/$DC" \
    && pass "FLEETKV: .env.refs, profil Claude, devcontainer.json valide" || bad "FLEETKV: rendu incomplet"
else
  bad "FLEETKV: copier a échoué"
fi

echo "== Tunnels SSH (tunnels.conf) et instances MCP (mcp-instances.conf) =="
for D in "$WORK/off" "$WORK/kv"; do
  L=$(basename "$D")
  ok=1
  for f in lib-tunnels.sh tunnel.sh mcp-instance.sh tunnels.conf tunnels.known_hosts mcp-instances.conf; do [ -f "$D/.devcontainer/$f" ] || ok=0; done
  [ "$ok" = 1 ] && bash -n "$D/.devcontainer/lib-tunnels.sh" && bash -n "$D/.devcontainer/tunnel.sh" && bash -n "$D/.devcontainer/mcp-instance.sh" \
    && pass "TUN/$L: lib-tunnels.sh, tunnel.sh, mcp-instance.sh et les 3 fichiers du projet rendus, bash -n OK" || bad "TUN/$L: fichiers absents ou invalides"
  [ -z "$(grep -vE '^[[:space:]]*(#|$)' "$D/.devcontainer/tunnels.conf" "$D/.devcontainer/mcp-instances.conf")" ] \
    && pass "TUN/$L: tunnels.conf et mcp-instances.conf livrés tout en commentaires (rien d'actif)" || bad "TUN/$L: ligne active dans un fichier livré"
  grep -q 'tunnels_start' "$D/.devcontainer/post-start.sh" && grep -q 'mcp-instance.sh" start' "$D/.devcontainer/post-start.sh" \
    && [ "$(grep -n 'tunnels_start' "$D/.devcontainer/post-start.sh" | cut -d: -f1 | head -1)" -lt "$(grep -n 'mcp_process_manifest .*start' "$D/.devcontainer/post-start.sh" | cut -d: -f1 | tail -1)" ] \
    && pass "TUN/$L: post-start lance les tunnels AVANT les serveurs MCP, puis les instances" || bad "TUN/$L: ordre post-start"
done
for f in tunnels.conf tunnels.known_hosts mcp-instances.conf; do
  grep -qxF "  - .devcontainer/$f" "$REPO_ROOT/copier.yml" && pass "TUN: $f au projet (_skip_if_exists)" || bad "TUN: $f écrasé par copier update"
done
# --- tunnel de bout en bout : faux ssh (agent + clé d'hôte exigés, -L ouverts par socat) ---
if command -v socat >/dev/null && command -v ssh-agent >/dev/null && command -v python3 >/dev/null; then
  T="$WORK/tun"; mkdir -p "$T/bin" "$T/dc" "$T/home"
  cp "$WORK/kv/.devcontainer/"{lib-tunnels.sh,tunnel.sh} "$T/dc/"
  cat >"$T/bin/ssh" <<'STUB'
#!/bin/bash
kh=""; fw=(); cible=""
while [ $# -gt 0 ]; do case "$1" in
  -o) case "$2" in UserKnownHostsFile=*) kh="${2#*=}";; esac; shift 2;;
  -p) shift 2;; -N) shift;; -L) fw+=("$2"); shift 2;; *) cible="$1"; shift;; esac; done
ssh-add -l >/dev/null 2>&1 || { echo "stub: pas de clé dans l'agent" >&2; exit 255; }
ssh-keygen -F "${cible#*@}" -f "$kh" >/dev/null 2>&1 || { echo "stub: hôte non épinglé" >&2; exit 255; }
pids=()
for f in "${fw[@]}"; do IFS=: read -r _ pl h p <<<"$f"; socat TCP-LISTEN:$pl,bind=127.0.0.1,fork,reuseaddr TCP:127.0.0.1:$p & pids+=($!); done
trap 'kill ${pids[*]} 2>/dev/null; exit 0' TERM INT
echo "stub: connecté à $cible"; wait
STUB
  chmod +x "$T/bin/ssh"
  ssh-keygen -q -t ed25519 -N '' -f "$T/cle" >/dev/null; ssh-keygen -q -t ed25519 -N '' -f "$T/hote" >/dev/null
  PH=$((20000 + RANDOM % 20000)); PL=$((PH + 1)); PS=$((PH + 2))
  python3 -m http.server "$PH" --bind 127.0.0.1 >/dev/null 2>&1 & HTTPD=$!
  printf 'web  moi@relais.exemple  %s  127.0.0.1:%s  MA_CLE\nsap  moi@relais.exemple  %s  sap.exemple:%s  MA_CLE\n' "$PL" "$PH" "$PS" "$PS" >"$T/dc/tunnels.conf"
  : >"$T/hosts"; SD="$(mktemp -d /tmp/tt.XXXXXX)"; chmod 700 "$SD"
  tun() { env HOME="$T/home" PATH="$T/bin:$PATH" TUNNELS_HOSTS_FILE="$T/hosts" TUNNELS_WAIT=8 TUNNELS_SOCK_DIR="$SD" "$@"; }
  out="$(tun MA_CLE="$(base64 -w0 "$T/cle")" bash "$T/dc/tunnel.sh" start 2>&1)"
  echo "$out" | grep -q "non épinglée" && pass "TUN: clé d'hôte non épinglée → refus (rien lancé)" || bad "TUN: hôte non épinglé accepté : $out"
  printf 'relais.exemple %s\n' "$(cut -d' ' -f1,2 "$T/hote.pub")" >"$T/dc/tunnels.known_hosts"
  out="$(tun bash "$T/dc/tunnel.sh" start 2>&1)"
  echo "$out" | grep -q "aucune clé" && pass "TUN: sans variable de clé ni agent → message, sortie 0" || bad "TUN: sans clé : $out"
  out="$(tun MA_CLE="$(base64 -w0 "$T/cle")" bash "$T/dc/tunnel.sh" start 2>&1)"; sleep 1
  [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PL/")" = 200 ] && pass "TUN: clé base64 (Key Vault) → agent → tunnel, HTTP 200 au travers" || bad "TUN: tunnel muet : $out"
  grep -qx "127.0.0.1 sap.exemple  # tunnels.conf" "$T/hosts" && ! grep -q "127.0.0.1:$PH\|^127.0.0.1 127" "$T/hosts" \
    && pass "TUN: /etc/hosts : cible nommée (même port) → 127.0.0.1 ; cible IP ignorée" || bad "TUN: /etc/hosts : $(cat "$T/hosts")"
  P="$(cat "$T/home/.local/state/devcontainer/tunnels/"*.pid 2>/dev/null)"
  [ -n "$P" ] && [ "$(ps -o sid= -p "$P" | tr -d ' ')" = "$P" ] && ! tr '\0' '\n' <"/proc/$P/environ" | grep -q '^MA_CLE=' \
    && pass "TUN: superviseur dans sa propre session, sans la clé dans son environnement" || bad "TUN: superviseur (PID ${P:-?})"
  [ -z "$(grep -rl "$(sed -n 2p "$T/cle")" "$T/home" "$SD" 2>/dev/null)" ] && [ "$(stat -c %a "$SD")" = 700 ] \
    && pass "TUN: la clé n'est écrite nulle part ; dossier de l'agent en 700" || bad "TUN: clé retrouvée sur disque"
  pkill -f "^/bin/bash $T/bin/ssh" ; sleep 7
  [ "$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:$PL/")" = 200 ] && pass "TUN: ssh tué → relancé par le superviseur" || bad "TUN: pas de relance"
  out="$(tun bash "$T/dc/tunnel.sh" status 2>&1)"
  echo "$out" | grep -q "superviseur ACTIF" && echo "$out" | grep -q "sap  127.0.0.1:$PS → sap.exemple:$PS : EN ÉCOUTE" \
    && pass "TUN: status (superviseur, chaque redirection)" || bad "TUN: status : $out"
  tun bash "$T/dc/tunnel.sh" stop >/dev/null; sleep 1
  ! (exec 3<>"/dev/tcp/127.0.0.1/$PL") 2>/dev/null && [ -z "$(ps -eo args | grep -E "^socat TCP-LISTEN:($PL|$PS)," )" ] \
    && pass "TUN: stop → ports fermés, aucun ssh/socat restant" || bad "TUN: stop incomplet"
  out="$(tun bash "$T/dc/tunnel.sh" start 2>&1)"
  echo "$out" | grep -q "actif" && pass "TUN: relance sans la variable : l'agent garde la clé (terminal Key Vault)" || bad "TUN: relance sans variable : $out"
  tun bash "$T/dc/tunnel.sh" stop >/dev/null
  pkill -f "ssh-agent -a $SD" 2>/dev/null; kill "$HTTPD" 2>/dev/null; rm -rf "$SD"
else
  echo "  (socat/ssh-agent/python3 absents : essai de bout en bout du tunnel sauté)"
fi
# --- instances : variables PRÉFIXE_* seulement ---
I="$WORK/inst"; mkdir -p "$I/ws/.devcontainer" "$I/opt/srv/scripts"
cp "$WORK/kv/.devcontainer/mcp-instance.sh" "$I/ws/.devcontainer/"
cat >"$I/opt/srv/scripts/mcp-server.sh" <<'STUB'
#!/bin/bash
echo "verbe=$1 port=$MCP_PORT host=$MCP_HOST pid=${MCP_PID_FILE##*/} log=${MCP_LOG_FILE##*/}"
for v in SAP_URL SAP_USER SAP_PASSWORD SAP_HANA_HOST MCP_AUTH_TOKEN BCA_SAP_URL AUTRE_SECRET; do
  if [ -n "${!v+x}" ]; then x="${!v}"; echo "$v=${#x}"; else echo "$v=absent"; fi
done
STUB
chmod +x "$I/opt/srv/scripts/mcp-server.sh"
printf 'SAP_URL=x\nSAP_HANA_HOST=h\n' >"$I/opt/srv/.env"
printf 'SAP_URL=kv://perso/a\nAUTRE_SECRET=kv://perso/c\nBCA_SAP_URL=kv://perso/d\nBCA_SAP_USER=kv://perso/e\n' >"$I/ws/.env.refs"
printf '# c\nsap-adt-bca  srv  8020  BCA\nmauvais srv 80x BCA\nsap-adt-qls srv 8021 QLS\n' >"$I/ws/.devcontainer/mcp-instances.conf"
out="$(env SAP_URL=s4 SAP_PASSWORD=s4pw AUTRE_SECRET=zz MCP_AUTH_TOKEN=tok BCA_SAP_URL=https://bca BCA_SAP_USER=jb MCP_OPT_DIR="$I/opt" \
  bash "$I/ws/.devcontainer/mcp-instance.sh" start 2>&1)"
echo "$out" | grep -q '^verbe=start port=8020 host=127.0.0.1 pid=.mcp-server-sap-adt-bca.pid log=server-sap-adt-bca.log$' \
  && pass "INST: sap-adt-bca → lanceur du serveur, 127.0.0.1:8020, PID et journal propres" || bad "INST: lancement : $out"
echo "$out" | grep -q '^SAP_URL=11$' && echo "$out" | grep -q '^SAP_USER=2$' \
  && pass "INST: BCA_SAP_URL/BCA_SAP_USER repris en SAP_URL/SAP_USER (longueurs 11, 2)" || bad "INST: reprise du préfixe"
echo "$out" | grep -q '^SAP_PASSWORD=absent$' && echo "$out" | grep -q '^AUTRE_SECRET=absent$' && echo "$out" | grep -q '^BCA_SAP_URL=absent$' \
  && pass "INST: aucune autre variable du projet (ni S/4, ni secret étranger, ni BCA_*)" || bad "INST: fuite de variables du projet"
echo "$out" | grep -q '^SAP_HANA_HOST=0$' && echo "$out" | grep -q '^MCP_AUTH_TOKEN=0$' \
  && pass "INST: clés du .env du serveur et réglages d'écoute non posés → vides (pas de repli)" || bad "INST: repli .env / Bearer hérité"
echo "$out" | grep -q 'mauvais : port « 80x » invalide' && echo "$out" | grep -q 'sap-adt-qls : aucune variable QLS_' \
  && pass "INST: port invalide et préfixe sans variables → messages, rien lancé" || bad "INST: cas d'erreur"
[ "$(env MCP_OPT_DIR="$I/opt" bash "$I/ws/.devcontainer/mcp-instance.sh" stop sap-adt-bca | grep -c '^verbe=stop port=8020')" = 1 ] \
  && pass "INST: stop NOM → cette instance seule" || bad "INST: stop ciblé"
grep -q 'mcp-instance.sh" stop' "$WORK/kv/.devcontainer/lib-secrets.sh" && pass "INST: --relance-mcp / .env.refs modifié arrêtent aussi les instances" || bad "INST: relance sans les instances"

echo "== Vérif marqueurs Jinja non résolus (les deux rendus) =="
if grep -rlE '\{\{|\{%' "$WORK/off" "$WORK/on" --include='*.md' --include='*.conf' --include='*.toml' 2>/dev/null | grep -q .; then
  bad "marqueurs Jinja non résolus trouvés :"; grep -rlE '\{\{|\{%' "$WORK/off" "$WORK/on" --include='*.md' --include='*.conf' --include='*.toml' 2>/dev/null
else
  pass "aucun marqueur Jinja non résolu"
fi

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mTOUS LES CONTRÔLES PASSENT\033[0m"; else echo -e "\033[31mECHECS DETECTES\033[0m"; fi
exit "$fail"
