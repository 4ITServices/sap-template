#!/usr/bin/env bash
# =============================================================================
# test-lib-dbt.sh — tests hors ligne du cycle de vie dbt-project
# -----------------------------------------------------------------------------
# Exerce lib-dbt.sh et dbt-run.sh (project_type=dbt-project) sur un bac à sable
# jetable : aucun réseau, aucun vrai moteur dbt, et un HOME factice — le vrai
# ~/.gitconfig et le vrai ~/.bashrc ne sont jamais touchés.
#
#   - « upstream » et « origin » sont deux dépôts git locaux (bare) ;
#   - uv, l'installeur dbt v2 et les deux moteurs sont des bouchons, ce qui
#     teste la LOGIQUE (worktrees, verrous, garde-fous), pas les téléchargements.
#
# Usage :  scripts/test-lib-dbt.sh
# Prérequis : git (>= 2.31), bash, python3, curl.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
SRC="$REPO_ROOT/template/.devcontainer"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

fail=0
pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else bad "$d"; fi; }
refute() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else pass "$d"; fi; }
has()  { grep -qF -- "$2" <<<"$1"; }

# --- environnement factice ---------------------------------------------------
REAL_USERBASE="$(python3 -m site --user-base 2>/dev/null)"
export HOME="$W/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export DBT_V1_VENV="$W/opt/dbt-v1" DBT_BIN_DIR="$W/bin" DBT_LOG="$W/dbt.log"
export STUB_LOG="$W/stub.log" STUB_DBT="$W/stubs/dbt-engine"
unset DBT_PROFILES_DIR
mkdir -p "$W/stubs" "$W/opt"

# moteur bouchon : `ls` rejoue un fichier, tout le reste dit ce qu'il a reçu
cat > "$STUB_DBT" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo "${STUB_VERSION:-dbt 2.0.0}"; exit 0; fi
for a in "$@"; do
  if [ "$a" = "ls" ]; then echo "ls $*" >> "$STUB_LOG"; cat "${STUB_LS_FILE:-/dev/null}"; exit "${STUB_LS_RC:-0}"; fi
done
echo "ENGINE=$0 CWD=$PWD PROFILES=${DBT_PROFILES_DIR:-} EXTRA=${EXTRA_VAR:-} ARGS=$*"
EOF
# uv bouchon : `venv` pose un interpréteur, `pip install` pose dbt + ses métadonnées
cat > "$W/stubs/uv" <<'EOF'
#!/bin/bash
echo "uv $*" >> "$STUB_LOG"
case "${1:-}" in
  venv) for a in "$@"; do d="$a"; done
        mkdir -p "$d/bin" "$d/lib/python3.12/site-packages"; echo "home = /usr/bin" > "$d/pyvenv.cfg"
        printf '#!/bin/sh\necho "Python 3.12.0"\n' > "$d/bin/python"; chmod +x "$d/bin/python" ;;
  pip)  prev=""; for a in "$@"; do [ "$prev" = "--python" ] && py="$a"; prev="$a"; done
        v="$(dirname "$(dirname "$py")")"
        cp "$STUB_DBT" "$v/bin/dbt"; chmod +x "$v/bin/dbt"
        mkdir -p "$v/lib/python3.12/site-packages/dbt_core-1.10.0.dist-info" ;;
esac
EOF
# installeur dbt v2 bouchon, servi en file://
cat > "$W/stubs/install.sh" <<'EOF'
#!/bin/sh
echo "installer $*" >> "$STUB_LOG"
dest=""; while [ $# -gt 0 ]; do case "$1" in --to) dest="$2"; shift ;; esac; shift; done
mkdir -p "$dest" && cp "$STUB_DBT" "$dest/dbt" && chmod +x "$dest/dbt"
EOF
chmod +x "$W/stubs/"*
export PATH="$W/stubs:$PATH"
export DBT_V2_INSTALLER_URL="file://$W/stubs/install.sh"

# --- dépôts : upstream (le projet dbt d'origine) et origin (l'outillage) -----
git init -q --bare -b main "$W/upstream.git"
git clone -q "$W/upstream.git" "$W/up-src" 2>/dev/null
mkdir -p "$W/up-src/dbt/models"
printf 'name: fake\nprofile: "fake_profile"\n' > "$W/up-src/dbt/dbt_project.yml"
printf 'dbt-core==1.10.0\ndbt-bigquery~=1.10\n' > "$W/up-src/dbt/requirements.txt"
printf 'select 1\n' > "$W/up-src/dbt/models/a.sql"
printf 'target/\ndbt_packages/\nlogs/\n' > "$W/up-src/.gitignore"
git -C "$W/up-src" add -A && git -C "$W/up-src" commit -q -m "upstream project" && git -C "$W/up-src" push -q origin main

git init -q --bare -b main "$W/origin.git"

# make_ws DIR — un clone d'origin équipé comme un projet rendu
make_ws() {
  git clone -q "$W/origin.git" "$1" 2>/dev/null
  mkdir -p "$1/.devcontainer" "$1/profiles"
  cp "$SRC/"*"lib-dbt.sh"* "$1/.devcontainer/lib-dbt.sh"
  cp "$SRC/"*"dbt-run.sh"* "$1/.devcontainer/dbt-run.sh"
  cp "$SRC/"*"dbt-doctor.sh"* "$1/.devcontainer/dbt-doctor.sh"
  printf 'DBT_SEND_ANONYMOUS_USAGE_STATS=false\nEXTRA_VAR=from-env-file\nDBT_PROFILES_DIR=/nowhere\n' > "$1/profiles/dbt.env"
  printf '/v1/\n/v2/\n' > "$1/.gitignore"
}
# conf DIR [lignes…] — écrit le manifeste du projet
conf() {
  local d="$1"; shift
  { echo "DBT_UPSTREAM_URL=\"$W/upstream.git\""; echo 'DBT_PROJECT_SUBDIR="dbt"'
    echo 'DBT_BQ_PROJECT="sandbox-prj"'; echo 'DBT_BQ_DATASET="JDOE_run"'
    echo 'DBT_BQ_DATASET_PREFIX="JDOE"'; echo 'DBT_TARGET_NAME="prd"'
    for l in "$@"; do echo "$l"; done; } > "$d/.devcontainer/dbt.conf"
}
# life DIR MODE — le cycle de vie, dans un shell neuf (comme un hook)
life() { ( cd "$1" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_process "$PWD" "$0"' "${2:-start}" ) 2>&1; }

WS="$W/ws"
make_ws "$WS"; conf "$WS"
git -C "$WS" add -A && git -C "$WS" commit -q -m "scaffold" && git -C "$WS" push -q origin main

# =============================================================================
echo "== Lecture des URL d'origine =="
# shellcheck disable=SC1090
u() { ( source "$WS/.devcontainer/lib-dbt.sh"; _dbt_url_host "$1" ); }
s() { ( source "$WS/.devcontainer/lib-dbt.sh"; _dbt_url_is_ssh "$1" ); }
[ "$(u git@git.example.com:grp/sub/repo.git)" = "git.example.com" ] && pass "hôte d'une URL scp (git@hôte:chemin)" || bad "hôte URL scp"
[ "$(u ssh://git@git.example.com:2222/grp/repo.git)" = "git.example.com" ] && pass "hôte d'une URL ssh:// avec port" || bad "hôte URL ssh://"
[ "$(u https://user@git.example.com/grp/repo.git)" = "git.example.com" ] && pass "hôte d'une URL https avec utilisateur" || bad "hôte URL https"
[ -z "$(u /srv/git/repo.git)" ] && pass "chemin local : pas d'hôte" || bad "chemin local pris pour un hôte"
check  "git@hôte:chemin est SSH" s git@git.example.com:grp/repo.git
refute "https:// n'est pas SSH" s https://user@git.example.com:8443/grp/repo.git

# =============================================================================
echo "== Premier démarrage : tout part de l'upstream =="
OUT="$(life "$WS" create)"
check "v1/ est un worktree sur la branche v1" test "$(git -C "$WS/v1" rev-parse --abbrev-ref HEAD)" = v1
check "v2/ est un worktree sur la branche v2" test "$(git -C "$WS/v2" rev-parse --abbrev-ref HEAD)" = v2
check "v1 part du commit de l'upstream" test "$(git -C "$WS" rev-parse v1)" = "$(git -C "$W/upstream.git" rev-parse main)"
check "v2 part de v1" test "$(git -C "$WS" rev-parse v2)" = "$(git -C "$WS" rev-parse v1)"
check "v1 ne suit pas l'upstream (pas de push par défaut vers lui)" test -z "$(git -C "$WS" config --get branch.v1.remote)"
[ "$(git -C "$WS" worktree list --porcelain | grep -c '^locked')" = 2 ] && pass "les deux worktrees sont verrouillés (prune)" || bad "worktrees non verrouillés"
check "remote upstream : pushurl DISABLED" test "$(git -C "$WS" config --get remote.upstream.pushurl)" = DISABLED
check "remote upstream : pas de tags" test "$(git -C "$WS" config --get remote.upstream.tagOpt)" = "--no-tags"
refute "un push vers upstream échoue" git -C "$WS/v1" push upstream v1:refs/heads/probe
refute "…et l'upstream n'a reçu aucune branche" git -C "$W/upstream.git" rev-parse --verify refs/heads/probe
check "le projet dbt de v1 est trouvé" test -f "$WS/v1/dbt/dbt_project.yml"
check "les worktrees sont déclarés sûrs (safe.directory)" test "$(git config --global --get-all safe.directory | grep -c -E "^$WS/v[12]\$")" = 2
check "aucun worktree n'est sale (fichiers d'éditeur masqués)" test -z "$(git -C "$WS/v1" status --porcelain)$(git -C "$WS/v2" status --porcelain)"
check "la racine ignore v1/ et v2/" test -z "$(git -C "$WS" status --porcelain -- v1 v2)"

echo "== Moteurs =="
check "v1 : venv posé, dbt1 lié" test "$(readlink -f "$DBT_BIN_DIR/dbt1")" = "$(readlink -f "$DBT_V1_VENV/bin/dbt")"
has "$(cat "$STUB_LOG")" "pip install --quiet --python $DBT_V1_VENV/bin/python -r " && pass "v1 : installé depuis les versions épinglées du projet" || bad "v1 : pins du projet non utilisés"
refute "v1 : installé depuis une COPIE isolée (pas le fichier du dépôt)" grep -qF -- "-r $WS/v1/" "$STUB_LOG"
has "$OUT" "dbt Core 1.10.0" && pass "v1 : version lue dans les métadonnées du paquet" || bad "v1 : version non affichée"
check "v2 : binaire posé là où l'extension dbt le cherche" test -x "$DBT_BIN_DIR/dbt"
check "v2 : dbtf est une vraie commande (lien), pas un alias" test "$(readlink "$DBT_BIN_DIR/dbtf")" = dbt
has "$(cat "$STUB_LOG")" "installer --update --to $DBT_BIN_DIR --version latest" && pass "v2 : installeur officiel appelé avec --to et --version" || bad "v2 : appel de l'installeur inattendu"

echo "== Hub de profils =="
HUB="$WS/profiles/profiles.yml"
check "hub généré" test -f "$HUB"
check "…au nom du profil demandé par dbt_project.yml" grep -q '^fake_profile:' "$HUB"
check "…target nommé selon dbt.conf" grep -q '^  target: prd' "$HUB"
check "…projet bac à sable" grep -q 'project: sandbox-prj' "$HUB"
check "…dataset bac à sable" grep -q 'dataset: JDOE_run' "$HUB"
check "…authentification oauth, aucun secret" grep -q 'method: oauth' "$HUB"

echo "== Redémarrage : idempotent =="
echo "# édité à la main" >> "$HUB"
N_UV=$(grep -c '^uv ' "$STUB_LOG"); N_INST=$(grep -c '^installer' "$STUB_LOG")
OUT2="$(life "$WS" start)"
check "le venv n'est pas reconstruit" test "$(grep -c '^uv ' "$STUB_LOG")" = "$N_UV"
check "dbt v2 n'est pas réinstallé ni mis à jour" test "$(grep -c '^installer' "$STUB_LOG")" = "$N_INST"
check "le hub édité à la main n'est pas réécrit" grep -q '# édité à la main' "$HUB"
refute "aucune erreur ni avertissement au redémarrage" grep -qE 'ERROR|WARNING' <<<"$OUT2"
[ "$(grep -c '>>> dbt-project' "$HOME/.bashrc")" = 1 ] && pass "~/.bashrc : un seul bloc après deux passages" || bad "~/.bashrc : bloc dupliqué"
check "~/.bashrc : DBT_PROFILES_DIR pointe le hub" grep -qF "export DBT_PROFILES_DIR=\"$WS/profiles\"" "$HOME/.bashrc"

echo "== Changement des versions épinglées =="
echo "# bump" >> "$WS/v1/dbt/requirements.txt"
life "$WS" start >/dev/null
[ "$(grep -c '^uv venv' "$STUB_LOG")" = 2 ] && pass "le venv est reconstruit quand le fichier de pins change" || bad "venv non reconstruit après changement des pins"
git -C "$WS/v1" checkout -q -- dbt/requirements.txt

echo "== Fichiers d'éditeur dans les worktrees =="
check "v2 : .env pointe profiles/dbt.env" test "$(readlink -f "$WS/v2/dbt/.env")" = "$(readlink -f "$WS/profiles/dbt.env")"
check "v1 : réglages de fenêtre dédiée valides (JSON)" python3 -c "import json; d=json.load(open('$WS/v1/.vscode/settings.json')); assert d['dbt.dbtMajorVersion']=='v1' and d['dbt.allowListFolders']==[]"
check "v2 : dbt Power User y est neutralisé" python3 -c "import json; d=json.load(open('$WS/v2/.vscode/settings.json')); assert d['dbt.dbtMajorVersion']=='v2' and d['dbt.allowListFolders']==['.vscode']"

# =============================================================================
echo "== Garde-fous de dbt-run.sh =="
RUN() { ( cd "${CWD:-$WS}" && bash "$WS/.devcontainer/dbt-run.sh" "$@" ) 2>&1; }
LS_OK="$W/ls-ok.jsonl"; LS_PRJ="$W/ls-prj.jsonl"; LS_PFX="$W/ls-pfx.jsonl"
printf 'log line\n{"database":"sandbox-prj","schema":"JDOE_run","name":"a","resource_type":"model"}\n' > "$LS_OK"
printf '{"database":"real-prd","schema":"JDOE_run","name":"a","resource_type":"model"}\n' > "$LS_PRJ"
printf '{"database":"sandbox-prj","schema":"SALES","name":"a","resource_type":"model"}\n' > "$LS_PFX"
export STUB_LS_FILE="$LS_OK"

O="$(RUN v1 parse)"
has "$O" "ENGINE=$DBT_V1_VENV/bin/dbt" && pass "just v1 → moteur dbt Core" || bad "v1 : mauvais moteur ($O)"
has "$O" "CWD=$WS/v1/dbt " && pass "…lancé depuis le dossier du projet dbt" || bad "v1 : mauvais dossier"
has "$O" "PROFILES=$WS/profiles " && pass "…hub imposé, même si dbt.env tente de le déplacer" || bad "v1 : hub non imposé ($O)"
has "$O" "EXTRA=from-env-file" && pass "…variables de profiles/dbt.env chargées" || bad "v1 : dbt.env non chargé"
O="$(RUN v2 parse)"
has "$O" "ENGINE=$DBT_BIN_DIR/dbt CWD=$WS/v2/dbt " && pass "just v2 → moteur dbt v2, dans v2/" || bad "v2 : mauvais moteur ou dossier ($O)"

O="$(RUN v1 run)";                      has "$O" "without a selection" && pass "écriture sans sélection : refusée" || bad "écriture sans sélection acceptée ($O)"
O="$(RUN v1 run-operation m)";          has "$O" "run-operation is refused" && pass "run-operation : refusé" || bad "run-operation accepté"
O="$(RUN v1 parse --profiles-dir /x)";  has "$O" "--profiles-dir is not allowed" && pass "--profiles-dir : refusé" || bad "--profiles-dir accepté"
O="$(RUN v1 retry)";                    has "$O" "retry replays" && pass "retry : refusé (sélection invérifiable)" || bad "retry accepté"
O="$(STUB_LS_FILE="$LS_PRJ" RUN v1 run -s a)"
has "$O" "outside the sandbox" && has "$O" "real-prd.JDOE_run" && pass "écriture vers un AUTRE PROJET : refusée, cible nommée" || bad "écriture hors projet acceptée ($O)"
refute "…et le moteur n'a pas été lancé" grep -qF "ARGS=run" <<<"$O"
O="$(STUB_LS_FILE="$LS_PFX" RUN v1 build --select a)"
has "$O" "outside the sandbox" && has "$O" "sandbox-prj.SALES" && pass "écriture vers un dataset SANS le préfixe : refusée" || bad "dataset sans préfixe accepté ($O)"
O="$(STUB_LS_RC=1 RUN v2 run -s a)"
has "$O" "destination is unknown" && pass "destination irrésoluble (dbt ls en échec) : refusée" || bad "destination inconnue acceptée ($O)"
O="$(RUN v1 run -s a --full-refresh)"
has "$O" "all inside the sandbox" && has "$O" "ARGS=run -s a --full-refresh" && pass "écriture dans le bac à sable : acceptée, arguments intacts" || bad "écriture légitime refusée ($O)"
has "$(tail -1 "$STUB_LOG")" "--output json --output-keys database schema alias name resource_type package_name -s a" && pass "…la sélection de l'utilisateur est celle qui est contrôlée" || bad "contrôle fait sur une autre sélection"
O="$(RUN v1 compile -s a)"
has "$O" "ARGS=compile -s a" && pass "lecture (compile) : aucun contrôle de destination" || bad "compile bloqué ($O)"
conf "$WS" 'DBT_SANDBOX_NEVER_BUILD="autre.x fake.a"'
O="$(RUN v1 run -s a)"
has "$O" "never built in the sandbox" && has "$O" "fake.a" && has "$O" "--exclude a" && pass "DBT_SANDBOX_NEVER_BUILD : écriture refusée, nœud nommé, exclusion proposée" || bad "nœud jamais construit accepté ($O)"
refute "…et le moteur n'a pas été lancé" grep -qF "ARGS=run" <<<"$O"
O="$(RUN v2 build --select a)";  has "$O" "never built in the sandbox" && pass "…v2 aussi" || bad "v2 : nœud jamais construit accepté ($O)"
O="$(RUN v1 compile -s a)";      has "$O" "ARGS=compile -s a" && pass "…lecture (compile) : non concernée" || bad "compile bloqué par DBT_SANDBOX_NEVER_BUILD ($O)"
conf "$WS" 'DBT_SANDBOX_NEVER_BUILD="fake.ab autre.a"'
O="$(RUN v1 run -s a)";          has "$O" "all inside the sandbox" && pass "…nom exact, paquet compris : fake.ab et autre.a ne touchent pas fake.a" || bad "correspondance trop large ($O)"
conf "$WS"

printf "{{ config(post_hook='truncate table x') }}\nselect 1\n" > "$WS/v1/dbt/models/hooked.sql"
O="$(RUN v1 run -s a)"; has "$O" "hooks nobody has reviewed" && has "$O" "models/hooked.sql" && pass "post_hook dans un modèle : écriture refusée, fichier nommé" || bad "hook de modèle non détecté ($O)"
conf "$WS" 'DBT_HOOKS_REVIEWED=1'
O="$(RUN v1 run -s a)"; has "$O" "ARGS=run -s a" && pass "…acceptée après DBT_HOOKS_REVIEWED=1" || bad "hooks relus mais écriture refusée ($O)"
rm -f "$WS/v1/dbt/models/hooked.sql"; conf "$WS"

echo "== Hooks des packages installés, et commandes qui les exécutent selon le moteur =="
printf 'name: fake\nprofile: "fake_profile"\n# on-run-start:\n#   - "{{ old_hook() }}"\n' > "$WS/v1/dbt/dbt_project.yml"
O="$(RUN v1 run -s a)"; has "$O" "all inside the sandbox" && pass "hook en commentaire (# on-run-start:) : ignoré" || bad "commentaire pris pour un hook ($O)"
git -C "$WS/v1" checkout -q -- dbt/dbt_project.yml
for V in v1 v2; do mkdir -p "$WS/$V/dbt/dbt_packages/elem"; printf 'name: elem\non-run-end:\n  - "{{ elem.on_run_end() }}"\n' > "$WS/$V/dbt/dbt_packages/elem/dbt_project.yml"; done
O="$(RUN v1 run -s a)"; has "$O" "hooks nobody has reviewed" && has "$O" "dbt_packages/elem/dbt_project.yml" && pass "on-run-end d'un package installé : écriture refusée, package nommé" || bad "hook de package non détecté ($O)"
O="$(RUN v1 test)";            has "$O" "hooks nobody has reviewed" && pass "v1 test : refusé (dbt Core exécute les hooks sur test)" || bad "v1 test non gardé ($O)"
O="$(RUN v1 source freshness)"; has "$O" "hooks nobody has reviewed" && pass "v1 source freshness : refusé (RunTask aussi)" || bad "v1 freshness non gardé ($O)"
O="$(RUN v1 compile -s a)";    has "$O" "ARGS=compile -s a" && pass "v1 compile : accepté (dbt Core n'exécute aucun hook sur compile)" || bad "v1 compile bloqué à tort ($O)"
O="$(RUN v1 ls)";              ! has "$O" "⛔" && has "$O" "log line" && pass "v1 ls : accepté" || bad "v1 ls bloqué à tort ($O)"
O="$(RUN v2 compile -s a)";    has "$O" "hooks nobody has reviewed" && has "$O" "compile and show too" && pass "v2 compile : refusé (dbt v2 exécute on-run-start sur compile)" || bad "v2 compile non gardé ($O)"
O="$(RUN v2 show -s a)";       has "$O" "hooks nobody has reviewed" && pass "v2 show : refusé" || bad "v2 show non gardé ($O)"
O="$(RUN v2 parse)";           has "$O" "ARGS=parse" && pass "v2 parse : accepté (aucun hook)" || bad "v2 parse bloqué à tort ($O)"
O="$(RUN v2 ls -s a)";         ! has "$O" "⛔" && has "$O" "log line" && pass "v2 ls : accepté (c'est lui qui résout les destinations)" || bad "v2 ls bloqué à tort ($O)"
conf "$WS" 'DBT_HOOKS_COMPILE_OK="project"'
O="$(RUN v2 compile -s a)";    has "$O" "ARGS=compile -s a" && has "$O" "DBT_HOOKS_COMPILE_OK" && pass "DBT_HOOKS_COMPILE_OK : v2 compile accepté, et dit pourquoi" || bad "compile refusé malgré DBT_HOOKS_COMPILE_OK ($O)"
O="$(RUN v2 show -s a)";       has "$O" "ARGS=show -s a" && pass "…v2 show accepté" || bad "show refusé malgré DBT_HOOKS_COMPILE_OK ($O)"
O="$(RUN v2 compile -s test)"; has "$O" "hooks nobody has reviewed" && pass "…compile + un mot qui exécute des hooks (test) : refusé" || bad "compile -s test accepté ($O)"
O="$(RUN v2 run -s a)";        has "$O" "hooks nobody has reviewed" && pass "…v2 run : toujours refusé" || bad "run accepté par DBT_HOOKS_COMPILE_OK ($O)"
mkdir -p "$WS/v2/dbt/dbt_packages/elementary"; printf 'name: elementary
on-run-end:
  - "{{ elementary.on_run_end() }}"
' > "$WS/v2/dbt/dbt_packages/elementary/dbt_project.yml"
O="$(ELEMENTARY=1 RUN v2 compile -s a)"; has "$O" "ELEMENTARY is not 0" && pass "…hooks d'elementary avec ELEMENTARY=1 : refusé" || bad "elementary actif accepté ($O)"
O="$(ELEMENTARY=0 RUN v2 compile -s a)"; has "$O" "ARGS=compile -s a" && pass "…hooks d'elementary avec ELEMENTARY=0 : accepté" || bad "elementary coupé mais refusé ($O)"
rm -rf "$WS/v2/dbt/dbt_packages/elementary"
conf "$WS" 'DBT_HOOKS_COMPILE_OK="autre"'
O="$(RUN v2 compile -s a)";    has "$O" "hooks nobody has reviewed" && pass "…projet absent de la liste : refusé" || bad "liste ignorée ($O)"
conf "$WS" 'DBT_HOOKS_REVIEWED=1'
O="$(RUN v2 compile -s a)";    has "$O" "ARGS=compile -s a" && pass "…v2 compile accepté après DBT_HOOKS_REVIEWED=1" || bad "v2 compile refusé après relecture ($O)"
O="$(RUN v1 test)";            has "$O" "ARGS=test" && pass "…v1 test accepté après DBT_HOOKS_REVIEWED=1" || bad "v1 test refusé après relecture ($O)"
conf "$WS"
rm -rf "$WS/v1/dbt/dbt_packages" "$WS/v2/dbt/dbt_packages"

printf 'packages:\n  - package: acme/elem\n    version: 1.0.0\n' > "$WS/v2/dbt/packages.yml"
O="$(RUN v2 compile -s a)"; has "$O" "packages are not installed" && has "$O" "just v2 deps" && pass "packages déclarés mais pas installés : hooks invérifiables, refusé" || bad "packages non installés non signalés ($O)"
O="$(RUN v2 deps)";         has "$O" "ARGS=deps" && pass "…deps reste possible (aucun hook)" || bad "deps bloqué à tort ($O)"
mkdir -p "$WS/v2/dbt/dbt_packages/elem"; printf 'name: elem\n' > "$WS/v2/dbt/dbt_packages/elem/dbt_project.yml"
O="$(RUN v2 compile -s a)"; has "$O" "ARGS=compile -s a" && pass "…une fois installés et sans hook : accepté" || bad "packages installés sans hook mais refusé ($O)"
rm -rf "$WS/v2/dbt/dbt_packages" "$WS/v2/dbt/packages.yml"

conf "$WS" 'DBT_BQ_PROJECT=""'
O="$(RUN v1 run -s a)"; has "$O" "DBT_BQ_PROJECT is empty" && pass "aucun bac à sable déclaré : toute écriture refusée" || bad "écriture sans bac à sable acceptée ($O)"
conf "$WS"

O="$(CWD="$WS/v1/dbt/models" RUN auto compile)"
has "$O" "ENGINE=$DBT_V1_VENV/bin/dbt CWD=$WS/v1/dbt/models " && pass "\`dbt\` dans v1/ → dbt Core, sans quitter le dossier courant" || bad "auto v1 ($O)"
O="$(CWD="$WS/v2" RUN auto compile)"
has "$O" "ENGINE=$DBT_BIN_DIR/dbt CWD=$WS/v2/dbt " && pass "\`dbt\` dans v2/ → dbt v2, ramené au dossier du projet" || bad "auto v2 ($O)"
O="$(CWD="$WS" RUN auto --version)"
has "$O" "dbt 2.0.0" && pass "\`dbt\` hors worktree → dbt v2 nu" || bad "auto hors worktree ($O)"
O="$(CWD="$WS/v1" RUN auto run)"; has "$O" "without a selection" && pass "\`dbt run\` tapé dans v1/ passe par le garde-fou" || bad "auto non gardé ($O)"

# =============================================================================
echo "== Destinations v1 / v2 =="
A="$W/dest-a.jsonl"
printf '{"database":"sandbox-prj","schema":"JDOE_other","name":"a","resource_type":"model"}\n{"database":"sandbox-prj","schema":"JDOE_run","name":"b","resource_type":"model"}\n' > "$A"
cat > "$W/stubs/dbt-split" <<EOF
#!/bin/bash
case "\$0" in *dbt-v1*) cat "$LS_OK" ;; *) cat "$A" ;; esac
EOF
chmod +x "$W/stubs/dbt-split"
cp "$W/stubs/dbt-split" "$DBT_V1_VENV/bin/dbt"; cp "$W/stubs/dbt-split" "$DBT_BIN_DIR/dbt"
O="$(RUN destinations)"
has "$O" "1 node(s) written elsewhere" && has "$O" "model a: sandbox-prj.JDOE_run  ->  sandbox-prj.JDOE_other" && pass "un modèle déplacé par v2 est signalé" || bad "écart de destination non signalé ($O)"
has "$O" "only in v2: model b" && pass "un modèle présent d'un seul côté est signalé" || bad "modèle orphelin non signalé"
printf '{"database":"sandbox-prj","schema":"run","name":"a","resource_type":"model"}\n' > "$W/dest-v1-bare.jsonl"
printf '{"database":"sandbox-prj","schema":"JDOE_run","name":"a","resource_type":"model"}\n' > "$W/dest-v2-pfx.jsonl"
cat > "$W/stubs/dbt-split" <<EOF
#!/bin/bash
case "\$0" in *dbt-v1*) cat "$W/dest-v1-bare.jsonl" ;; *) cat "$W/dest-v2-pfx.jsonl" ;; esac
EOF
cp "$W/stubs/dbt-split" "$DBT_V1_VENV/bin/dbt"; cp "$W/stubs/dbt-split" "$DBT_BIN_DIR/dbt"
O="$(RUN destinations)"
has "$O" "0 node(s) written elsewhere (sandbox prefix JDOE_" && pass "v1 sans le préfixe du bac à sable, v2 avec : pas un déplacement" || bad "préfixe du bac à sable compté comme un déplacement ($O)"
printf '{"database":"sandbox-prj","schema":"JDOE_FAKE__RUN","name":"a","resource_type":"model"}\n' > "$W/dest-v2-pfx.jsonl"
O="$(RUN destinations)"
has "$O" "0 node(s) written elsewhere" && has "$O" "namespace FAKE__ ignored" && pass "v2 dans l'espace de noms du produit (<PREFIXE>_<PACKAGE>__) : pas un déplacement" || bad "espace de noms compté comme un déplacement ($O)"
printf '{"database":"sandbox-prj","schema":"JDOE_AUTRE__RUN","name":"a","resource_type":"model"}\n' > "$W/dest-v2-pfx.jsonl"
O="$(RUN destinations)"
has "$O" "1 node(s) written elsewhere" && pass "…l'espace de noms d'un autre package reste un déplacement" || bad "espace de noms étranger ignoré à tort ($O)"
cp "$STUB_DBT" "$DBT_V1_VENV/bin/dbt"; cp "$STUB_DBT" "$DBT_BIN_DIR/dbt"

# =============================================================================
echo "== Doctor : ce que le serveur VS Code du container a installé et activé =="
DOC() { ( cd "$WS" && bash .devcontainer/dbt-doctor.sh ) 2>/dev/null | sed -n '/^\[editor/,/^\[MCP/p'; }
O="$(DOC)"; has "$O" "no VS Code server in this container" && pass "pas de serveur VS Code : dit, sans erreur" || bad "absence de serveur VS Code mal gérée ($O)"
X="$HOME/.vscode-server/extensions"; LG="$HOME/.vscode-server/data/logs/20260101T000000/exthost1"
mkdir -p "$X/dbtlabsinc.dbt-0.111.0" "$X/innoverio.vscode-dbt-power-user-0.64.7" "$X/innoverio.vscode-dbt-power-user-0.60.0" "$LG"
echo '{"name":"dbt"}' > "$X/dbtlabsinc.dbt-0.111.0/package.json"
echo '{"name":"pu","extensionDependencies":["ms-python.python","samuelcolvin.jinjahtml"]}' > "$X/innoverio.vscode-dbt-power-user-0.64.7/package.json"
reg() { printf '[%s]\n' "$1" > "$X/extensions.json"; }
E_DBT='{"identifier":{"id":"dbtlabsinc.dbt"},"version":"0.111.0","relativeLocation":"dbtlabsinc.dbt-0.111.0"}'
E_PU='{"identifier":{"id":"innoverio.vscode-dbt-power-user"},"version":"0.64.7","relativeLocation":"innoverio.vscode-dbt-power-user-0.64.7"}'
E_PY='{"identifier":{"id":"ms-python.python"},"version":"1.0.0","relativeLocation":"x"},{"identifier":{"id":"samuelcolvin.jinjahtml"},"version":"1.0.0","relativeLocation":"y"}'
echo "2026-01-01 00:00:01.000 [info] ExtensionService#_doActivateExtension dbtLabsInc.dbt, startup: false, activationEvent: 'workspaceContains:**/dbt_project.yml'" > "$LG/remoteexthost.log"

reg "$E_DBT"
O="$(DOC)"
has "$O" "✅ dbtLabsInc.dbt 0.111.0 installed in the container" && pass "extension inscrite au registre du serveur : installée (version lue)" || bad "extension inscrite non reconnue ($O)"
has "$O" "✅ dbtLabsInc.dbt active in the last VS Code window (activated on workspaceContains:**/dbt_project.yml)" && pass "…et son activation est lue dans le journal de la fenêtre" || bad "activation non lue ($O)"
has "$O" "❌ innoverio.vscode-dbt-power-user is NOT installed in the container — a leftover folder is there" && pass "dossier présent mais absent du registre : NON installée (l'ancien contrôle disait oui)" || bad "dossier orphelin pris pour une installation ($O)"
reg "$E_DBT,$E_PU"
O="$(DOC)"
has "$O" "✅ innoverio.vscode-dbt-power-user 0.64.7 installed" && pass "seconde extension inscrite : installée" || bad "seconde extension non reconnue"
has "$O" "cannot start: it depends on ms-python.python, samuelcolvin.jinjahtml" && pass "…dépendances manquantes : signalées (lues dans son package.json)" || bad "dépendances manquantes non signalées ($O)"
reg "$E_DBT,$E_PU,$E_PY"
O="$(DOC)"
refute "dépendances présentes : plus de signalement" grep -q "cannot start" <<<"$O"
has "$O" "innoverio.vscode-dbt-power-user did NOT start in the last VS Code window" && pass "installée mais jamais activée : dit, avec les deux causes possibles" || bad "non-activation non signalée ($O)"
echo "2026-01-01 00:00:02.000 [error] Activating extension 'innoverio.vscode-dbt-power-user' failed: boom" >> "$LG/remoteexthost.log"
O="$(DOC)"; has "$O" "❌ innoverio.vscode-dbt-power-user was activated and FAILED" && pass "activation en échec : signalée" || bad "échec d'activation non signalé ($O)"
rm -rf "$HOME/.vscode-server"

O="$( (cd "$WS" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null | sed -n '/^\[hooks/,/^\[BigQuery/p')"
has "$O" "✅ v1: no hook, neither in the project nor in its installed packages" && pass "doctor : « aucun hook » dit quand c'est vrai" || bad "doctor : section hooks inattendue ($O)"
mkdir -p "$WS/v2/dbt/dbt_packages/elem"; printf 'name: elem\non-run-end:\n  - "x"\n' > "$WS/v2/dbt/dbt_packages/elem/dbt_project.yml"
O="$( (cd "$WS" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null | sed -n '/^\[hooks/,/^\[BigQuery/p')"
has "$O" "v2: hooks in dbt_packages/elem/dbt_project.yml" && has "$O" "compile show docs" && pass "doctor : hooks d'un package listés, avec les commandes refusées" || bad "doctor : hooks de package non listés ($O)"
rm -rf "$WS/v2/dbt/dbt_packages"

# =============================================================================
echo "== Clone neuf : les branches viennent d'origin, sans l'upstream =="
git -C "$WS" push -q origin v1 v2 2>/dev/null
WS2="$W/ws2"; make_ws "$WS2"; conf "$WS2"
sed -i "s#^DBT_UPSTREAM_URL=.*#DBT_UPSTREAM_URL=\"$W/absent.git\"#" "$WS2/.devcontainer/dbt.conf"
rm -rf "$DBT_V1_VENV" "$DBT_BIN_DIR"
OUT="$(life "$WS2" create)"
check "v1/ créé depuis origin/v1" test "$(git -C "$WS2/v1" rev-parse HEAD)" = "$(git -C "$WS" rev-parse v1)"
check "…et suit origin (git push/pull naturels)" test "$(git -C "$WS2" config --get branch.v1.remote)" = origin
check "v2/ créé depuis origin/v2" test -f "$WS2/v2/dbt/dbt_project.yml"
refute "aucun accès à l'upstream n'a été tenté" grep -q "fetching upstream" <<<"$OUT"

echo "== Dossier de travail renommé : les liens des worktrees sont réparés =="
mv "$WS2" "$W/ws2-moved"; WS2="$W/ws2-moved"
refute "avant réparation, v1/ est cassé" git -C "$WS2/v1" status
life "$WS2" start >/dev/null
check "après redémarrage, v1/ fonctionne" git -C "$WS2/v1" status
check "…v2/ aussi" git -C "$WS2/v2" status
check "~/.bashrc suit le nouveau chemin" grep -qF "$WS2/.devcontainer/dbt-run.sh" "$HOME/.bashrc"
[ "$(grep -c '>>> dbt-project' "$HOME/.bashrc")" = 1 ] && pass "…toujours un seul bloc" || bad "~/.bashrc : bloc dupliqué après renommage"
check "les réglages de fenêtre dédiée suivent le nouveau chemin" grep -qF "$WS2/.devcontainer/tmux-session.sh" "$WS2/v1/.vscode/settings.json"

echo "== Worktree supprimé à la main : recréé ; dossier étranger : jamais effacé =="
rm -rf "$WS2/v1"
life "$WS2" start >/dev/null
check "v1/ supprimé puis recréé (verrou levé, prune)" test "$(git -C "$WS2/v1" rev-parse --abbrev-ref HEAD)" = v1
WS5="$W/ws5"; make_ws "$WS5"; conf "$WS5"
mkdir -p "$WS5/v2"; echo "précieux" > "$WS5/v2/notes.txt"
OUT="$(life "$WS5" start)"
has "$OUT" "v2/ exists but is not a worktree" && pass "dossier étranger dans v2/ : signalé" || bad "dossier étranger non signalé"
check "…son contenu est intact" grep -q précieux "$WS5/v2/notes.txt"
refute "…et il n'a pas été converti en worktree" test -e "$WS5/v2/.git"
check "…sans empêcher v1/ d'être créé" test -f "$WS5/v1/dbt/dbt_project.yml"

echo "== Un dossier qui n'est pas un venv à la place du venv : jamais vidé =="
rm -rf "$DBT_V1_VENV"; mkdir -p "$DBT_V1_VENV"; echo "précieux" > "$DBT_V1_VENV/data.txt"
OUT="$(life "$WS5" start)"
has "$OUT" "is not a virtualenv" && pass "dossier étranger à l'emplacement du venv : signalé" || bad "dossier étranger non signalé (venv)"
check "…et son contenu est intact" grep -q précieux "$DBT_V1_VENV/data.txt"
rm -rf "$DBT_V1_VENV"

echo "== Un autre dbt à la place de dbt v2 : jamais écrasé =="
printf '#!/bin/sh\necho "Core: installed: 1.10.0"\n' > "$DBT_BIN_DIR/dbt"; chmod +x "$DBT_BIN_DIR/dbt"
N_INST=$(grep -c '^installer' "$STUB_LOG")
OUT="$(life "$WS2" start)"
has "$OUT" "is not dbt v2" && pass "binaire étranger signalé" || bad "binaire étranger non signalé"
check "…et laissé en place" test "$(grep -c '^installer' "$STUB_LOG")" = "$N_INST"

# =============================================================================
echo "== Hôte d'origine en SSH : clé épinglée, HTTPS→SSH, verrou de push =="
WS3="$W/ws3"; make_ws "$WS3"; conf "$WS3"
sed -i 's#^DBT_UPSTREAM_URL=.*#DBT_UPSTREAM_URL="git@git.invalid:grp/repo.git"#' "$WS3/.devcontainer/dbt.conf"
echo "git.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAkeyforteststestsaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$WS3/.devcontainer/upstream_known_hosts"
rm -f "$HOME/.gitconfig"
( cd "$WS3" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' ) >/dev/null 2>&1
G() { git config --global "$@"; }
has "$(G --get core.sshCommand)" "UserKnownHostsFile=$WS3/.devcontainer/upstream_known_hosts $HOME/.ssh/known_hosts" && pass "core.sshCommand : clé épinglée d'abord, ~/.ssh/known_hosts ensuite" || bad "core.sshCommand inattendu"
check "https://hôte/ est lu en SSH (packages dbt privés)" test "$(G --get url.git@git.invalid:.insteadOf)" = "https://git.invalid/"
[ "$(G --get-all url.DISABLED://.pushInsteadOf | wc -l)" = 3 ] && pass "verrou de push : scp, ssh:// et https://" || bad "verrou de push incomplet"
O="$(git -C "$WS3" push git@git.invalid:grp/repo.git HEAD:refs/heads/x 2>&1)"
has "$O" "DISABLED" && pass "push par URL explicite : refusé par git avant tout accès réseau" || bad "push par URL explicite non verrouillé ($O)"
( cd "$WS3" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' ) >/dev/null 2>&1
[ "$(G --get-all url.DISABLED://.pushInsteadOf | wc -l)" = 3 ] && pass "verrou rejoué : aucune entrée dupliquée" || bad "verrou dupliqué"
G core.sshCommand "ssh -i /custom/key"
( cd "$WS3" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' ) >/dev/null 2>&1
check "un core.sshCommand personnalisé n'est pas écrasé" test "$(G --get core.sshCommand)" = "ssh -i /custom/key"
G --add url.DISABLED://.pushInsteadOf "git@other.invalid:"
echo 'DBT_UPSTREAM_PUSH_LOCK=0' >> "$WS3/.devcontainer/dbt.conf"
OUT="$( cd "$WS3" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' 2>&1 )"
refute "DBT_UPSTREAM_PUSH_LOCK=0 lève le verrou de cet hôte…" grep -q "git.invalid" <<<"$(G --get-all url.DISABLED://.pushInsteadOf)"
check "…sans toucher au verrou posé pour un autre hôte" test "$(G --get-all url.DISABLED://.pushInsteadOf)" = "git@other.invalid:"
has "$OUT" "UNLOCKED" && pass "…et le dit en clair" || bad "levée du verrou silencieuse"

echo "== Sans bac à sable déclaré : dbt reste verrouillé =="
WS4="$W/ws4"; make_ws "$WS4"; conf "$WS4" 'DBT_BQ_PROJECT=""' 'DBT_BQ_DATASET=""'
OUT="$(life "$WS4" create)"
refute "aucun profiles.yml généré" test -f "$WS4/profiles/profiles.yml"
has "$OUT" "dbt stays LOCKED" && pass "…et le hook l'annonce" || bad "absence de hub non annoncée"

# =============================================================================
echo "== Flotte (dbt-fleet) : deux produits, une v1 commune, un projet global =="
# mkup NAME SUBDIR PROFILE PIN — un dépôt d'origine local portant un projet dbt
mkup() {
  local N="$1" SUB="$2" PROF="$3" PIN="$4" D="$W/fleet-src/$1"
  git init -q --bare -b main "$W/fleet-up/$N.git"
  git clone -q "$W/fleet-up/$N.git" "$D" 2>/dev/null
  mkdir -p "$D/$SUB/models"
  printf 'name: %s\nprofile: "%s"\n' "${N//-/_}" "$PROF" > "$D/$SUB/dbt_project.yml"
  printf 'dbt-core==%s\n' "$PIN" > "$D/$SUB/requirements.txt"
  printf 'select 1\n' > "$D/$SUB/models/m_$N.sql"
  printf 'target/\ndbt_packages/\nlogs/\n' > "$D/.gitignore"
  git -C "$D" add -A && git -C "$D" commit -q -m "upstream $N" && git -C "$D" push -q origin main
}
mkup alpha dbt prof_alpha 1.9.8
mkup beta . prof_shared 1.10.0
mkup gamma dbt prof_shared 1.10.0
git init -q --bare -b main "$W/fleet-origin.git"
FW="$W/fleet"
git clone -q "$W/fleet-origin.git" "$FW" 2>/dev/null
mkdir -p "$FW/.devcontainer" "$FW/profiles/env" "$FW/global/macros"
for f in lib-dbt.sh dbt-run.sh dbt-doctor.sh; do cp "$SRC/"*"$f"* "$FW/.devcontainer/$f"; done
printf 'DBT_SEND_ANONYMOUS_USAGE_STATS=false\nFLEET_COMMON=1\n' > "$FW/profiles/dbt.env"
printf 'BETA_ONLY=1\n' > "$FW/profiles/env/beta.env"
printf '/v1/\n/v2/\n' > "$FW/.gitignore"
cat > "$FW/.devcontainer/dbt.conf" <<EOF
DBT_FLEET=1
DBT_V1_PINS="dbt-core==1.10.0 dbt-bigquery==1.10.0"
DBT_BQ_PROJECT="sandbox-prj"
DBT_BQ_DATASET="JDOE_run"
DBT_BQ_DATASET_PREFIX="JDOE"
DBT_TARGET_NAME="prd"
EOF
cat > "$FW/.devcontainer/products.conf" <<EOF
# NAME  URL  BRANCH  SUBDIR  GLOBAL
alpha   $W/fleet-up/alpha.git  main  dbt  yes
beta    $W/fleet-up/beta.git   -     .    no   # projet à la racine
EOF
printf 'name: fleet_global\nprofile: "prof_global"\n' > "$FW/global/dbt_project.yml"
cp "$REPO_ROOT/template/"*"global"*"/packages.yml" "$FW/global/packages.yml"
git -C "$FW" add -A && git -C "$FW" commit -q -m "fleet scaffold" && git -C "$FW" push -q origin main
rm -rf "$DBT_V1_VENV" "$DBT_BIN_DIR"; : > "$STUB_LOG"
OUT="$(life "$FW" create)"

for x in "alpha v1" "alpha v2" "beta v1" "beta v2"; do set -- $x
  check "$1 : $2/$1/ est un worktree sur la branche $1/$2" test "$(git -C "$FW/$2/$1" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$1/$2"
done
check "alpha/v1 part de son dépôt d'origine" test "$(git -C "$FW" rev-parse alpha/v1)" = "$(git -C "$W/fleet-up/alpha.git" rev-parse main)"
check "alpha/v2 part de alpha/v1" test "$(git -C "$FW" rev-parse alpha/v2)" = "$(git -C "$FW" rev-parse alpha/v1)"
[ "$(git -C "$FW" worktree list --porcelain | grep -c '^locked')" = 4 ] && pass "les quatre worktrees sont verrouillés" || bad "worktrees de la flotte non verrouillés"
check "remote up-alpha : pushurl DISABLED" test "$(git -C "$FW" config --get remote.up-alpha.pushurl)" = DISABLED
check "remote up-beta : pushurl DISABLED" test "$(git -C "$FW" config --get remote.up-beta.pushurl)" = DISABLED
refute "un push vers un dépôt d'origine échoue" git -C "$FW/v1/alpha" push up-alpha alpha/v1:refs/heads/probe
has "$(cat "$STUB_LOG")" "pip install --quiet --python $DBT_V1_VENV/bin/python dbt-core==1.10.0 dbt-bigquery==1.10.0" && pass "v1 commune : venv construit depuis DBT_V1_PINS" || bad "v1 commune : DBT_V1_PINS non utilisé"
[ "$(grep -c '^uv venv' "$STUB_LOG")" = 1 ] && pass "…une seule venv pour toute la flotte" || bad "plusieurs venvs construites"
grep -qxF "  - local: ../v2/alpha/dbt" "$FW/global/packages.yml" && pass "global/ : alpha (GLOBAL yes) en package local" || bad "global/ : alpha absent du bloc géré"
refute "global/ : beta (GLOBAL no) n'y est pas" grep -q "v2/beta" "$FW/global/packages.yml"
for pf in prof_alpha prof_shared prof_global; do grep -q "^$pf:" "$FW/profiles/profiles.yml" || { bad "hub : profil $pf manquant"; continue; }; done
[ "$(grep -cE '^prof_(alpha|shared|global):' "$FW/profiles/profiles.yml")" = 3 ] && pass "hub : un profil par nom demandé (produits + global), sans doublon" || bad "hub de la flotte incomplet"
check "alpha : .env de v2 -> profiles/dbt.env (commun)" test "$(readlink -f "$FW/v2/alpha/dbt/.env")" = "$(readlink -f "$FW/profiles/dbt.env")"
check "beta : .env de v2 -> profiles/env/beta.env (propre au produit)" test "$(readlink -f "$FW/v2/beta/.env")" = "$(readlink -f "$FW/profiles/env/beta.env")"
check "global/.env -> profiles/dbt.env" test "$(readlink -f "$FW/global/.env")" = "$(readlink -f "$FW/profiles/dbt.env")"
check "racine propre (worktrees ignorés)" test -z "$(git -C "$FW" status --porcelain -- v1 v2)"

FRUN() { ( cd "${CWD:-$FW}" && bash "$FW/.devcontainer/dbt-run.sh" "$@" ) 2>&1; }
O="$(FRUN v1 alpha parse)"; has "$O" "ENGINE=$DBT_V1_VENV/bin/dbt CWD=$FW/v1/alpha/dbt " && has "$O" "PROFILES=$FW/profiles " && pass "just v1 alpha → dbt Core commun, dans v1/alpha/dbt" || bad "v1 alpha ($O)"
O="$(FRUN v2 beta parse)"; has "$O" "ENGINE=$DBT_BIN_DIR/dbt CWD=$FW/v2/beta " && pass "just v2 beta → dbt v2, projet à la racine du worktree" || bad "v2 beta ($O)"
O="$(FRUN v1 parse)"; has "$O" "which product?" && pass "sans produit : refusé, liste des produits" || bad "produit manquant non signalé ($O)"
O="$(FRUN v1 nope parse)"; has "$O" "unknown product 'nope'" && pass "produit inconnu : refusé" || bad "produit inconnu accepté ($O)"
O="$(CWD="$FW/v2/alpha/dbt/models" FRUN auto parse)"; has "$O" "CWD=$FW/v2/alpha/dbt/models" && has "$O" "ENGINE=$DBT_BIN_DIR/dbt" && pass "\`dbt\` dans v2/alpha/ → dbt v2 sur alpha" || bad "auto v2 alpha ($O)"
O="$(CWD="$FW/global" FRUN auto parse)"; has "$O" "ENGINE=$DBT_BIN_DIR/dbt CWD=$FW/global " && pass "\`dbt\` dans global/ → dbt v2 sur global" || bad "auto global ($O)"
O="$(FRUN global compile)"; has "$O" "packages are not installed" && has "$O" "just global deps" && pass "global : packages locaux pas encore installés → compile refusé" || bad "global sans packages ($O)"
mkdir -p "$FW/global/dbt_packages"; ln -sfn ../../v2/alpha/dbt "$FW/global/dbt_packages/alpha"
O="$(FRUN global compile)"; has "$O" "ARGS=compile" && pass "…installés et sans hook : compile accepté" || bad "global compile ($O)"
printf '{"database":"sandbox-prj","schema":"JDOE_X","alias":"T","name":"a","resource_type":"model","package_name":"alpha"}\n{"database":"sandbox-prj","schema":"JDOE_X","alias":"T","name":"b","resource_type":"model","package_name":"gamma"}\n' > "$W/ls-dup.jsonl"
O="$(STUB_LS_FILE="$W/ls-dup.jsonl" FRUN global run -s a)"; has "$O" "written by several nodes" && has "$O" "alpha.a, gamma.b" && pass "global : deux nœuds écrivant la même table → écriture refusée" || bad "collision non détectée ($O)"
O="$(STUB_LS_FILE="$W/ls-dup.jsonl" FRUN destinations global)"; has "$O" "1 relation(s) written by several nodes" && pass "just destinations global : collisions listées" || bad "destinations global ($O)"
O="$(STUB_LS_FILE="$LS_OK" FRUN global run -s a)"; has "$O" "all inside the sandbox" && has "$O" "ARGS=run -s a" && pass "global : écriture dans le bac à sable, sans collision → acceptée" || bad "global run légitime refusé ($O)"

O="$(FRUN product-add gamma "$W/fleet-up/gamma.git" main dbt yes 2>&1)"
has "$O" "→ gamma declared" && pass "product-add : produit déclaré" || bad "product-add ($O)"
grep -qE "^gamma +$W/fleet-up/gamma.git +main +dbt +yes" "$FW/.devcontainer/products.conf" && pass "…ligne ajoutée à products.conf" || bad "ligne products.conf inattendue"
check "…worktree v2/gamma créé sur gamma/v2" test "$(git -C "$FW/v2/gamma" rev-parse --abbrev-ref HEAD 2>/dev/null)" = gamma/v2
grep -qxF "  - local: ../v2/gamma/dbt" "$FW/global/packages.yml" && pass "…et ajouté au projet global (GLOBAL yes)" || bad "gamma absent du global"
[ "$(grep -c '^uv venv' "$STUB_LOG")" = 1 ] && pass "…sans reconstruire la venv commune" || bad "venv reconstruite par product-add"
has "$O" "nothing is pushed for you" && pass "…et rien n'est poussé" || bad "product-add : message de publication absent"
O="$(FRUN product-add gamma "$W/fleet-up/gamma.git")"; has "$O" "already declared" && pass "product-add : doublon refusé" || bad "doublon accepté"
O="$(FRUN product-add Bad_Name "$W/fleet-up/gamma.git")"; has "$O" "invalid product name" && pass "product-add : nom invalide refusé" || bad "nom invalide accepté"

O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"
has "$O" "alpha pins dbt-core 1.9.8, runs on 1.10.0" && pass "doctor : montée de version à committer signalée (alpha)" || bad "doctor : écart de version non signalé"
! has "$O" "beta pins" && pass "…rien pour beta, déjà sur la version commune" || bad "doctor : faux écart pour beta"
has "$O" "✅ v2 alpha dbt project: v2/alpha/dbt (profile 'prof_alpha')" && pass "doctor : projets de chaque produit listés" || bad "doctor : projets non listés"
has "$O" "global/ dbt project (profile 'prof_global'): 2 product(s) as local packages" && pass "doctor : projet global et ses packages" || bad "doctor : global non vu ($(grep global <<<"$O" | head -2))"

git -C "$FW" add .devcontainer/products.conf profiles/profiles.yml global/packages.yml && git -C "$FW" commit -q -m "fleet: products" && git -C "$FW" push -q origin main
for N in alpha beta gamma; do for V in v1 v2; do git -C "$FW/$V/$N" push -q origin "$N/$V" 2>/dev/null; done; done
O="$(cd "$FW" && bash .devcontainer/dbt-run.sh upstream-pull alpha 2>&1)"; has "$O" "mirror on origin: alpha/upstream" && pass "upstream-pull alpha : miroir alpha/upstream publié" || bad "upstream-pull ($O)"
check "…présent sur origin" git -C "$W/fleet-origin.git" rev-parse --verify refs/heads/alpha/upstream
FW2="$W/fleet2"; git clone -q "$W/fleet-origin.git" "$FW2" 2>/dev/null
sed -i "s#$W/fleet-up/#$W/absent/#" "$FW2/.devcontainer/products.conf"
OUT="$(life "$FW2" create)"
[ "$(grep -c '<- origin/' <<<"$OUT")" = 6 ] && pass "clone neuf de la flotte : les 6 branches viennent d'origin" || bad "clone neuf : branches ($OUT)"
refute "…sans aucun accès aux dépôts d'origine" grep -q "fetching up-" <<<"$OUT"
check "…v2/gamma présent" test -f "$FW2/v2/gamma/dbt/dbt_project.yml"

# =============================================================================
echo "== Coordinateur : un produit dont les branches vivent dans son propre dépôt =="
mkup delta dbt prof_shared 1.10.0
git init -q --bare -b main "$W/homes/delta.git"
( cd "$W/fleet-src/delta" && git push -q "$W/homes/delta.git" main:main main:upstream-main main:v1 main:v2 )
printf 'delta   %s  main  dbt  no  %s\n' "$W/fleet-up/delta.git" "$W/homes/delta.git" >> "$FW/.devcontainer/products.conf"
OUT="$(life "$FW" start)"
check "delta : worktree v2/delta sur la branche locale delta/v2" test "$(git -C "$FW/v2/delta" rev-parse --abbrev-ref HEAD 2>/dev/null)" = delta/v2
check "…qui suit home-delta/v2 (le v2 du dépôt du produit)" test "$(git -C "$FW" rev-parse --abbrev-ref 'delta/v2@{upstream}')" = home-delta/v2
check "…remote home-delta = le dépôt du produit" test "$(git -C "$FW" remote get-url home-delta)" = "$W/homes/delta.git"
check "push.default = upstream dans le coordinateur" test "$(git -C "$FW" config --get push.default)" = upstream
( cd "$FW/v2/delta" && echo "refacto" >> dbt/models/m_delta.sql && git commit -q -am "refacto depuis le coordinateur" && git push -q ) 2>/dev/null
check "git push depuis v2/delta : le commit arrive dans le v2 du dépôt du produit" test "$(git -C "$W/homes/delta.git" log -1 --format=%s v2)" = "refacto depuis le coordinateur"
refute "…et rien n'est poussé sur l'origin du coordinateur" git -C "$W/fleet-origin.git" rev-parse --verify -q refs/heads/delta/v2
git clone -q -b v2 "$W/homes/delta.git" "$W/delta-side" 2>/dev/null
( cd "$W/delta-side" && echo "select 2" > dbt/models/side.sql && git add -A && git commit -q -m "travail dans le container du produit" && git push -q origin v2 ) 2>/dev/null
SYNC() { ( cd "$FW" && bash .devcontainer/dbt-run.sh sync "$@" ) 2>&1; }
O="$(SYNC delta)"; has "$O" "delta/v2: fast-forwarded 1 commit(s) from home-delta/v2" && pass "just sync delta : worktree propre avancé" || bad "sync avance rapide ($O)"
has "$O" "travail dans le container du produit" && pass "…et le sujet du commit reçu est affiché" || bad "sync : commit reçu non listé ($O)"
check "…v2/delta voit le commit fait côté produit" test "$(git -C "$FW/v2/delta" log -1 --format=%s)" = "travail dans le container du produit"
( cd "$W/delta-side" && echo "select 3" >> dbt/models/side.sql && git commit -q -am "encore côté produit" && git push -q origin v2 ) 2>/dev/null
echo "en cours" >> "$FW/v2/delta/dbt/models/m_delta.sql"
O="$(SYNC delta)"; has "$O" "NOT applied: uncommitted changes" && pass "sync : worktree modifié jamais touché" || bad "sync worktree modifié ($O)"
check "…ses modifications sont intactes" grep -q "en cours" "$FW/v2/delta/dbt/models/m_delta.sql"
( cd "$FW/v2/delta" && git commit -q -am "local, non poussé" )
O="$(SYNC delta)"; has "$O" "DIVERGED from home-delta/v2 (1 local, 1 there)" && pass "sync : divergence signalée, rien fusionné" || bad "sync divergence ($O)"
( cd "$FW/v2/delta" && git pull -q --rebase && git push -q ) 2>/dev/null
O="$(SYNC delta)"; has "$O" "delta/v2: up to date with home-delta/v2" && pass "sync : à jour après pull + push" || bad "sync à jour ($O)"
refute "…aucune branche non suivie signalée (main, upstream-main, v1, v2)" grep -q "not followed here" <<<"$O"
git -C "$W/delta-side" push -q origin v2:v3 2>/dev/null
O="$(SYNC delta)"; grep -q "NOTE: branches in home-delta not followed here: v3\$" <<<"$O" && pass "sync : une branche v3 ouverte côté produit est nommée" || bad "sync : branche non suivie tue ($O)"
O="$(cd "$FW" && bash .devcontainer/dbt-run.sh upstream-pull delta 2>&1)"; has "$O" "mirror on home-delta: upstream-main" && pass "upstream-pull delta : miroir publié dans le dépôt du produit" || bad "upstream-pull home ($O)"
refute "…pas sur l'origin du coordinateur" git -C "$W/fleet-origin.git" rev-parse --verify -q refs/heads/upstream-main
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"
has "$O" "delta: branches live in $W/homes/delta.git (remote home-delta)" && pass "doctor : où vivent les branches du produit" || bad "doctor : home non affiché"
has "$O" "delta/v2 = home-delta/v2" && pass "doctor : delta/v2 à jour de home-delta/v2" || bad "doctor : suivi non affiché ($(grep -F 'delta/v2' <<<"$O" | head -2))"
git -C "$FW" add .devcontainer/products.conf profiles/profiles.yml global/packages.yml 2>/dev/null; git -C "$FW" commit -q -m "fleet: delta (own repository)"; git -C "$FW" push -q origin main
FW3="$W/fleet3"; git clone -q "$W/fleet-origin.git" "$FW3" 2>/dev/null
OUT="$(life "$FW3" create)"
has "$OUT" "branch delta/v2 <- home-delta/v2" && pass "clone neuf du coordinateur : delta vient de son propre dépôt" || bad "clone neuf : delta ($OUT)"
check "…et son v2 est celui du dépôt du produit" test "$(git -C "$FW3/v2/delta" rev-parse HEAD)" = "$(git -C "$W/homes/delta.git" rev-parse v2)"

echo "== product-new : le dépôt dédié créé, rempli depuis l'origine, puis déclaré =="
mkup epsilon dbt prof_eps 1.10.0
mkdir -p "$W/gh/acme"
cat > "$W/stubs/gh" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "repo view") [ -d "$GH_ROOT/$3.git" ] || exit 1; [ "${4:-}" = "--json" ] && echo "${GH_VISIBILITY:-PRIVATE}"; exit 0 ;;
  "repo create") git init -q --bare -b main "$GH_ROOT/$3.git" ;;
esac
EOF
chmod +x "$W/stubs/gh"
git config --global url."file://$W/gh/".insteadOf "https://github.com/"
printf '{_commit: HEAD, _src_path: %s, author_email: t@t, author_name: Tester, claude_profile: '"''"', github_org: acme, project_type: dbt-fleet}\n' "$REPO_ROOT" > "$FW/.copier-answers.yml"
echo 'DBT_PRODUCT_REPO_PREFIX="fl-"' >> "$FW/.devcontainer/dbt.conf"
O="$(cd "$FW" && GH_ROOT="$W/gh" GH_TOKEN=dummy PYTHONUSERBASE="$REAL_USERBASE" bash .devcontainer/dbt-run.sh product-new epsilon "$W/fleet-up/epsilon.git" main dbt no 2>&1)"
has "$O" "→ acme/fl-epsilon: main, upstream-main, v1, v2 published" && pass "product-new : dépôt créé et publié" || bad "product-new ($(tail -5 <<<"$O"))"
for b in main upstream-main v1 v2; do git -C "$W/gh/acme/fl-epsilon.git" rev-parse --verify -q "refs/heads/$b" >/dev/null || bad "product-new : branche $b absente du dépôt créé"; done
check "…v1 = v2 = la branche d'origine" test "$(git -C "$W/gh/acme/fl-epsilon.git" rev-parse v2)" = "$(git -C "$W/fleet-up/epsilon.git" rev-parse main)"
A="$(git -C "$W/gh/acme/fl-epsilon.git" show main:.copier-answers.yml 2>/dev/null)"
has "$A" "project_type: dbt-project" && has "$A" "upstream_repo_url: $W/fleet-up/epsilon.git" && has "$A" "bq_sandbox_project: sandbox-prj" && pass "…son main est un dbt-project aux réponses de la flotte (bac à sable)" || bad "product-new : réponses inattendues ($A)"
git -C "$W/gh/acme/fl-epsilon.git" show main:profiles/profiles.yml 2>/dev/null | grep -q '^prof_eps:' && pass "…son hub de profils est amorcé (profil du projet)" || bad "product-new : hub non amorcé"
git -C "$W/gh/acme/fl-epsilon.git" show main:.devcontainer/upstream_known_hosts >/dev/null 2>&1 || git -C "$W/gh/acme/fl-epsilon.git" show main:profiles/dbt.env | grep -q FLEET_COMMON && pass "…il reprend le dbt.env de la flotte" || bad "product-new : dbt.env de la flotte absent"
grep -qE "^epsilon +$W/fleet-up/epsilon.git +main +dbt +no +https://github.com/acme/fl-epsilon.git" "$FW/.devcontainer/products.conf" && pass "…déclaré dans products.conf, HOME = le nouveau dépôt" || bad "product-new : ligne products.conf inattendue"
C="$(git -C "$W/gh/acme/fl-epsilon.git" show main:CLAUDE.md 2>/dev/null)"
grep -q '^## Coordination' <<<"$C" && has "$C" "$W/fleet-origin.git" && pass "…son CLAUDE.md explique le coordinateur et le nomme" || bad "product-new : section Coordination absente"
check "…worktree v2/epsilon qui suit home-epsilon/v2" test "$(git -C "$FW" rev-parse --abbrev-ref 'epsilon/v2@{upstream}' 2>/dev/null)" = home-epsilon/v2
O="$(cd "$FW" && GH_ROOT="$W/gh" GH_TOKEN=dummy PYTHONUSERBASE="$REAL_USERBASE" bash .devcontainer/dbt-run.sh product-new epsilon "$W/fleet-up/epsilon.git" 2>&1)"; has "$O" "already declared" && pass "product-new : produit déjà déclaré refusé" || bad "product-new doublon ($O)"
mkup zeta dbt prof_z 1.10.0
O="$(cd "$FW" && GH_ROOT="$W/gh" GH_TOKEN=dummy GH_VISIBILITY=PUBLIC PYTHONUSERBASE="$REAL_USERBASE" bash .devcontainer/dbt-run.sh product-new zeta "$W/fleet-up/zeta.git" main dbt no 2>&1)"
has "$O" "is not PRIVATE — nothing was pushed" && pass "product-new : dépôt non privé → aucun push" || bad "product-new visibilité ($(tail -3 <<<"$O"))"
refute "…le dépôt reste vide" git -C "$W/gh/acme/fl-zeta.git" rev-parse --verify -q refs/heads/main
refute "…et zeta n'est pas déclaré" grep -q '^zeta ' "$FW/.devcontainer/products.conf"
git config --global --unset-all url."file://$W/gh/".insteadOf

# =============================================================================
echo "== Verrou de la flotte (.devcontainer/products.lock) =="
LK() { ( cd "$FW" && bash .devcontainer/dbt-run.sh "$@" ) 2>&1; }
LOCKF="$FW/.devcontainer/products.lock"
O="$(LK lock)"; has "$O" "products.lock written" && pass "just lock : verrou écrit" || bad "lock ($O)"
[ "$(grep -cE '^[a-z]' "$LOCKF")" = 10 ] && pass "…une ligne par produit et par version (5 × v1/v2)" || bad "lock : $(grep -cE '^[a-z]' "$LOCKF") lignes"
grep -qE "^delta +v2 +$(git -C "$FW" rev-parse delta/v2)  $W/homes/delta.git#v2$" "$LOCKF" && pass "…commit exact et source (dépôt du produit#branche)" || bad "lock : ligne delta v2 inattendue"
grep -qE "^alpha +v1 +$(git -C "$FW" rev-parse alpha/v1)  origin#alpha/v1$" "$LOCKF" && pass "…produit hébergé ici : source origin" || bad "lock : ligne alpha v1 inattendue"
O="$(LK lock)"; has "$O" "already up to date" && pass "relancé sans changement : fichier inchangé" || bad "lock idempotent ($O)"
O="$(LK lock-status)"; has "$O" "= lock" && ! has "$O" "since the lock" && pass "lock-status : tout est au verrou" || bad "lock-status ($O)"
( cd "$FW/v2/delta" && echo "-- local" >> dbt/models/m_delta.sql && git commit -q -am "local, pas encore poussé" )
cp "$LOCKF" "$W/lock.before"
O="$(LK lock)"; has "$O" "NOT written" && has "$O" "is not pushed to home-delta/v2" && pass "commit non poussé : verrou refusé" || bad "lock non poussé ($O)"
check "…et le fichier n'a pas bougé" cmp -s "$LOCKF" "$W/lock.before"
O="$(LK lock-status)"; has "$O" "v2/delta/                1 commit(s) since the lock" && pass "lock-status : 1 commit depuis le verrou" || bad "lock-status avance ($O)"
( cd "$FW/v2/delta" && git push -q ) 2>/dev/null
O="$(LK lock)"; has "$O" "delta v2: " && has "$O" "(1 commit(s))" && pass "poussé : verrou mis à jour, l'écart est nommé" || bad "lock mise à jour ($O)"
echo "-- en cours" >> "$FW/v2/delta/dbt/models/m_delta.sql"
O="$(LK lock)"; has "$O" "not part of the lock" && has "$O" "uncommitted changes in v2/delta/" && pass "modification non commitée : signalée, hors verrou" || bad "lock + modif ($O)"
git -C "$FW/v2/delta" checkout -q -- dbt/models/m_delta.sql
LOCKED="$(git -C "$FW" rev-parse delta/v2)"
( cd "$W/delta-side" && git pull -q --rebase origin v2 && echo "select 4" >> dbt/models/side.sql && git commit -q -am "après le verrou" && git push -q origin v2 ) 2>/dev/null
O="$(SYNC delta)"; has "$O" "fast-forwarded 1 commit(s)" || bad "sync avant rejeu ($O)"
O="$(SYNC)"; has "$O" "lock: 1 worktree(s) away from products.lock" && pass "just sync : résumé de l'écart au verrou" || bad "sync résumé ($(tail -2 <<<"$O"))"
O="$(LK lock-checkout delta)"; has "$O" "at the locked ${LOCKED:0:9} (detached)" && pass "lock-checkout delta : état verrouillé rejoué" || bad "lock-checkout ($O)"
check "…v2/delta au commit verrouillé" test "$(git -C "$FW/v2/delta" rev-parse HEAD)" = "$LOCKED"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "v2/delta/ is on 'HEAD', not on its branch delta/v2" && pass "doctor : worktree rejoué signalé" || bad "doctor rejeu"
O="$(LK lock)"; has "$O" "is not on delta/v2" && pass "…et un état rejoué ne peut pas être verrouillé" || bad "lock d'un état rejoué ($O)"
O="$(LK lock-release delta)"; has "$O" "back on delta/v2" && pass "lock-release : retour sur la branche" || bad "lock-release ($O)"
check "…à la pointe de delta/v2" test "$(git -C "$FW/v2/delta" rev-parse HEAD)" = "$(git -C "$FW" rev-parse delta/v2)"
echo "-- sale" >> "$FW/v2/delta/dbt/models/m_delta.sql"
O="$(LK lock-checkout delta)"; has "$O" "uncommitted changes" && pass "lock-checkout refusé sur un worktree modifié" || bad "lock-checkout sale ($O)"
git -C "$FW/v2/delta" checkout -q -- dbt/models/m_delta.sql
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null | sed -n '/^\[lock/,/^\[profile/p')"
has "$O" "v2/delta/ 1 commit(s) since the lock" && has "$O" "products.lock is not committed yet" && pass "doctor : section [lock] (écarts, verrou à committer)" || bad "doctor [lock] ($O)"

echo "== Aucune fuite hors du bac à sable de test =="
refute "le vrai ~/.gitconfig n'a pas reçu le verrou" grep -q "git.invalid" /home/"$(id -un)"/.gitconfig
check "l'upstream n'a toujours qu'une branche" test "$(git -C "$W/upstream.git" for-each-ref refs/heads | wc -l)" = 1

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mTOUS LES CONTRÔLES PASSENT\033[0m"; else echo -e "\033[31mECHECS DETECTES\033[0m"; fi
exit "$fail"
