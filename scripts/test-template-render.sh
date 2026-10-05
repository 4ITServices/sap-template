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
# de squelette Python, l'outillage dbt (lib-dbt.sh, dbt.conf, feature gcloud,
# hub de profils, products.conf et global/ pour la flotte) présent et valide,
# et rien de tout cela ne fuit dans les autres types.
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
jsonc_ok "$WORK/off/$DC" && pass "OFF: devcontainer.json valide (JSONC)" || bad "OFF: devcontainer.json invalide"

echo "== claude_profile=render-profile : montage du profil =="
if render false "$WORK/prof" --data claude_profile=render-profile; then
  PROF_SRC='${localEnv:HOME}/.claude-profiles/render-profile'
  grep -qF "\"source=$PROF_SRC,target=/home/vscode/.claude,type=bind\"" "$WORK/prof/$DC" \
    && pass "PROFIL: ~/.claude-profiles/render-profile monté sur ~/.claude" || bad "PROFIL: montage du profil absent"
  grep -qF "\"initializeCommand\": \"mkdir -p \\\"$PROF_SRC\\\"\"" "$WORK/prof/$DC" \
    && pass "PROFIL: initializeCommand crée CE dossier (même chemin que la source)" || bad "PROFIL: initializeCommand ne crée pas le dossier du profil"
  grep -qF "$LEGACY_MOUNT" "$WORK/prof/$DC" && bad "PROFIL: le ~/.claude partagé est encore monté" || pass "PROFIL: ~/.claude partagé non monté"
  jsonc_ok "$WORK/prof/$DC" && pass "PROFIL: devcontainer.json valide (JSONC)" || bad "PROFIL: devcontainer.json invalide"
else
  bad "PROFIL: copier a échoué"
fi
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
  for present in .devcontainer/lib-dbt.sh .devcontainer/dbt-run.sh .devcontainer/dbt-doctor.sh \
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
  if grep -rlE '\{\{|\{%' "$D" 2>/dev/null | grep -q .; then
    bad "DBT: marqueurs Jinja non résolus :"; grep -rlE '\{\{|\{%' "$D"
  else pass "DBT: aucun marqueur Jinja non résolu (tous fichiers)"; fi
else
  bad "DBT: copier a échoué"
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
  for present in .devcontainer/lib-dbt.sh .devcontainer/dbt-run.sh .devcontainer/dbt-doctor.sh \
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
for leak in .devcontainer/lib-dbt.sh .devcontainer/dbt-run.sh .devcontainer/dbt-doctor.sh .devcontainer/dbt.conf \
            .devcontainer/features .ignore profiles; do
  [ -e "$WORK/off/$leak" ] && bad "OFF: $leak ne devrait PAS exister" || pass "OFF: pas de $leak"
done
grep -qiE 'gcloud|DBT_|dbtLabs|power-user' "$WORK/off/$DC" && bad "OFF: devcontainer.json référence dbt/gcloud" || pass "OFF: devcontainer.json sans dbt ni gcloud"
grep -q 'lib-dbt' "$WORK/off/.devcontainer/post-create.sh" "$WORK/off/.devcontainer/post-start.sh" \
  && bad "OFF: les hooks référencent lib-dbt.sh" || pass "OFF: hooks sans cycle dbt"
for kept in pyproject.toml Dockerfile src/render_test/__init__.py tests/__init__.py .github/workflows/ci.yml CLAUDE.md README.md justfile; do
  [ -f "$WORK/off/$kept" ] && pass "OFF: $kept toujours généré" || bad "OFF: $kept a disparu"
done

echo "== Vérif marqueurs Jinja non résolus (les deux rendus) =="
if grep -rlE '\{\{|\{%' "$WORK/off" "$WORK/on" --include='*.md' --include='*.conf' --include='*.toml' 2>/dev/null | grep -q .; then
  bad "marqueurs Jinja non résolus trouvés :"; grep -rlE '\{\{|\{%' "$WORK/off" "$WORK/on" --include='*.md' --include='*.conf' --include='*.toml' 2>/dev/null
else
  pass "aucun marqueur Jinja non résolu"
fi

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mTOUS LES CONTRÔLES PASSENT\033[0m"; else echo -e "\033[31mECHECS DETECTES\033[0m"; fi
exit "$fail"
