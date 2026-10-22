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
REAL_GI="$HOME/.local/libexec/git-ssh-garde.sh"; REAL_GI_AVANT="$(sha256sum "$REAL_GI" 2>/dev/null || echo absent)"
export HOME="$W/home"; mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
# aucune configuration git, aucun ssh ni assistant hérités de l'appelant (le vrai ~/.gitconfig reste hors d'atteinte)
unset GIT_CONFIG_GLOBAL GIT_SSH_COMMAND GIT_SSH GIT_ASKPASS SSH_ASKPASS SSH_AUTH_SOCK
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
  if [ "$a" = "ls" ]; then echo "ls $*" >> "$STUB_LOG"
    [ -n "${STUB_MANIFEST:-}" ] && mkdir -p target && cp "$STUB_MANIFEST" target/manifest.json  # dbt v2 ls rewrites it
    cat "${STUB_LS_FILE:-/dev/null}"; exit "${STUB_LS_RC:-0}"; fi
done
echo "ENGINE=$0 CWD=$PWD PROFILES=${DBT_PROFILES_DIR:-} EXTRA=${EXTRA_VAR:-} ARGS=$* PFX=${DATASET_PREFIX:-}"
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
  cp "$SRC/"*"git-ssh-garde.sh"* "$1/.devcontainer/git-ssh-garde.sh"
  printf 'DBT_SEND_ANONYMOUS_USAGE_STATS=false\nEXTRA_VAR=from-env-file\n' > "$1/profiles/dbt.env"
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

O="$(DBT_PROFILES_DIR=/nowhere RUN v1 parse)"
has "$O" "ENGINE=$DBT_V1_VENV/bin/dbt" && pass "just v1 → moteur dbt Core" || bad "v1 : mauvais moteur ($O)"
has "$O" "CWD=$WS/v1/dbt " && pass "…lancé depuis le dossier du projet dbt" || bad "v1 : mauvais dossier"
has "$O" "PROFILES=$WS/profiles " && pass "…hub imposé, même si le shell exporte un autre DBT_PROFILES_DIR" || bad "v1 : hub non imposé ($O)"
has "$O" "EXTRA=from-env-file" && pass "…variables de profiles/dbt.env chargées" || bad "v1 : dbt.env non chargé"
O="$(RUN v2 parse)"
has "$O" "ENGINE=$DBT_BIN_DIR/dbt CWD=$WS/v2/dbt " && pass "just v2 → moteur dbt v2, dans v2/" || bad "v2 : mauvais moteur ou dossier ($O)"

O="$(RUN v1 run)";                      has "$O" "without a selection" && pass "écriture sans sélection : refusée" || bad "écriture sans sélection acceptée ($O)"
O="$(RUN v1 run-operation m)";          has "$O" "run-operation is refused" && pass "run-operation : refusé" || bad "run-operation accepté"
O="$(RUN v1 parse --profiles-dir /x)";  has "$O" "--profiles-dir is not allowed" && pass "--profiles-dir : refusé" || bad "--profiles-dir accepté"
O="$(RUN v1 parse --project-dir /x)";   has "$O" "--project-dir is not allowed" && pass "--project-dir : refusé" || bad "--project-dir accepté"
O="$(RUN v2 run -s a --project-dir=/x)"; has "$O" "--project-dir is not allowed" && pass "--project-dir= : refusé" || bad "--project-dir= accepté"
refute "…et le moteur n'a pas été lancé" grep -qF "ARGS=run" <<<"$O"
O="$(DBT_PROJECT_DIR=/x RUN v2 run -s a)"; has "$O" "DBT_PROJECT_DIR is set" && pass "DBT_PROJECT_DIR exporté : refusé" || bad "DBT_PROJECT_DIR accepté ($O)"
refute "…et le moteur n'a pas été lancé" grep -qF "ARGS=run" <<<"$O"
O="$(RUN v1 parse --packages-install-path /x)"; has "$O" "--packages-install-path is not allowed" && ! has "$O" "ARGS=" && pass "--packages-install-path : refusé (les hooks lus sont ceux de dbt_packages/)" || bad "--packages-install-path accepté ($O)"
O="$(RUN v2 compile --packages-install-path=/x)"; has "$O" "--packages-install-path is not allowed" && ! has "$O" "ARGS=" && pass "--packages-install-path= : refusé" || bad "--packages-install-path= accepté ($O)"
O="$(DBT_PACKAGES_INSTALL_PATH=/x RUN v2 parse)"; has "$O" "DBT_PACKAGES_INSTALL_PATH is set" && ! has "$O" "ARGS=" && pass "DBT_PACKAGES_INSTALL_PATH exporté : refusé" || bad "DBT_PACKAGES_INSTALL_PATH accepté ($O)"
O="$(RUN v2 parse --profile p)"; has "$O" "ARGS=parse --profile p" && pass "…--profile hors de global-v4 : inchangé (le hub est imposé)" || bad "--profile hors de global-v4 ($O)"
cp "$WS/profiles/dbt.env" "$W/dbt.env.bak"
printf 'DBT_HOOKS_REVIEWED=1\n' >> "$WS/profiles/dbt.env"
O="$(RUN v2 parse)"; has "$O" "sets a DBT_* variable" && pass "dbt.env qui pose une variable du garde-fou (DBT_HOOKS_REVIEWED) : refusé" || bad "variable du garde-fou posée par dbt.env acceptée ($O)"
cp "$W/dbt.env.bak" "$WS/profiles/dbt.env"; printf 'DBT_PROFILES_DIR=/nowhere\n' >> "$WS/profiles/dbt.env"
O="$(RUN v1 parse)"; has "$O" "sets a DBT_* variable" && pass "dbt.env qui déplace le hub (DBT_PROFILES_DIR) : refusé" || bad "DBT_PROFILES_DIR posé par dbt.env accepté ($O)"
cp "$W/dbt.env.bak" "$WS/profiles/dbt.env"
O="$(RUN v1 parse)"; has "$O" "EXTRA=from-env-file" && pass "…dbt.env sans variable du garde-fou : chargé" || bad "dbt.env rétabli refusé ($O)"
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

echo "== DBT_HOOKS_REVIEWED_V2 : les hooks approuvés, dans la v2 seulement =="
man() {  # man FICHIER TEXTE_DU_HOOK PROJET_DE_LA_SOURCE — un manifeste : une opération + un post_hook sur une source
  python3 - "$@" <<'PY'
import json, sys
f, sql, db = sys.argv[1:4]
json.dump({"sources": {"source.fake.S.T": {"package_name": "fake", "source_name": "S", "name": "T", "database": db, "schema": "DS", "identifier": "T"}},
           "nodes": {"operation.elem.elem-on-run-end-0": {"resource_type": "operation", "package_name": "elem", "raw_code": "{{ elem.on_run_end() }}"},
                     "model.fake.a": {"resource_type": "model", "package_name": "fake", "config": {"post-hook": [{"sql": sql}]}}}}, open(f, "w"))
PY
}
MAN_A="$W/man-a.json"; MAN_B="$W/man-b.json"; MAN_C="$W/man-c.json"
man "$MAN_A" "insert into {{ source('S', 'T') }} select 1" sandbox-prj
man "$MAN_B" "insert into {{ source('S', 'T') }} select 2" sandbox-prj
man "$MAN_C" "insert into {{ source('S', 'T') }} select 1" real-prd
conf "$WS" 'DBT_HOOKS_REVIEWED_V2=1'
O="$(STUB_MANIFEST="$MAN_A" RUN v2 run -s a)"; has "$O" "no approved hook" && has "$O" "hooks nobody has reviewed" && pass "aucun hook approuvé : refusé" || bad "interrupteur sans approbation accepté ($O)"
mkdir -p "$WS/v2/dbt/target"; cp "$MAN_A" "$WS/v2/dbt/target/manifest.json"
O="$(RUN hooks-approve)";   has "$O" "2 hook(s)" && pass "just hooks-approve : les 2 hooks du manifeste approuvés" || bad "approbation ($O)"
check "…consignés dans .devcontainer/hooks.approved" grep -q "model.fake.a.post-hook" "$WS/.devcontainer/hooks.approved"
O="$(STUB_MANIFEST="$MAN_A" RUN v2 run -s a)"; has "$O" "every hook is an approved one" && has "$O" "ARGS=run -s a" && pass "v2 run, hooks approuvés : accepté" || bad "hooks approuvés mais refusé ($O)"
O="$(STUB_MANIFEST="$MAN_A" RUN v2 test)";     has "$O" "ARGS=test" && pass "…v2 test (sans écriture) : dbt ls relit les hooks, accepté" || bad "v2 test refusé ($O)"
O="$(STUB_MANIFEST="$MAN_B" RUN v2 run -s a)"; has "$O" "not approved" && has "$O" "model.fake.a post-hook" && pass "hook modifié : refusé, nommé" || bad "hook modifié accepté ($O)"
refute "…et le moteur n'a pas été lancé" grep -qF "ARGS=run" <<<"$O"
O="$(STUB_MANIFEST="$MAN_C" RUN v2 run -s a)"; has "$O" "not approved" && pass "même texte, source résolue ailleurs : refusé" || bad "source déplacée acceptée ($O)"
O="$(STUB_MANIFEST="$MAN_A" RUN v1 run -s a)"; has "$O" "hooks nobody has reviewed" && pass "v1 : hors de l'interrupteur, toujours refusé" || bad "v1 ouverte par DBT_HOOKS_REVIEWED_V2 ($O)"
conf "$WS"
O="$(STUB_MANIFEST="$MAN_A" RUN v2 run -s a)"; has "$O" "hooks nobody has reviewed" && pass "interrupteur à 0 : refusé malgré l'approbation" || bad "approbation sans interrupteur acceptée ($O)"
rm -f "$WS/.devcontainer/hooks.approved" "$WS/v2/dbt/target/manifest.json"
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
[ "$(G --get-all url.DISABLED://.pushInsteadOf | wc -l)" = 13 ] && pass "verrou de push : scp, ssh://, https:// et les 10 formes de plus (pushInsteadOf)" || bad "verrou de push incomplet"
O="$(git -C "$WS3" push git@git.invalid:grp/repo.git HEAD:refs/heads/x 2>&1)"
has "$O" "DISABLED" && pass "push par URL explicite : refusé par git avant tout accès réseau" || bad "push par URL explicite non verrouillé ($O)"
( cd "$WS3" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' ) >/dev/null 2>&1
[ "$(G --get-all url.DISABLED://.pushInsteadOf | wc -l)" = 13 ] && pass "verrou rejoué : aucune entrée dupliquée" || bad "verrou dupliqué"
G core.sshCommand "ssh -i /custom/key"
( cd "$WS3" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' ) >/dev/null 2>&1
check "un core.sshCommand personnalisé n'est pas écrasé" test "$(G --get core.sshCommand)" = "ssh -i /custom/key"
G --add url.DISABLED://.pushInsteadOf "git@other.invalid:"
echo 'DBT_UPSTREAM_PUSH_LOCK=0' >> "$WS3/.devcontainer/dbt.conf"
OUT="$( cd "$WS3" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' 2>&1 )"
refute "DBT_UPSTREAM_PUSH_LOCK=0 lève le verrou de cet hôte…" grep -q "git.invalid" <<<"$(G --get-all url.DISABLED://.pushInsteadOf)"
check "…sans toucher au verrou posé pour un autre hôte" test "$(G --get-all url.DISABLED://.pushInsteadOf)" = "git@other.invalid:"
has "$OUT" "UNLOCKED" && pass "…et le dit en clair" || bad "levée du verrou silencieuse"
check "…et ses quitteurs https et proxys morts retirés (un hôte déverrouillé se relit en https)" test -z "$(G --get-regexp '^(credential\..*git\.invalid.*helper|http\..*git\.invalid.*\.proxy)$')"

# =============================================================================
echo "== Verrou 4 : les 23 formes d'un push vers un hôte d'origine, couche par couche, et un mutant par couche =="
# Sans réseau : ssh est un bouchon qui consigne ce qu'on lui demande (seul « ssh -G », local, passe au vrai
# ssh, avec un fichier de configuration du test) ; getent aussi (une table du test ; seuls localhost et les
# adresses littérales vont au vrai getent, qui lit /etc/hosts). https est jugé deux fois : le push lui-même
# (le proxy mort l'arrête sur 127.0.0.1:9, rien ne sort), puis `git credential fill` sur l'URL où partirait
# le push — ce que git ferait au premier 401 —, l'assistant général étant « généreux ».
V4="$W/verrou4"; mkdir -p "$V4/bin"
WS5="$W/ws5"; make_ws "$WS5"; conf "$WS5"
sed -i 's#^DBT_UPSTREAM_URL=.*#DBT_UPSTREAM_URL="git@git.invalid:grp/repo.git"#' "$WS5/.devcontainer/dbt.conf"
cp "$WS3/.devcontainer/upstream_known_hosts" "$WS5/.devcontainer/"
cat > "$V4/ssh_config" <<'EOF'
Host gl-alias
  HostName git.invalid
Host ip-alias
  HostName 127.0.0.1
Host hka-alias
  HostName github.com
  HostKeyAlias git.invalid
Host pc-alias
  HostName github.com
  ProxyCommand nc git.invalid 22
Host pc-ip
  HostName github.com
  ProxyCommand socat - TCP:[::ffff:127.0.0.1]:22
Host pj-alias
  HostName github.com
  ProxyJump jb@GIT.INVALID.:2222
Host can-alias
  HostName git
  CanonicalizeHostname yes
  CanonicalDomains invalid
EOF
REAL_SSH="$(command -v ssh 2>/dev/null || true)"
REAL_GETENT="$(command -v getent 2>/dev/null || true)"
cat > "$V4/bin/ssh" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = -G ]; then
    [ -n "$REAL_SSH" ] && exec "$REAL_SSH" -F "$V4/ssh_config" "\$@"
    d="\${@: -1}"; printf 'hostname %s\n' "\${d##*@}"; exit 0
  fi
done
printf '%s\n' "\$*" >> "$V4/ssh.log"
echo "ssh (bouchon du test) : aucune connexion" >&2; exit 1
EOF
# getent bouchon : « ahosts » répond depuis $V4/hosts ; localhost et les adresses littérales vont au vrai getent
printf 'alias-ip.test 127.0.0.1\nmapped.test ::ffff:127.0.0.1\ninverse.test 192.0.2.10\norigine.test 192.0.2.10\n' > "$V4/hosts"
cat > "$V4/bin/getent" <<EOF
#!/bin/bash
[ "\$1" = ahosts ] || exec "$REAL_GETENT" "\$@"
shift; rc=2
for k in "\$@"; do
  l="\$(awk -v k="\${k,,}" 'tolower(\$1) == k { \$1 = ""; print; exit }' "$V4/hosts")"
  if [ -n "\$l" ]; then for a in \$l; do printf '%-15s STREAM %s\n' "\$a" "\$k"; done; rc=0
  elif [ -n "$REAL_GETENT" ] && { [[ "\$k" =~ ^[0-9.]+\$ ]] || [[ "\$k" == *:* ]] || [ "\$k" = localhost ]; }; then
    "$REAL_GETENT" ahosts "\$k" && rc=0
  fi
done
exit \$rc
EOF
printf '#!/bin/sh\necho "ASKPASS $*" >> %q\necho secret\n' "$V4/cred.log" > "$V4/askpass"
printf '#!/bin/sh\ncat >/dev/null; echo "GENEREUX $1" >> %q\n[ "$1" = get ] && printf "username=jb\\npassword=secret\\n"\nexit 0\n' "$V4/cred.log" > "$V4/genereux"
printf '#!/bin/sh\necho "GIT_SSH $*" >> %q\nexit 1\n' "$V4/gitssh.log" > "$V4/gitssh"
chmod +x "$V4/bin/ssh" "$V4/bin/getent" "$V4/askpass" "$V4/genereux" "$V4/gitssh"
ESS="$V4/essai"; git init -q "$ESS"; git -C "$ESS" commit -q --allow-empty -m "essai (jamais poussé)"
GI="$HOME/.local/libexec/git-ssh-garde.sh"   # la copie de la garde que git lance (hors du worktree)
SETSID=""; command -v setsid >/dev/null 2>&1 && SETSID="setsid -w"   # sans terminal de contrôle

# v4_setup NOM [code évalué après lib-dbt.sh, avant dbt_git_setup : un mutant] — le cycle git sur une
# configuration globale à part ($V4/NOM.cfg, vidée), où l'assistant général « généreux » est posé avant
v4_setup() {
  : > "$V4/$1.cfg"; GIT_CONFIG_GLOBAL="$V4/$1.cfg" git config --global credential.helper "$V4/genereux"
  ( cd "$WS5" && GIT_CONFIG_GLOBAL="$V4/$1.cfg" bash -c 'source .devcontainer/lib-dbt.sh && eval "$1" && dbt_load_conf "$PWD" && dbt_git_setup' _ "${2:-:}" ) 2>&1
}
# v4_forme CFG u|p|s URL [VAR=valeur…] -> DISABLED | GARDE | HTTPS | PROXY-SEUL | QUITTEUR-SEUL | FUITE-SSH | FUITE-HTTPS | AUTRE:…
#   u = l'URL d'un remote, p = sa pushurl explicite, s = git send-pack <URL> (ni remote ni pushInsteadOf)
#   HTTPS = les deux lignes https tiennent (le proxy mort arrête le push, le quitteur ne donne rien)
v4_forme() {
  local cfg="$1" k="$2" u="$3" v out px q; shift 3
  if [ "$k" = s ]; then v="$u"
  else
    git -C "$ESS" remote remove t >/dev/null 2>&1
    git -C "$ESS" remote add t "$u"; [ "$k" = p ] && git -C "$ESS" remote set-url --push t "$u"
    v="$(GIT_CONFIG_GLOBAL="$cfg" git -C "$ESS" remote get-url --push t)"
  fi
  case "$v" in
    DISABLED://*) echo DISABLED ;;
    https://*|http://*)
      : > "$V4/cred.log"
      out="$(cd "$ESS" && env GIT_CONFIG_GLOBAL="$cfg" GIT_ASKPASS="$V4/askpass" GIT_TERMINAL_PROMPT=0 "$@" timeout 30 git push --dry-run t HEAD:refs/heads/probe 2>&1 </dev/null)"
      px=N; grep -q '127\.0\.0\.1 port 9' <<<"$out" && [ ! -s "$V4/cred.log" ] && px=P
      : > "$V4/cred.log"
      out="$(printf 'url=%s\n\n' "$v" | GIT_CONFIG_GLOBAL="$cfg" GIT_ASKPASS="$V4/askpass" GIT_TERMINAL_PROMPT=0 git -C "$ESS" credential fill 2>&1)"
      if grep -q 'verrou 4' <<<"$out" && [ ! -s "$V4/cred.log" ]; then q=Q; else q=L; fi
      case "$px$q" in PQ) echo HTTPS ;; PL) echo PROXY-SEUL ;; NQ) echo QUITTEUR-SEUL ;; *) echo FUITE-HTTPS ;; esac ;;
    *)
      : > "$V4/ssh.log"
      if [ "$k" = s ]; then
        out="$(cd "$ESS" && env GIT_CONFIG_GLOBAL="$cfg" PATH="$V4/bin:$PATH" "$@" timeout 30 git send-pack --dry-run "$v" HEAD:refs/heads/probe 2>&1 </dev/null)"
      else
        out="$(cd "$ESS" && env GIT_CONFIG_GLOBAL="$cfg" PATH="$V4/bin:$PATH" "$@" timeout 30 git push --dry-run t HEAD:refs/heads/probe 2>&1 </dev/null)"
      fi
      if grep -q 'receive-pack' "$V4/ssh.log"; then echo FUITE-SSH
      elif grep -q 'verrou 4 (ssh guard)' <<<"$out"; then echo GARDE
      else echo "AUTRE:$(tail -1 <<<"$out")"; fi ;;
  esac
}
H=git.invalid; HU=GIT.INVALID; HM=Git.Invalid; A=grp/autre.git
# forme|URL|couche attendue — DISABLED (pushInsteadOf : les 3 historiques, ou la couche c), GARDE (a), HTTPS (b)
FORMES=(
  "u|https://$H/$A|DISABLED" "u|git@$H:$A|DISABLED" "u|ssh://git@$H/$A|DISABLED"
  "u|git+ssh://git@$H/$A|DISABLED" "u|ssh+git://git@$H/$A|DISABLED" "u|ssh://git@$H:22/$A|DISABLED"
  "u|ssh://$H/$A|DISABLED" "u|$H:$A|DISABLED" "u|jb@$H:$A|GARDE" "u|git@$H.:$A|GARDE"
  "u|ssh://git@$HU/$A|GARDE" "u|git@$HM:$A|GARDE" "u|https://$HM/$A|HTTPS" "u|https://$H:443/$A|DISABLED"
  "u|https://jb@$H/$A|HTTPS" "u|http://$H/$A|DISABLED" "u|https://$H./$A|HTTPS"
  "p|https://$H/$A|GARDE" "p|git@$H:$A|GARDE" "p|ssh://git@$H/$A|GARDE" "p|https://$HM/$A|HTTPS"
  "p|https://$H/grp/repo.git|GARDE" "s|git@$H:$A|GARDE"
)
NF="${#FORMES[@]}"
lab() { local k="${1%%|*}" r="${1#*|}"; r="${r%|*}"; case "$k" in p) printf 'pushurl explicite %s' "$r" ;; s) printf 'git send-pack %s' "$r" ;; *) printf '%s' "$r" ;; esac; }
# v4_tableau CFG [VAR=valeur…] -> une ligne « issue » par forme, dans l'ordre de FORMES
v4_tableau() { local cfg="$1" f r; shift; for f in "${FORMES[@]}"; do r="${f#*|}"; v4_forme "$cfg" "${f%%|*}" "${r%|*}" "$@"; done; }
attendu() { local f; for f in "${FORMES[@]}"; do echo "${f##*|}"; done; }
# ecarts ATTENDU OBTENU -> « n:attendu->obtenu » pour chaque forme qui diffère
ecarts() { paste -d'|' <(printf '%s\n' "$1") <(printf '%s\n' "$2") | awk -F'|' '$1 != $2 { printf "%d:%s->%s ", NR, $1, $2 }'; }
nb() { grep -o -- "$1" <<<"$2" | wc -l | tr -d ' '; }

O="$(v4_setup complet)"
has "$O" "push to git.invalid LOCKED (pushInsteadOf; https: dead proxy, no credentials)" && has "$O" "ssh push guard on git.invalid" \
  && pass "dbt_git_setup : les trois couches posées, et dites" || bad "dbt_git_setup verrou 4 ($O)"
SC5="$(GIT_CONFIG_GLOBAL="$V4/complet.cfg" git config --global --get core.sshCommand)"
[ "$SC5" = "bash $GI --hosts=git.invalid -o \"UserKnownHostsFile=$WS5/.devcontainer/upstream_known_hosts $HOME/.ssh/known_hosts\"" ] \
  && pass "core.sshCommand = la copie installée de la garde ssh, qui porte la clé épinglée" || bad "core.sshCommand de la garde inattendu ($SC5)"
cmp -s "$WS5/.devcontainer/git-ssh-garde.sh" "$GI" && [ -x "$GI" ] \
  && pass "la garde est copiée hors du worktree (~/.local/libexec/git-ssh-garde.sh), à l'identique" || bad "copie installée de la garde absente ou différente"
[ "$(GIT_CONFIG_GLOBAL="$V4/complet.cfg" git config --global --get-all "http.https://$H.proxy")" = "http://127.0.0.1:9" ] \
  && [ "$(GIT_CONFIG_GLOBAL="$V4/complet.cfg" git config --global --get-all "http.http://$H.proxy")" = "http://127.0.0.1:9" ] \
  && pass "proxy mort posé pour https:// et http:// de l'hôte (127.0.0.1:9)" || bad "proxy mort absent"
ATT="$(attendu)"; COMPLET="$(v4_tableau "$V4/complet.cfg")"
i=0; while IFS= read -r r; do
  f="${FORMES[$i]}"; i=$((i + 1))
  if [ "$r" = "${f##*|}" ]; then pass "forme $i/$NF : $(lab "$f") — $r"; else bad "forme $i/$NF : $(lab "$f") — $r (attendu ${f##*|})"; fi
done <<<"$COMPLET"
cp "$V4/complet.cfg" "$V4/complet.avant"
( cd "$WS5" && GIT_CONFIG_GLOBAL="$V4/complet.cfg" bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' ) >/dev/null 2>&1
cmp -s "$V4/complet.avant" "$V4/complet.cfg" && pass "rejoué : configuration identique (idempotent)" || bad "verrou 4 non idempotent ($(diff "$V4/complet.avant" "$V4/complet.cfg" | head -5))"

# sans le correctif : les couches retirées = le lib-dbt.sh d'avant
v4_setup avant '_dbt_push_lock_ssh() { :; }; _dbt_push_lock_https() { :; }; _dbt_push_lock_proxy() { :; }; _dbt_push_prefixes_more() { :; }' >/dev/null
O="$(v4_tableau "$V4/avant.cfg")"; N="$(grep -c '^FUITE' <<<"$O")"
[ "$N" = 20 ] && pass "sans le correctif : $N formes sur $NF partent vers l'hôte d'origine (le tableau voit les trous)" || bad "sans le correctif : $N fuite(s), 20 attendues ($(ecarts "$ATT" "$O"))"
# mutant (a) : sans la garde ssh, les 9 formes qu'elle seule arrête partent par ssh (git send-pack compris)
v4_setup mut-a '_dbt_push_lock_ssh() { :; }' >/dev/null
E="$(ecarts "$ATT" "$(v4_tableau "$V4/mut-a.cfg")")"
[ "$(nb 'GARDE->FUITE-SSH' "$E")" = 9 ] && [ "$(wc -w <<<"$E")" = 9 ] && has "$E" "$NF:GARDE->FUITE-SSH" \
  && pass "mutant (a) sans garde ssh : détecté — 9 formes partent par ssh, git send-pack compris ($E)" || bad "mutant (a) non détecté ($E)"
# mutant (b1) : sans le proxy mort, les 4 formes https ne tiennent plus que par le quitteur
v4_setup mut-bp '_dbt_push_lock_proxy() { :; }' >/dev/null
E="$(ecarts "$ATT" "$(v4_tableau "$V4/mut-bp.cfg")")"
[ "$(nb 'HTTPS->QUITTEUR-SEUL' "$E")" = 4 ] && [ "$(wc -w <<<"$E")" = 4 ] \
  && pass "mutant (b1) sans proxy mort : détecté — 4 formes https vont au réseau ($E)" || bad "mutant (b1) non détecté ($E)"
# mutant (b2) : sans le quitteur, les 4 formes https recevraient un identifiant au premier 401
v4_setup mut-b '_dbt_push_lock_https() { :; }' >/dev/null
E="$(ecarts "$ATT" "$(v4_tableau "$V4/mut-b.cfg")")"
[ "$(nb 'HTTPS->PROXY-SEUL' "$E")" = 4 ] && [ "$(wc -w <<<"$E")" = 4 ] \
  && pass "mutant (b2) sans quitteur https : détecté — 4 formes reçoivent un identifiant ($E)" || bad "mutant (b2) non détecté ($E)"
# mutant (c) : sans les 10 préfixes de plus, la garde et https rattrapent tout… sauf sous GIT_SSH_COMMAND
v4_setup mut-c '_dbt_push_prefixes_more() { :; }' >/dev/null
E="$(ecarts "$ATT" "$(v4_tableau "$V4/mut-c.cfg")")"
[ "$(nb 'DISABLED->GARDE' "$E")" = 5 ] && [ "$(nb 'DISABLED->HTTPS' "$E")" = 2 ] && [ "$(wc -w <<<"$E")" = 7 ] \
  && pass "mutant (c) sans les préfixes de plus : détecté — 7 formes arrêtées par une autre couche ($E)" || bad "mutant (c) non détecté ($E)"
O="$(v4_tableau "$V4/complet.cfg" GIT_SSH_COMMAND=ssh)"; E="$(ecarts "$O" "$(v4_tableau "$V4/mut-c.cfg" GIT_SSH_COMMAND=ssh)")"
[ "$(nb 'DISABLED->FUITE-SSH' "$E")" = 5 ] && [ "$(nb 'DISABLED->HTTPS' "$E")" = 2 ] && [ "$(wc -w <<<"$E")" = 7 ] \
  && pass "…sous GIT_SSH_COMMAND (garde remplacée), le mutant (c) laisse partir 5 formes que le correctif arrête ($E)" || bad "mutant (c) sous GIT_SSH_COMMAND ($E)"
E="$(ecarts "$ATT" "$O")"
[ -n "$E" ] && [ "$(nb 'GARDE->FUITE-SSH' "$E")" = "$(wc -w <<<"$E")" ] && has "$E" "$NF:GARDE->FUITE-SSH" \
  && pass "limite dite : GIT_SSH_COMMAND exporté ne retire que la garde ssh ($(wc -w <<<"$E") formes, git send-pack compris : pushInsteadOf ne vaut que pour git push)" || bad "GIT_SSH_COMMAND : autre couche touchée ($E)"
# GIT_SSH seul ne remplace pas la garde : git préfère core.sshCommand
: > "$V4/gitssh.log"; E="$(ecarts "$ATT" "$(v4_tableau "$V4/complet.cfg" GIT_SSH="$V4/gitssh")")"
[ -z "$E" ] && [ ! -s "$V4/gitssh.log" ] && pass "GIT_SSH exporté : la garde reste devant (GIT_SSH jamais lancé, les $NF formes inchangées)" || bad "GIT_SSH remplace la garde ($E)"

# la lecture de l'hôte d'origine par ssh reste possible : fetch, ls-remote, clone, archive
LUCFG="$V4/complet.cfg"
G5() { env GIT_CONFIG_GLOBAL="$LUCFG" PATH="$V4/bin:$PATH" timeout 30 git "$@" 2>&1 </dev/null; }
lu() { : > "$V4/ssh.log"; O="$(cd "$V4" && G5 "$@")"; ! grep -q 'verrou 4' <<<"$O" && grep -qF -- "$LU" "$V4/ssh.log"; }
LU="git-upload-pack 'grp/repo.git'"
lu ls-remote "git@$H:grp/repo.git" && pass "lecture : git ls-remote git@$H: part vers ssh (git-upload-pack)" || bad "ls-remote bloqué ($O)"
lu ls-remote "https://$H/grp/repo.git" && pass "lecture : https://$H/ se lit par ssh (réécriture), la garde laisse passer" || bad "ls-remote https bloqué ($O)"
lu ls-remote "jb@$HU:grp/repo.git" && pass "lecture : autre utilisateur, majuscules — la lecture passe aussi" || bad "lecture variante bloquée ($O)"
lu clone -q "git@$H:grp/repo.git" "$V4/clone" && pass "lecture : git clone part vers ssh (git-upload-pack)" || bad "clone bloqué ($O)"
git -C "$ESS" remote set-url t "git@$H:grp/repo.git"; git -C "$ESS" config --unset remote.t.pushurl
lu -C "$ESS" fetch t && pass "lecture : git fetch d'un remote de l'hôte part vers ssh" || bad "fetch bloqué ($O)"
LU="git-upload-archive 'grp/repo.git'"
lu archive "--remote=git@$H:grp/repo.git" HEAD && pass "lecture : git archive --remote part vers ssh (git-upload-archive)" || bad "archive bloqué ($O)"
# ce qui ressemble à une lecture sans en être une
: > "$V4/ssh.log"; O="$(cd "$V4" && G5 ls-remote --upload-pack=git-receive-pack "git@$H:grp/repo.git")"
grep -q 'verrou 4 (ssh guard)' <<<"$O" && ! grep -q receive-pack "$V4/ssh.log" && pass "--upload-pack=git-receive-pack : refusé par la garde" || bad "--upload-pack détourné ($O)"
: > "$V4/ssh.log"; O="$(cd "$V4" && G5 ls-remote "--upload-pack=git-upload-pack 'x'; git-receive-pack" "git@$H:grp/repo.git")"
grep -q 'verrou 4 (ssh guard)' <<<"$O" && [ ! -s "$V4/ssh.log" ] && pass "une lecture suivie d'autre chose : refusée" || bad "commande composée passée ($O)"
# GA [--garde=FICHIER] ARGS… : la garde lancée seule, sans terminal de contrôle, ssh et getent en bouchons
GA() { local g="$GI"; case "${1:-}" in --garde=*) g="${1#--garde=}"; shift ;; esac
  PATH="$V4/bin:$PATH" $SETSID bash "$g" "$@" </dev/null 2>&1; }
O="$(GA --hosts=$H "git@$H" "git-lfs-authenticate 'grp/repo.git' upload")"; has "$O" "verrou 4 (ssh guard)" && pass "git-lfs-authenticate … upload : refusé" || bad "lfs upload passé ($O)"
O="$(GA --hosts=$H -4vp 22 "git@$H" "git-receive-pack 'grp/repo.git'")"; has "$O" "verrou 4 (ssh guard)" && pass "options groupées (-4vp 22) : l'hôte reste lu, push refusé" || bad "options groupées ($O)"
if [ -n "$REAL_SSH" ]; then
  : > "$V4/ssh.log"; O="$(cd "$ESS" && G5 push --dry-run gl-alias:grp/repo.git HEAD:refs/heads/probe)"
  grep -q 'verrou 4 (ssh guard)' <<<"$O" && [ ! -s "$V4/ssh.log" ] && pass "alias de ~/.ssh/config (HostName de l'hôte d'origine) : push refusé (ssh -G)" || bad "alias ssh passé ($O)"
  O="$(GA --hosts=localhost ip-alias "git-receive-pack 'x'")"; has "$O" "to localhost (127.0.0.1)" && pass "alias vers une adresse IP de l'hôte : refusé" || bad "alias IP ($O)"
else pass "alias ssh : pas de client ssh pour « ssh -G » (non joué)"; fi
O="$(GA --hosts=localhost git@127.0.0.1 "git-receive-pack 'x'")"; has "$O" "to localhost (127.0.0.1)" && pass "adresse IP de l'hôte d'origine : push refusé" || bad "IP de l'hôte ($O)"
: > "$V4/ssh.log"; GA --hosts=localhost git@127.0.0.1 "git-upload-pack 'x'" >/dev/null; grep -q "git-upload-pack 'x'" "$V4/ssh.log" && pass "…et la lecture par cette adresse passe" || bad "lecture par IP bloquée"
O="$(GA --hosts=$H git@192.0.2.1 "git-receive-pack 'x'")"; has "$O" "unresolved" && pass "adresse IP quand l'hôte ne se résout pas : push refusé (fail closed)" || bad "IP non résolue ($O)"

# la garde par adresse et par la configuration ssh : un cas par écriture, puis un mutant par mécanisme
# id|--hosts=…|destination|ce que c'est (A = par adresse, C = par la configuration ssh, rendue par ssh -G)
GCAS=(
  "A1|--hosts=localhost|git@[::ffff:127.0.0.1]|adresse IPv4-mappée de l'hôte, [::ffff:127.0.0.1]"
  "A2|--hosts=localhost|git@[::ffff:7f00:1]|la même en hexadécimal, [::ffff:7f00:1]"
  "A3|--hosts=localhost|git@alias-ip.test|un nom qui se résout vers l'adresse de l'hôte"
  "A4|--hosts=localhost|git@mapped.test|un nom dont l'adresse est ::ffff:<adresse de l'hôte>"
  "A5|--hosts=origine.test|git@inverse.test|un autre nom du même serveur (son nom inverse)"
)
[ -n "$REAL_SSH" ] && GCAS+=(
  "C1|--hosts=$H|hka-alias|alias ssh : HostName github.com, HostKeyAlias de l'hôte"
  "C2|--hosts=$H|pc-alias|alias ssh : HostName github.com, ProxyCommand nc <hôte> 22"
  "C3|--hosts=localhost|pc-ip|alias ssh : ProxyCommand socat vers [::ffff:<adresse de l'hôte>]:22"
  "C4|--hosts=$H|pj-alias|alias ssh : HostName github.com, ProxyJump jb@<HÔTE>.:2222"
  "C5|--hosts=$H|can-alias|alias ssh : HostName git, CanonicalizeHostname + CanonicalDomains invalid"
)
# gfuites [--garde=FICHIER] -> les id des cas où git-receive-pack est parti vers ssh
gfuites() { local c id h d r=""; for c in "${GCAS[@]}"; do IFS='|' read -r id h d _ <<<"$c"
  : > "$V4/ssh.log"; GA "$@" "$h" "$d" "git-receive-pack 'grp/repo.git'" >/dev/null; grep -q receive-pack "$V4/ssh.log" && r="$r $id"; done; echo "${r# }"; }
for c in "${GCAS[@]}"; do IFS='|' read -r id h d what <<<"$c"
  : > "$V4/ssh.log"; O="$(GA "$h" "$d" "git-receive-pack 'grp/repo.git'")"
  has "$O" "verrou 4 (ssh guard)" && [ ! -s "$V4/ssh.log" ] && pass "garde $id — $what : push refusé avant ssh" || bad "garde $id — $what ($O)"
done
: > "$V4/ssh.log"; GA --hosts=localhost git@alias-ip.test "git-upload-pack 'x'" >/dev/null
grep -q "git@alias-ip.test git-upload-pack 'x'" "$V4/ssh.log" && pass "…la lecture par un autre nom de l'hôte passe" || bad "lecture par autre nom bloquée"
: > "$V4/ssh.log"; GA --hosts=localhost git@github.com "git-receive-pack 'acme/x.git'" >/dev/null
grep -q "git@github.com git-receive-pack 'acme/x.git'" "$V4/ssh.log" && pass "…un hôte d'origine résolu ne gêne pas les autres hôtes (push GitHub passé à ssh)" || bad "push GitHub bloqué par la résolution"
# mutants de la garde : chacun retire un mécanisme ; le cas qu'il est seul à couvrir doit fuir
gmut() {   # NOM SED ATTENDU — ATTENDU = les id qui doivent fuir
  local f="$V4/garde-$1.sh"; cp "$GI" "$f"; sed -i "$2" "$f"
  if cmp -s "$GI" "$f"; then bad "mutant garde $1 : non appliqué"; return; fi
  local got; got="$(gfuites --garde="$f")"
  [ "$got" = "$3" ] && pass "mutant garde « $1 » : détecté — fuient : $got" || bad "mutant garde « $1 » : fuient « $got », attendu « $3 »"
}
gmut sans-unmap 's/^unmap() {$/unmap() { printf "%s" "$1"; return 0;/' "A4"
gmut sans-resolution 's/^dest_addrs() {.*$/dest_addrs() { local Y; for Y in "$@"; do is_ip "$Y" \&\& printf "%s\\n" "$Y"; done; return 0;/' "A3 A4 A5"
if [ -n "$REAL_SSH" ]; then
  gmut comparaison-textuelle 's/^unmap() {$/unmap() { printf "%s" "$1"; return 0;/; s/^dest_addrs() {.*$/dest_addrs() { local Y; for Y in "$@"; do is_ip "$Y" \&\& printf "%s\\n" "$Y"; done; return 0;/' "A1 A2 A3 A4 A5 C3"
  gmut sans-hostkeyalias 's/^alias_hka() {/alias_hka() { return 0;/' "C1"
  gmut sans-proxycommand 's/^alias_pc() {/alias_pc() { return 0;/' "C2 C3"
  gmut sans-proxyjump 's/^alias_pj() {/alias_pj() { return 0;/' "C4"
  gmut sans-canonicaldomains 's/^alias_canon() {/alias_canon() { return 0;/' "C5"
else
  gmut comparaison-textuelle 's/^unmap() {$/unmap() { printf "%s" "$1"; return 0;/; s/^dest_addrs() {.*$/dest_addrs() { local Y; for Y in "$@"; do is_ip "$Y" \&\& printf "%s\\n" "$Y"; done; return 0;/' "A1 A2 A3 A4 A5"
fi
# sans terminal (un agent, une tâche de nuit) : une lecture de l'hôte d'origine ne pose aucune question
if [ -n "$SETSID" ]; then
  : > "$V4/ssh.log"; GA --hosts=$H "git@$H" "git-upload-pack 'grp/repo.git'" >/dev/null
  grep -q "^-o BatchMode=yes git@$H git-upload-pack" "$V4/ssh.log" && pass "lecture de l'hôte d'origine sans terminal : BatchMode=yes (ni phrase secrète, ni clé d'hôte à confirmer)" || bad "BatchMode absent ($(cat "$V4/ssh.log"))"
  : > "$V4/ssh.log"; GA --hosts=$H git@github.com "git-upload-pack 'acme/x.git'" >/dev/null
  grep -q "^git@github.com git-upload-pack" "$V4/ssh.log" && pass "…GitHub : la commande passe telle quelle" || bad "GitHub touché ($(cat "$V4/ssh.log"))"
  sed 's/exec ssh -o BatchMode=yes "\$@"/exec ssh "$@"/' "$GI" > "$V4/garde-sans-batch.sh"
  : > "$V4/ssh.log"; GA --garde="$V4/garde-sans-batch.sh" --hosts=$H "git@$H" "git-upload-pack 'grp/repo.git'" >/dev/null
  ! cmp -s "$GI" "$V4/garde-sans-batch.sh" && ! grep -q BatchMode "$V4/ssh.log" && pass "mutant garde « sans BatchMode » : détecté" || bad "mutant sans BatchMode non détecté"
  if command -v script >/dev/null 2>&1; then
    : > "$V4/ssh.log"; script -qec "PATH=$V4/bin:\$PATH bash $GI --hosts=$H git@$H \"git-upload-pack 'grp/repo.git'\"" /dev/null >/dev/null 2>&1 </dev/null
    grep -q "^git@$H git-upload-pack" "$V4/ssh.log" && pass "…dans un terminal, ssh garde ses questions (une phrase secrète tapée à la main reste possible)" || bad "terminal : $(cat "$V4/ssh.log")"
  fi
else pass "BatchMode : pas de setsid (non joué)"; fi

# la seconde ligne https tient là où le quitteur ne voit rien : le proxy mort arrête le push lui-même
hx() { : > "$V4/cred.log"; O="$(cd "$ESS" && env GIT_CONFIG_GLOBAL="$1" GIT_ASKPASS="$V4/askpass" GIT_TERMINAL_PROMPT=0 timeout 30 git "${@:2}" 2>&1 </dev/null)"
  grep -q '127\.0\.0\.1 port 9' <<<"$O" && [ ! -s "$V4/cred.log" ]; }
HXN=0
hxc() {   # libellé, puis les arguments de git — joué sur la configuration complète, puis sur le mutant (b1)
  local l="$1"; shift
  hx "$V4/complet.cfg" "$@" && pass "https : $l — le proxy mort arrête le push" || bad "https : $l ($O)"
  hx "$V4/mut-bp.cfg" "$@" || HXN=$((HXN + 1))
}
hxc "assistants remis à zéro après le quitteur (-c credential.helper=)" -c credential.helper= -c "credential.helper=$V4/genereux" push --dry-run "https://jb@$H/$A" HEAD:refs/heads/probe
git -C "$ESS" config --local credential.helper ""; git -C "$ESS" config --local --add credential.helper "$V4/genereux"
hxc "assistants remis à zéro dans la configuration du dépôt" push --dry-run "https://jb@$H/$A" HEAD:refs/heads/probe
git -C "$ESS" config --local --unset-all credential.helper
hxc "un mot de passe dans l'URL (aucun assistant consulté)" push --dry-run "https://u:p@$H/$A" HEAD:refs/heads/probe
hxc "un en-tête d'authentification (http.extraHeader)" -c "http.extraHeader=Authorization: Bearer x" push --dry-run "https://$HM/$A" HEAD:refs/heads/probe
hxc "un http.proxy général vidé" -c http.proxy= push --dry-run "https://$HM./$A" HEAD:refs/heads/probe
hxc "http:// avec un utilisateur" push --dry-run "http://jb@$HU/$A" HEAD:refs/heads/probe
[ "$HXN" = 6 ] && pass "mutant (b1) sans proxy mort : les 6 cas partent au réseau (détecté)" || bad "mutant (b1) : $HXN cas sur 6 seulement"
# limite dite : NO_PROXY couvrant l'hôte contourne le proxy mort (git ne l'interroge plus) ; le quitteur reste
O="$(cd "$ESS" && env GIT_CONFIG_GLOBAL="$V4/complet.cfg" NO_PROXY='*' GIT_TERMINAL_PROMPT=0 timeout 30 git push --dry-run "https://jb@$H/$A" HEAD:refs/heads/probe 2>&1 </dev/null)"
! grep -q '127\.0\.0\.1 port 9' <<<"$O" && pass "limite dite : NO_PROXY='*' contourne le proxy mort (just doctor le signale)" || bad "NO_PROXY : comportement inattendu ($O)"

# les autres hôtes ne sont pas touchés
: > "$V4/ssh.log"; O="$(cd "$ESS" && G5 push --dry-run git@github.com:acme/x.git HEAD:refs/heads/probe)"
grep -q "git@github.com git-receive-pack 'acme/x.git'" "$V4/ssh.log" && ! grep -q 'verrou 4' <<<"$O" && pass "GitHub par ssh : le push passe à ssh tel quel" || bad "GitHub ssh touché ($O)"
: > "$V4/cred.log"; O="$(printf 'url=https://github.com/acme/x.git\n\n' | GIT_CONFIG_GLOBAL="$V4/complet.cfg" GIT_TERMINAL_PROMPT=0 git -C "$ESS" credential fill 2>&1)"
grep -q 'GENEREUX get' "$V4/cred.log" && has "$O" "password=secret" && pass "GitHub par https : l'assistant général répond, comme avant" || bad "GitHub https touché ($O)"
[ -z "$(GIT_CONFIG_GLOBAL="$V4/complet.cfg" git config --global --get-urlmatch http.proxy https://github.com/acme/x.git)" ] \
  && pass "GitHub par https : aucun proxy" || bad "GitHub https : un proxy s'applique"
git -C "$ESS" remote set-url t https://github.com/acme/x.git
case "$(GIT_CONFIG_GLOBAL="$V4/complet.cfg" git -C "$ESS" remote get-url --push t)" in DISABLED*) bad "push vers GitHub verrouillé" ;; *) pass "push vers GitHub : aucun pushInsteadOf" ;; esac
# un assistant posé APRÈS le quitteur (comme VS Code à l'attache) n'est jamais consulté
cp "$V4/complet.cfg" "$V4/apres.cfg"; GIT_CONFIG_GLOBAL="$V4/apres.cfg" git config --global --add credential.helper "$V4/genereux"
[ "$(v4_forme "$V4/apres.cfg" u "https://$HM/$A")" = HTTPS ] && pass "assistant général ajouté après le quitteur : jamais consulté (quit=1)" || bad "assistant postérieur consulté"
# rien de l'existant n'est retiré : un assistant ou un proxy posé pour l'hôte reste écrit (inerte derrière les nôtres)
: > "$V4/sien.cfg"; GIT_CONFIG_GLOBAL="$V4/sien.cfg" git config --global "credential.https://$H.helper" store
GIT_CONFIG_GLOBAL="$V4/sien.cfg" git config --global "http.https://$H.proxy" http://proxy.corp.invalid:3128
( cd "$WS5" && GIT_CONFIG_GLOBAL="$V4/sien.cfg" bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' ) >/dev/null 2>&1
[ "$(GIT_CONFIG_GLOBAL="$V4/sien.cfg" git config --global --get-all "credential.https://$H.helper" | head -1)" = store ] \
  && [ "$(GIT_CONFIG_GLOBAL="$V4/sien.cfg" git config --global --get-all "http.https://$H.proxy" | head -1)" = http://proxy.corp.invalid:3128 ] \
  && [ "$(v4_forme "$V4/sien.cfg" u "https://jb@$H/$A")" = HTTPS ] && pass "un assistant et un proxy déjà posés pour l'hôte : gardés dans la configuration, et sans effet" || bad "assistant ou proxy de l'hôte retiré ou actif"

# core.sshCommand personnalisé : jamais écrasé, et dit
: > "$V4/perso.cfg"; GIT_CONFIG_GLOBAL="$V4/perso.cfg" git config --global core.sshCommand "ssh -i /custom/key"
O="$( cd "$WS5" && GIT_CONFIG_GLOBAL="$V4/perso.cfg" bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' 2>&1 )"
[ "$(GIT_CONFIG_GLOBAL="$V4/perso.cfg" git config --global --get core.sshCommand)" = "ssh -i /custom/key" ] && has "$O" "the ssh push guard is NOT installed" \
  && pass "core.sshCommand personnalisé : gardé, et l'absence de la garde dite" || bad "sshCommand personnalisé ($O)"
# DBT_UPSTREAM_PUSH_LOCK=0 : les trois couches de cet hôte retirées, la clé épinglée seule revient
cp "$V4/complet.cfg" "$V4/leve.cfg"
O="$( cd "$WS5" && GIT_CONFIG_GLOBAL="$V4/leve.cfg" bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && DBT_UPSTREAM_PUSH_LOCK=0 && dbt_git_setup' 2>&1 )"
[ "$(GIT_CONFIG_GLOBAL="$V4/leve.cfg" git config --global --get core.sshCommand)" = "ssh -o \"UserKnownHostsFile=$WS5/.devcontainer/upstream_known_hosts $HOME/.ssh/known_hosts\"" ] \
  && [ -z "$(GIT_CONFIG_GLOBAL="$V4/leve.cfg" git config --global --get-all url.DISABLED://.pushInsteadOf)" ] \
  && [ -z "$(GIT_CONFIG_GLOBAL="$V4/leve.cfg" git config --global --get-regexp '^(credential|http)\..*git\.invalid')" ] \
  && [ "$(GIT_CONFIG_GLOBAL="$V4/leve.cfg" git config --global --get credential.helper)" = "$V4/genereux" ] \
  && pass "DBT_UPSTREAM_PUSH_LOCK=0 : garde, proxys morts, quitteurs et 13 préfixes retirés ; la clé épinglée seule, l'assistant général intact" || bad "levée du verrou 4 ($O)"
# garde trop stricte (mutant) : elle refuserait aussi les lectures — le contrôle de lecture le voit
cp "$GI" "$V4/garde.orig"
sed -i 's/^  if \[ "\$IS_READ" = 0 \]; then$/  if true; then/' "$GI"
LU="git-upload-pack 'grp/repo.git'"
if ! cmp -s "$V4/garde.orig" "$GI" && ! lu ls-remote "git@$H:grp/repo.git"; then pass "mutant « garde trop stricte » : détecté (la lecture ne part plus)"; else bad "mutant garde trop stricte non détecté"; fi
cp "$V4/garde.orig" "$GI"

# la garde vit hors du worktree : un commit antérieur extrait (sans git-ssh-garde.sh) ne casse ni la lecture ni le verrou
mv "$WS5/.devcontainer/git-ssh-garde.sh" "$V4/garde.ws"
lu ls-remote "git@$H:grp/repo.git" && [ "$(v4_forme "$V4/complet.cfg" u "jb@$H:$A")" = GARDE ] \
  && pass "garde absente du worktree (lock-checkout d'un commit antérieur) : la lecture passe, le push reste refusé" || bad "garde du worktree absente : $O"
mv "$V4/garde.ws" "$WS5/.devcontainer/git-ssh-garde.sh"
v4_setup mut-ws '_dbt_ssh_guard() { _dbt_ssh_guard_src; }' >/dev/null   # mutant : la garde lancée depuis le worktree (avant)
mv "$WS5/.devcontainer/git-ssh-garde.sh" "$V4/garde.ws"
LUCFG="$V4/mut-ws.cfg"; if ! lu ls-remote "git@$H:grp/repo.git"; then pass "mutant « garde lancée depuis le worktree » : détecté (la lecture casse pendant le rejeu)"; else bad "mutant garde du worktree non détecté"; fi
LUCFG="$V4/complet.cfg"; mv "$V4/garde.ws" "$WS5/.devcontainer/git-ssh-garde.sh"
cp "$V4/mut-ws.cfg" "$V4/migre.cfg"
( cd "$WS5" && GIT_CONFIG_GLOBAL="$V4/migre.cfg" bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && dbt_git_setup' ) >/dev/null 2>&1
[ "$(GIT_CONFIG_GLOBAL="$V4/migre.cfg" git config --global --get core.sshCommand)" = "$SC5" ] \
  && pass "une garde déjà posée depuis le worktree : just setup la repointe vers la copie installée" || bad "garde du worktree non repointée"

# doctor : ce qu'il dit des trois couches
DOC() { ( cd "$WS5" && env GIT_CONFIG_GLOBAL="$1" "${@:2}" bash .devcontainer/dbt-doctor.sh ) 2>/dev/null | sed -n '/^\[upstream/,/^\[worktrees/p'; }
O="$(DOC "$V4/complet.cfg")"
has "$O" "✅ push lock on git.invalid, global (pushInsteadOf: 13 forms" && has "$O" "✅ https and http to git.invalid meet a dead proxy (127.0.0.1:9" \
  && has "$O" "✅ no https credentials for git.invalid (quitter" \
  && has "$O" "✅ ssh push guard: core.sshCommand = ~/.local/libexec/git-ssh-garde.sh, the copy of .devcontainer/git-ssh-garde.sh (git.invalid)" \
  && has "$O" "✅ the ssh push guard refuses git-receive-pack to git.invalid (git@git.invalid, jb@GIT.INVALID, git.invalid., git@[::ffff:" \
  && has "$O" "✅ …and lets git-upload-pack through to git.invalid" \
  && ! grep -E '❌.*(push lock|guard|proxy|quitter|GIT_|NO_PROXY|pushInsteadOf|core\.sshCommand)' <<<"$O" >/dev/null \
  && pass "doctor : les trois couches au vert, la garde et le proxy mort éprouvés hors ligne, aucun ❌ du verrou 4" || bad "doctor verrou 4 ($O)"
O="$(DOC "$V4/mut-a.cfg")"; has "$O" "❌ core.sshCommand is not the ssh push guard" && pass "doctor : garde absente -> ❌" || bad "doctor mutant a ($O)"
O="$(DOC "$V4/mut-bp.cfg")"; has "$O" "❌ no dead proxy for https://git.invalid" && pass "doctor : proxy mort absent -> ❌" || bad "doctor mutant b1 ($O)"
O="$(DOC "$V4/mut-b.cfg")"; has "$O" "❌ https quitter missing for git.invalid" && pass "doctor : quitteur absent -> ❌" || bad "doctor mutant b2 ($O)"
O="$(DOC "$V4/mut-c.cfg")"; has "$O" "❌ global push lock incomplete for git.invalid" && pass "doctor : préfixes manquants -> ❌" || bad "doctor mutant c ($O)"
O="$(DOC "$V4/mut-ws.cfg")"; has "$O" "❌ core.sshCommand runs a guard other than its installed copy" && pass "doctor : garde lancée depuis le worktree -> ❌" || bad "doctor mut-ws ($O)"
echo "# modifiée" >> "$GI"; O="$(DOC "$V4/complet.cfg")"; cp "$V4/garde.orig" "$GI"
has "$O" "❌ the installed ssh push guard (~/.local/libexec/git-ssh-garde.sh) differs" && pass "doctor : copie installée différente de .devcontainer/git-ssh-garde.sh -> ❌" || bad "doctor copie différente ($O)"
git -C "$WS5" config --local "http.https://$H.proxy" ""; O="$(DOC "$V4/complet.cfg")"; git -C "$WS5" config --local --unset-all "http.https://$H.proxy"
has "$O" "❌ a proxy for git.invalid is set in the workspace's own git config" && pass "doctor : un proxy de l'hôte dans la configuration du dépôt -> ❌ (et l'épreuve https n'est pas jouée)" || bad "doctor proxy local ($O)"
O="$(DOC "$V4/complet.cfg" NO_PROXY='*')"; has "$O" "❌ NO_PROXY / no_proxy covers git.invalid (*)" && pass "doctor : NO_PROXY='*' -> ❌" || bad "doctor NO_PROXY ($O)"
O="$(DOC "$V4/complet.cfg" no_proxy=localhost,.invalid)"; has "$O" "❌ NO_PROXY / no_proxy covers git.invalid (invalid)" && pass "doctor : no_proxy=.invalid -> ❌" || bad "doctor no_proxy ($O)"
O="$(DOC "$V4/complet.cfg" NO_PROXY=localhost,127.0.0.1,.example.com)"; ! has "$O" "NO_PROXY / no_proxy covers" && pass "doctor : un NO_PROXY qui ne couvre pas l'hôte -> rien" || bad "doctor NO_PROXY fausse alerte ($O)"
O="$(DOC "$V4/complet.cfg" GIT_SSH_COMMAND=ssh)"; has "$O" "❌ GIT_SSH_COMMAND is exported" && pass "doctor : GIT_SSH_COMMAND exporté -> ❌" || bad "doctor GIT_SSH_COMMAND ($O)"
O="$(DOC "$V4/complet.cfg" GIT_SSH="$V4/gitssh")"; has "$O" "·  GIT_SSH is exported: git uses it only without core.sshCommand" && ! grep -q '❌.*GIT_SSH' <<<"$O" \
  && pass "doctor : GIT_SSH seul -> une ligne d'information, pas de ❌ (git préfère core.sshCommand)" || bad "doctor GIT_SSH ($O)"
O="$(DOC "$V4/complet.cfg" GIT_CONFIG_PARAMETERS="'core.sshCommand'='ssh'")"; has "$O" "❌ git configuration exported in the environment touches the push lock (GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT: core.sshcommand)" \
  && pass "doctor : GIT_CONFIG_PARAMETERS avec core.sshCommand -> ❌" || bad "doctor GIT_CONFIG_PARAMETERS ($O)"
O="$(DOC "$V4/complet.cfg" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://$H.proxy" GIT_CONFIG_VALUE_0=)"; has "$O" "touches the push lock (GIT_CONFIG_PARAMETERS / GIT_CONFIG_COUNT: http.https://git.invalid.proxy)" \
  && pass "doctor : GIT_CONFIG_COUNT/KEY_0 sur le proxy de l'hôte -> ❌" || bad "doctor GIT_CONFIG_COUNT ($O)"
has "$(DOC "$V4/complet.cfg")" "·  GIT_CONFIG_GLOBAL is exported: git reads $V4/complet.cfg" && pass "doctor : GIT_CONFIG_GLOBAL exporté -> dit (le verrou vérifié est celui de ce fichier)" || bad "doctor GIT_CONFIG_GLOBAL"
O="$(DOC "$V4/perso.cfg")"; has "$O" "❌ core.sshCommand is customised: the ssh push guard is not installed" && pass "doctor : core.sshCommand personnalisé -> ❌, avec la ligne à y mettre" || bad "doctor perso ($O)"

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
# onCreateCommand : les deux moteurs seuls, avant que l'éditeur se connecte
O="$( (cd "$FW" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_engines "$PWD"') 2>&1)"
check "onCreate (dbt_engines) : python du venv v1 posé avant post-create" test -x "$DBT_V1_VENV/bin/python"
check "…dbt v2 posé aussi" test -x "$DBT_BIN_DIR/dbt"
check "…sans aucun worktree (rien d'autre que les moteurs)" test ! -e "$FW/v1"
OUT="$(life "$FW" create)"
[ "$(grep -c '^installer ' "$STUB_LOG")" = 1 ] && pass "post-create retrouve les moteurs de onCreate : dbt v2 non réinstallé" || bad "dbt v2 réinstallé après onCreate"

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

# =============================================================================
echo "== v4 : DBT_V4_PRODUCTS, référents nés ici (referents.conf), espace de datasets de la v4 =="
O="$(RUN v4 parse)"; has "$O" "has no v4" && pass "projet seul : pas de v4 (just v4 refusé)" || bad "v4 hors flotte ($O)"
git config --global url."file://$W/gh/".insteadOf "https://github.com/"   # epsilon : son dépôt reste joignable
LK lock-release delta >/dev/null   # le lock-checkout refusé plus haut a déjà détaché v1/delta (il ne vérifie pas tout avant d'agir)
LOCKS_BEFORE="$(git config --global --get-all url.DISABLED://.pushInsteadOf | sort)"
printf 'DATASET_PREFIX=JDOE\n' >> "$FW/profiles/dbt.env"
printf '/v4/\n' >> "$FW/.gitignore"
# delta : sa v4 est ouverte LÀ OÙ VIVENT ses branches, depuis sa v2 publiée ; le coordinateur la suit
git -C "$W/homes/delta.git" branch v4 v2
# rho : un référent né ici — son propre dépôt, une branche v4, aucun dépôt d'origine
git init -q --bare -b main "$W/homes/rho.git"
RS="$W/rho-src"; git init -q -b v4 "$RS"; mkdir -p "$RS/dbt/models"
printf 'name: rho\nprofile: "prof_rho"\n' > "$RS/dbt/dbt_project.yml"; printf 'select 1\n' > "$RS/dbt/models/m_rho.sql"
git -C "$RS" add -A && git -C "$RS" commit -q -m "rho, né ici" && git -C "$RS" push -q "$W/homes/rho.git" v4
cat >> "$FW/.devcontainer/dbt.conf" <<'EOF'
DBT_V4_PRODUCTS="delta alpha"
DBT_BQ_DATASET_PREFIX_V4="JDOE_V4"
EOF
# une flotte qui déclare une v4 nomme sa copie principale, par son chemin réel : ici FW
echo "DBT_V4_MAIN_WS=\"$FW\"" >> "$FW/.devcontainer/dbt.conf"
O="$(FRUN referent-add sigma nowhere)"; has "$O" "is not a git URL" && pass "referent-add : URL invalide refusée" || bad "referent-add URL ($O)"
O="$(FRUN referent-add delta "$W/homes/rho.git")"; has "$O" "already declared in .devcontainer/products.conf" && pass "referent-add : nom d'un produit refusé" || bad "referent-add doublon produit ($O)"
O="$(FRUN referent-add rho "$W/homes/rho.git" dbt)"
has "$O" "→ rho declared in .devcontainer/referents.conf" && pass "referent-add rho : référent déclaré" || bad "referent-add ($(tail -5 <<<"$O"))"
grep -qE "^rho +dbt +$W/homes/rho.git$" "$FW/.devcontainer/referents.conf" && pass "…ligne NAME SUBDIR HOME dans referents.conf" || bad "referents.conf inattendu"
check "rho : v4/rho/ sur rho/v4, qui suit home-rho/v4" test "$(git -C "$FW" rev-parse --abbrev-ref 'rho/v4@{upstream}' 2>/dev/null)" = home-rho/v4
check "…le projet dbt de v4/rho est trouvé" test -f "$FW/v4/rho/dbt/dbt_project.yml"
refute "…aucun remote up-rho (pas d'origine)" git -C "$FW" remote get-url up-rho
refute "…ni v1/rho ni v2/rho" test -e "$FW/v1/rho" -o -e "$FW/v2/rho"
check "…profil prof_rho ajouté au hub" grep -q '^prof_rho:' "$FW/profiles/profiles.yml"
check "verrous de push inchangés (aucun hôte ajouté ni retiré)" test "$(git config --global --get-all url.DISABLED://.pushInsteadOf | sort)" = "$LOCKS_BEFORE"
check "delta : v4/delta/ sur delta/v4, qui suit home-delta/v4" test "$(git -C "$FW" rev-parse --abbrev-ref 'delta/v4@{upstream}' 2>/dev/null)" = home-delta/v4
check "…au commit de sa v2 publiée" test "$(git -C "$FW/v4/delta" rev-parse HEAD)" = "$(git -C "$W/homes/delta.git" rev-parse v2)"
git -C "$FW" worktree list --porcelain | awk -v p="$FW/v4/delta" '$1=="worktree"{f=(substr($0,10)==p)} f&&$1=="locked"{x=1} END{exit !x}' && pass "…verrouillée contre le prune" || bad "v4/delta non verrouillée"
has "$O" "v4/alpha/: not opened yet" && pass "alpha (déclaré, v4 non publiée) : dit, jamais créé depuis v1 ni l'origine" || bad "v4 non ouverte non signalée"
refute "…ni v4/alpha ni branche alpha/v4" test -e "$FW/v4/alpha" -o -n "$(git -C "$FW" branch --list alpha/v4)"
refute "beta (hors DBT_V4_PRODUCTS) : pas de v4" test -e "$FW/v4/beta"
check "profiles/v4.env : DATASET_PREFIX de la v4" grep -qx 'DATASET_PREFIX=JDOE_V4' "$FW/profiles/v4.env"
check "…et sinon profiles/dbt.env à l'identique (généré)" diff <(tail -n +3 "$FW/profiles/v4.env") <(sed 's/^DATASET_PREFIX=.*/DATASET_PREFIX=JDOE_V4/' "$FW/profiles/dbt.env")
check ".env de v4/delta -> profiles/v4.env" test "$(readlink -f "$FW/v4/delta/dbt/.env")" = "$(readlink -f "$FW/profiles/v4.env")"
check ".env de v4/rho -> profiles/v4.env" test "$(readlink -f "$FW/v4/rho/dbt/.env")" = "$(readlink -f "$FW/profiles/v4.env")"
check ".env de v2/delta inchangé -> profiles/dbt.env" test "$(readlink -f "$FW/v2/delta/dbt/.env")" = "$(readlink -f "$FW/profiles/dbt.env")"
check "réglages de la fenêtre v4 : dbt v2, envFile de la v4" python3 -c "import json; d=json.load(open('$FW/v4/delta/.vscode/settings.json')); assert d['dbt.dbtMajorVersion']=='v2' and d['python.envFile'].endswith('profiles/v4.env')"
check "racine propre (v4/ ignoré)" test -z "$(git -C "$FW" status --porcelain -- v4)"

echo "== v4 : le garde-fou, dans les deux sens =="
FJ() { printf '{"database":"sandbox-prj","schema":"%s","alias":"%s","name":"%s","resource_type":"model","package_name":"%s"}\n' "$1" "$2" "$2" "${3:-delta}"; }
FJ JDOE_V4_DELTA__X a > "$W/ls-v4ok.jsonl"; FJ JDOE_DELTA__X a > "$W/ls-v2ok.jsonl"; FJ JDOE_V4X a > "$W/ls-v4x.jsonl"
O="$(FRUN v4 delta parse)"; has "$O" "ENGINE=$DBT_BIN_DIR/dbt CWD=$FW/v4/delta/dbt " && grep -q 'PFX=JDOE_V4$' <<<"$O" && pass "just v4 delta → dbt v2 dans v4/delta, DATASET_PREFIX de la v4" || bad "v4 delta ($O)"
O="$(FRUN v2 delta parse)"; grep -q 'PFX=JDOE$' <<<"$O" && pass "just v2 delta → garde DATASET_PREFIX=JDOE" || bad "v2 delta ($O)"
O="$(DATASET_PREFIX=JDOE_V4 FRUN v2 delta parse)"; grep -q 'PFX=JDOE$' <<<"$O" && pass "…même avec DATASET_PREFIX=JDOE_V4 exporté par le shell (le mode choisit le fichier)" || bad "variable héritée ($O)"
O="$(STUB_LS_FILE="$W/ls-v4ok.jsonl" FRUN v4 delta run -s a)"; has "$O" "all inside the sandbox" && has "$O" "ARGS=run -s a" && pass "v4 : écriture sous JDOE_V4_* acceptée" || bad "écriture v4 légitime ($O)"
O="$(STUB_LS_FILE="$W/ls-v2ok.jsonl" FRUN v4 delta run -s a)"; has "$O" "outside the sandbox" && has "$O" "dataset JDOE_V4 or JDOE_V4_*" && pass "v4 : écriture sous JDOE_ (l'espace de la v2) refusée" || bad "v4 hors de son espace ($O)"
refute "…et le moteur n'a pas été lancé" grep -qF "ARGS=run" <<<"$O"
O="$(STUB_LS_FILE="$W/ls-v4ok.jsonl" FRUN v2 delta run -s a)"; has "$O" "outside the sandbox" && has "$O" "never JDOE_V4" && pass "v2 : écriture sous JDOE_V4_* refusée" || bad "v2 dans l'espace v4 ($O)"
O="$(STUB_LS_FILE="$W/ls-v4x.jsonl" FRUN v4 delta run -s a)"; has "$O" "outside the sandbox" && pass "v4 : JDOE_V4X n'est pas l'espace JDOE_V4 (borne « _ »)" || bad "borne du préfixe ($O)"
O="$(FRUN v4 alpha parse)"; has "$O" "no dbt project in v4/alpha/" && pass "v4 déclarée non ouverte : refusée" || bad "v4 non ouverte ($O)"
O="$(FRUN v4 beta parse)"; has "$O" "beta has no v4" && pass "v4 d'un produit hors DBT_V4_PRODUCTS : refusée" || bad "v4 beta ($O)"
O="$(FRUN v1 rho parse)"; has "$O" "is a referent, born here" && pass "v1 d'un référent : refusée" || bad "v1 rho ($O)"
O="$(FRUN v2 rho build -s a)"; has "$O" "is a referent, born here" && pass "v2 d'un référent : refusée" || bad "v2 rho ($O)"
O="$(FRUN v4 rho parse)"; has "$O" "CWD=$FW/v4/rho/dbt " && grep -q 'PFX=JDOE_V4$' <<<"$O" && pass "just v4 rho → v4/rho, espace de la v4" || bad "v4 rho ($O)"
O="$(cd "$FW" && bash .devcontainer/dbt-run.sh upstream-pull rho 2>&1)"; has "$O" "born here" && pass "upstream-pull d'un référent : rien à reprendre" || bad "upstream-pull rho ($O)"
O="$(FRUN product-add rho "$W/fleet-up/alpha.git")"; has "$O" "already declared in .devcontainer/referents.conf" && pass "product-add : nom d'un référent refusé" || bad "product-add rho ($O)"
printf 'DATASET_PREFIX=JDOE_V4\n' >> "$FW/profiles/env/beta.env"
O="$(FRUN v2 beta parse)"; has "$O" "that is the v4 space" && pass "v2 sous le préfixe de la v4 (fichier d'env du produit) : refusé, parse compris" || bad "v2 sous JDOE_V4 ($O)"
sed -i '/^DATASET_PREFIX=/d' "$FW/profiles/env/beta.env"
printf 'DATASET_PREFIX=JDOE\n' > "$FW/profiles/env/delta.env"
O="$(FRUN v4 delta parse)"; has "$O" "the v4 space is JDOE_V4" && pass "v4 dont le fichier d'env du produit repose un autre préfixe : refusé" || bad "v4 sous JDOE ($O)"
rm -f "$FW/profiles/env/delta.env"
ln -sfn ../../../profiles/dbt.env "$FW/v4/delta/dbt/.env"
O="$(FRUN v4 delta parse)"; has "$O" "does not point to profiles/v4.env" && pass ".env de v4/delta vers dbt.env : refusé (l'extension écrirait la v4 sous JDOE_)" || bad ".env v4 ($O)"
O="$(life "$FW" start)"; check "…redémarrage : lien reposé sur profiles/v4.env" test "$(readlink -f "$FW/v4/delta/dbt/.env")" = "$(readlink -f "$FW/profiles/v4.env")"
has "$O" "(re-pointed)" && pass "…et dit" || bad "lien reposé en silence"
ln -sfn ../../../profiles/v4.env "$FW/v2/delta/dbt/.env"
O="$(FRUN v2 delta parse)"; has "$O" "points to profiles/v4.env" && pass ".env de v2/delta vers v4.env : refusé" || bad ".env v2 ($O)"
ln -sfn ../../../profiles/dbt.env "$FW/v2/delta/dbt/.env"
for X in OTHER_V4 JDOEV4 "JDOE_V4;x" "" JDOE_V4_D005 JDOE_D005 JDOE_V4_d005_X JDOE_V4_X_S001; do
  sed -i "s/^DBT_BQ_DATASET_PREFIX_V4=.*/DBT_BQ_DATASET_PREFIX_V4=\"$X\"/" "$FW/.devcontainer/dbt.conf"
  O="$(FRUN v4 delta parse)"; has "$O" "every v4 command is refused" && pass "DBT_BQ_DATASET_PREFIX_V4='$X' (pas JDOE_<x>, ou un segment à la forme d'un flux) : v4 refusée" || bad "préfixe v4 '$X' accepté ($O)"
done
# shellcheck disable=SC2034  # lues par _dbt_v4_prefix_ok, dans le même sous-shell
PFXOK() { ( source "$FW/.devcontainer/lib-dbt.sh"; DBT_BQ_DATASET_PREFIX=JDOE; DBT_BQ_DATASET_PREFIX_V4="$1"; _dbt_v4_prefix_ok ); }
PFXOK JDOE_V4 && PFXOK JDOE_V4_X && PFXOK JDOE_V4_DD05 && PFXOK JDOE_V4_D05 && PFXOK JDOE_V4_D0050 && ! PFXOK JDOE_V4_D005 \
  && pass "_dbt_v4_prefix_ok : JDOE_V4, JDOE_V4_X, JDOE_V4_DD05, JDOE_V4_D05, JDOE_V4_D0050 acceptés (pas la forme d'un flux)" || bad "_dbt_v4_prefix_ok trop strict"
sed -i 's/^DBT_BQ_DATASET_PREFIX_V4=.*/DBT_BQ_DATASET_PREFIX_V4="JDOE_V4"/' "$FW/.devcontainer/dbt.conf"

echo "== v4 : hooks — une approbation de la v2 n'ouvre jamais la v4 =="
for V in v2 v4; do printf "{{ config(post_hook='select 1') }}\nselect 1\n" > "$FW/$V/delta/dbt/models/hooked.sql"; done
echo 'DBT_HOOKS_COMPILE_OK="delta"' >> "$FW/.devcontainer/dbt.conf"
O="$(FRUN v2 delta compile)"; has "$O" "ARGS=compile" && pass "DBT_HOOKS_COMPILE_OK=delta : v2 compile accepté" || bad "v2 compile ($O)"
O="$(FRUN v4 delta compile)"; has "$O" "hooks nobody has reviewed" && has "$O" "may name v4/delta" && pass "…v4 compile refusé, le nom à relire (v4/delta) est donné" || bad "v4 ouverte par l'approbation v2 ($O)"
O="$(FRUN v4 delta check)"; has "$O" "hooks nobody has reviewed" && pass "…dbt check (v2.0.8) compte comme commande à hooks en v4" || bad "v4 check ($O)"
O="$(FRUN v2 delta check)"; has "$O" "hooks nobody has reviewed" && ! has "$O" "ARGS=" && pass "…et en v2 aussi : DBT_HOOKS_COMPILE_OK n'ouvre que compile et show (check refusé)" || bad "v2 check sans contrôle des hooks ($O)"
echo 'DBT_HOOKS_COMPILE_OK="v4/delta"' >> "$FW/.devcontainer/dbt.conf"
O="$(FRUN v4 delta compile)"; has "$O" "has no seal of its own" && ! has "$O" "ARGS=compile" && pass "DBT_HOOKS_COMPILE_OK=v4/delta : v4 compile refusé (une v4/<produit> n'a pas de sceau)" || bad "v4 compile ($O)"
O="$(FRUN v4 delta run -s a)"; has "$O" "hooks nobody has reviewed" && pass "…v4 run : toujours refusé" || bad "v4 run ($O)"
printf 'x\ty\tz\n' > "$FW/.devcontainer/hooks.approved"; echo 'DBT_HOOKS_REVIEWED_V2=1' >> "$FW/.devcontainer/dbt.conf"
O="$(STUB_LS_FILE="$W/ls-v4ok.jsonl" FRUN v4 delta run -s a)"; has "$O" "hooks nobody has reviewed" && pass "DBT_HOOKS_REVIEWED_V2=1 : la v4 reste fermée" || bad "v4 ouverte par REVIEWED_V2 ($O)"
O="$(FRUN hooks-approve v4/delta)"; has "$O" "no approved-hooks list" && pass "hooks-approve v4/… : refusé (pas de liste pour la v4)" || bad "hooks-approve v4 ($O)"
sed -i -e '/^DBT_HOOKS_COMPILE_OK=/d' -e '/^DBT_HOOKS_REVIEWED_V2=/d' "$FW/.devcontainer/dbt.conf"
rm -f "$FW/.devcontainer/hooks.approved" "$FW/v2/delta/dbt/models/hooked.sql" "$FW/v4/delta/dbt/models/hooked.sql"

echo "== v4 : \`dbt\` dans v4/, global-v4/ et ailleurs =="
O="$(CWD="$FW/v4/delta/dbt/models" FRUN auto parse)"; has "$O" "CWD=$FW/v4/delta/dbt/models" && grep -q 'PFX=JDOE_V4$' <<<"$O" && pass "\`dbt\` dans v4/delta/ → garde-fou de la v4, dossier courant gardé" || bad "auto v4 ($O)"
O="$(CWD="$FW/v4/delta/dbt" FRUN auto run)"; has "$O" "without a selection" && pass "…\`dbt run\` y passe par le garde-fou" || bad "auto v4 non gardé ($O)"
mkdir -p "$FW/v4/beta"; O="$(CWD="$FW/v4/beta" FRUN auto parse)"; has "$O" "beta has no v4" && pass "\`dbt\` dans v4/<produit sans v4>/ : refusé" || bad "auto v4 beta ($O)"; rmdir "$FW/v4/beta"
mkdir -p "$FW/probe/sub"; printf 'name: probe\n' > "$FW/probe/dbt_project.yml"
O="$(CWD="$FW/probe/sub" FRUN auto parse)"; has "$O" "a dbt project outside" && ! has "$O" "ARGS=parse" && pass "\`dbt\` dans un projet dbt inconnu de l'espace de travail : refusé, jamais dbt v2 brut" || bad "projet inconnu lancé ($O)"
rm -rf "$FW/probe"
O="$(CWD="$FW" FRUN auto --version)"; has "$O" "dbt 2.0.0" && pass "…hors de tout projet : dbt v2 nu, comme avant" || bad "auto hors projet ($O)"
mkdir -p "$FW/global-v4"; printf 'name: fleet_global_v4\nprofile: "prof_global"\n' > "$FW/global-v4/dbt_project.yml"
life "$FW" start >/dev/null
check "global-v4/ : .env -> profiles/v4.env (cycle de vie)" test "$(readlink -f "$FW/global-v4/.env")" = "$(readlink -f "$FW/profiles/v4.env")"
O="$(FRUN global-v4 parse)"; has "$O" "ENGINE=$DBT_BIN_DIR/dbt CWD=$FW/global-v4 " && grep -q 'PFX=JDOE_V4$' <<<"$O" && pass "just global-v4 → dbt v2, espace de la v4" || bad "global-v4 ($O)"
O="$(CWD="$FW/global-v4" FRUN auto parse)"; grep -q 'PFX=JDOE_V4$' <<<"$O" && pass "\`dbt\` dans global-v4/ → garde-fou de la v4" || bad "auto global-v4 ($O)"
{ FJ JDOE_V4_X T alpha | sed 's/"name":"T"/"name":"a"/'; FJ JDOE_V4_X T gamma | sed 's/"name":"T"/"name":"b"/'; } > "$W/ls-dup4.jsonl"
O="$(STUB_LS_FILE="$W/ls-dup4.jsonl" FRUN global-v4 run -s a)"; has "$O" "written by several nodes of global-v4/" && has "$O" "alpha.a, gamma.b" && pass "global-v4 : deux nœuds, une table → écriture refusée" || bad "collision global-v4 ($O)"
O="$(STUB_LS_FILE="$W/ls-dup4.jsonl" FRUN destinations global-v4)"; has "$O" "global-v4: 1 relation(s) written by several nodes" && has "$O" "every node in the v4 space" && pass "just destinations global-v4 : collisions et espace" || bad "destinations global-v4 ($O)"
echo 'DBT_SANDBOX_NEVER_BUILD="delta.a"' >> "$FW/.devcontainer/dbt.conf"
O="$(STUB_LS_FILE="$W/ls-v4ok.jsonl" FRUN global-v4 run -s a)"; has "$O" "never built in the sandbox" && has "$O" "delta.a" && pass "global-v4 : DBT_SANDBOX_NEVER_BUILD (noms <paquet>.<nœud>) appliqué" || bad "NEVER_BUILD global-v4 ($O)"
O="$(STUB_LS_FILE="$W/ls-v4ok.jsonl" FRUN v4 delta run -s a)"; has "$O" "never built in the sandbox" && pass "…et dans v4/delta (paquet du projet)" || bad "NEVER_BUILD v4 ($O)"
sed -i '/^DBT_SANDBOX_NEVER_BUILD=/d' "$FW/.devcontainer/dbt.conf"

echo "== v4 : hooks de global-v4 — sous preuve, son sceau recalculé par le garde-fou à chaque compile/show =="
G="$FW/global-v4"; mkdir -p "$G/macros" "$G/dbt_packages" "$FW/docs"
printf 'name: fleet_global_v4\nprofile: "prof_global"\non-run-start: ["select 1"]\n' > "$G/dbt_project.yml"
printf 'packages:\n  - local: ../v4/delta/dbt\n' > "$G/packages.yml"
printf 'packages:\n- local: ../v4/delta/dbt\n  name: delta\nsha1_hash: 0\n' > "$G/package-lock.yml"
ln -sfn ../../v4/delta/dbt "$G/dbt_packages/delta"
printf '{%% macro m() %%}{%% endmacro %%}\n' > "$G/macros/m.sql"
SEAL() { ( cd "$FW" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_hooks_v4_seal' ) 2>/dev/null; }
PROOF() { printf '# preuve\n\nVERDICT HOOKS GLOBAL-V4 : PREUVE OK ; TÉMOINS OK ; sceau %s\n' "${1:-$(SEAL)}" > "$FW/docs/hooks-v4.md"; }
S0="$(SEAL)"; [[ "$S0" =~ ^[0-9a-f]{20}$ ]] && pass "dbt_hooks_v4_seal : un sceau de 20 hex ($S0)" || bad "sceau ($S0)"
[ "$(SEAL)" = "$S0" ] && pass "…stable d'un calcul à l'autre" || bad "sceau instable"
O="$(FRUN global-v4 compile)"; has "$O" "hooks nobody has reviewed" && pass "global-v4 non listé : compile refusé (hooks)" || bad "global-v4 non listé ($O)"
echo 'DBT_HOOKS_COMPILE_OK="global-v4"' >> "$FW/.devcontainer/dbt.conf"
O="$(FRUN global-v4 compile)"; has "$O" "names no proof" && ! has "$O" "ARGS=compile" && pass "listé, DBT_HOOKS_V4_PROOF vide : refusé" || bad "sans preuve ($O)"
for X in /etc/passwd ../x docs/../../x; do
  echo "DBT_HOOKS_V4_PROOF=\"$X\"" >> "$FW/.devcontainer/dbt.conf"
  O="$(FRUN global-v4 compile)"; has "$O" "inside the workspace" && ! has "$O" "ARGS=compile" && pass "DBT_HOOKS_V4_PROOF='$X' (hors de l'espace de travail) : refusé" || bad "preuve hors de l'espace de travail ($O)"
done
echo 'DBT_HOOKS_V4_PROOF="docs/hooks-v4.md"' >> "$FW/.devcontainer/dbt.conf"
O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "preuve absente : refusé" || bad "preuve absente ($O)"
PROOF; O="$(FRUN global-v4 compile)"; has "$O" "ARGS=compile" && has "$O" "proof of its hooks holds (seal $S0" && pass "preuve au sceau actuel : compile accepté, et dit pourquoi" || bad "compile sous preuve ($O)"
O="$(FRUN global-v4 show -s a)"; has "$O" "ARGS=show -s a" && pass "…show accepté" || bad "show sous preuve ($O)"
# ce que le sceau ne voit pas : --vars (il l'emporte sur les vars disable_* d'elementary du dbt_project.yml scellé), un autre profil
unsealed() { O="$(FRUN global-v4 compile "$@")"
  has "$O" "the proof of its hooks holds for" && has "$O" "refused" && ! has "$O" "ARGS=" && pass "sous preuve, compile $* : refusé (hors du sceau)" || bad "compile $* sous preuve ($O)"; }
unsealed --vars '{a: 1}'; unsealed '--vars={a: 1}'; unsealed --profile prof_x; unsealed --profile=prof_x
O="$(FRUN global-v4 show -s a --vars '{a: 1}')"; has "$O" "with --vars" && ! has "$O" "ARGS=" && pass "…show --vars : refusé" || bad "show --vars sous preuve ($O)"
O="$(DBT_PROFILE=prof_x FRUN global-v4 compile)"; has "$O" "DBT_PROFILE=prof_x" && ! has "$O" "ARGS=" && pass "…DBT_PROFILE exporté : refusé" || bad "DBT_PROFILE sous preuve ($O)"
O="$(FRUN global-v4 parse --vars '{a: 1}')"; has "$O" "ARGS=parse --vars {a: 1}" && pass "…parse --vars (aucun hook) : accepté" || bad "parse --vars global-v4 ($O)"
O="$(FRUN v4 delta compile --vars '{a: 1}')"; has "$O" "ARGS=compile --vars {a: 1}" && pass "…v4/delta sans hook, compile --vars (appliquer-redescente.sh) : accepté" || bad "v4 compile --vars ($O)"
O="$(CWD="$G" FRUN auto compile)"; has "$O" "ARGS=compile" && has "$O" "proof of its hooks holds" && pass "…\`dbt compile\` dans global-v4/ : le même contrôle" || bad "auto global-v4 ($O)"
O="$(STUB_LS_FILE="$W/ls-v4ok.jsonl" FRUN global-v4 run -s a)"; has "$O" "hooks nobody has reviewed" && ! has "$O" "ARGS=run" && pass "…run : toujours refusé" || bad "run sous preuve ($O)"
O="$(FRUN global-v4 test)"; has "$O" "hooks nobody has reviewed" && pass "…test : toujours refusé" || bad "test sous preuve ($O)"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "✅ global-v4: compile/show allowed — the proof of its hooks holds (seal $S0" && pass "doctor : preuve valable, dite" || bad "doctor preuve ($(grep global-v4 <<<"$O"))"
# sealcase NOM COMMANDE… — une altération : le sceau change, compile refusé (et show), puis tout est remis
sealcase() {
  local nom="$1"; shift; cp -a "$FW" "$W/fleet-avant-sceau"
  eval "$*"
  local S; S="$(SEAL)"
  O="$(FRUN global-v4 compile)"
  if [ "$S" != "$S0" ] && has "$O" "does not hold for the files on disk (seal now ${S:-}" && ! has "$O" "ARGS=compile"; then pass "sceau : $nom → compile refusé"; else bad "sceau : $nom ($S, $O)"; fi
  rm -rf "$FW"; mv "$W/fleet-avant-sceau" "$FW"
}
sealcase "macro de global-v4 modifiée" 'echo "{# x #}" >> "$G/macros/m.sql"'
sealcase "macro ajoutée dans un sous-dossier" 'mkdir -p "$G/macros/a" && echo x > "$G/macros/a/b.sql"'
sealcase "on-run-end ajouté à global-v4/dbt_project.yml" 'echo "on-run-end: [\"select 2\"]" >> "$G/dbt_project.yml"'
sealcase "packages.yml de global-v4 modifié" 'echo "# x" >> "$G/packages.yml"'
sealcase "package-lock.yml modifié" 'sed -i "s/^sha1_hash: .*/sha1_hash: 1/" "$G/package-lock.yml"'
sealcase "dependencies.yml ajouté (sans local)" 'printf "packages:\n  - package: x/y\n" > "$G/dependencies.yml"'
sealcase "on-run-start ajouté au dbt_project.yml d un membre" 'echo "on-run-start: [\"drop table x\"]" >> "$FW/v4/delta/dbt/dbt_project.yml"'
sealcase "packages.yml d un membre ajouté" 'printf "packages:\n  - package: x/y\n" > "$FW/v4/delta/dbt/packages.yml"'
sealcase "profiles/v4.env modifié" 'echo "ELEMENTARY=1" >> "$FW/profiles/v4.env"'
sealcase "profiles/profiles.yml modifié" 'echo "# x" >> "$FW/profiles/profiles.yml"'
sealcase "hooks.approved modifié" 'printf "x\ty\toperation\n" >> "$FW/.devcontainer/hooks.approved"'
sealcase "vendor/ ajouté (un paquet recopié)" 'mkdir -p "$G/vendor/vend" && echo "name: vend" > "$G/vendor/vend/dbt_project.yml"'
sealcase "copie d un membre sans lien à la place du lien" 'rm "$G/dbt_packages/delta" && mkdir "$G/dbt_packages/delta" && cp "$FW/v4/delta/dbt/dbt_project.yml" "$G/dbt_packages/delta/"'
sealcase "moteur dbt v2 d une autre version" 'export STUB_VERSION="dbt 2.0.9"'
unset STUB_VERSION
# unsealable NOM COMMANDE… — pas de sceau : compile refusé, « cannot be sealed »
unsealable() {
  local nom="$1"; shift; cp -a "$FW" "$W/fleet-avant-sceau"
  eval "$*"
  O="$(FRUN global-v4 compile)"
  if [ -z "$(SEAL)" ] && has "$O" "cannot be sealed" && ! has "$O" "ARGS=compile"; then pass "pas de sceau : $nom → compile refusé"; else bad "pas de sceau : $nom ($O)"; fi
  rm -rf "$FW"; mv "$W/fleet-avant-sceau" "$FW"
}
unsealable "lien dans macros/" 'ln -s /etc/hostname "$G/macros/lien.sql"'
unsealable "fichier spécial dans macros/" 'mkfifo "$G/macros/f"'
unsealable "macros/ absent" 'rm -rf "$G/macros"'
unsealable "vendor/ est un lien" 'ln -s macros "$G/vendor"'
unsealable "membre déclaré entre guillemets" 'echo "  - local: \"../v4/delta/dbt\"" >> "$G/packages.yml"'
unsealable "membre en flux ({local: …})" 'echo "  - {local: ../v2/delta/dbt}" >> "$G/packages.yml"'
unsealable "local dans dependencies.yml" 'printf "packages:\n  - local: ../v2/delta/dbt\n" > "$G/dependencies.yml"'
unsealable "paquet installé en plus du verrou" 'mkdir "$G/dbt_packages/autre"'
unsealable "paquet du verrou absent" 'printf -- "- package: x/autre\n  name: autre\n  version: 1.0.0\n" >> "$G/package-lock.yml"'
unsealable "lien d un membre remplacé par une copie (son .env est un lien)" 'rm "$G/dbt_packages/delta" && cp -a "$FW/v4/delta/dbt" "$G/dbt_packages/delta"'
unsealable "lien d un membre vers la v2" 'ln -sfn ../../v2/delta/dbt "$G/dbt_packages/delta"'
unsealable "nom de paquet invalide" 'mkdir "$G/dbt_packages/a.b"'
[ -z "$(DBT_BIN_DIR="$W/vide" SEAL)" ] && pass "pas de sceau : moteur dbt v2 absent" || bad "sceau sans moteur"
# la porte : une seule ligne de verdict ancrée, PREUVE OK et TÉMOINS OK sur la ligne du sceau
porte() { local nom="$1" texte="$2"; printf '%b' "$texte" > "$FW/docs/hooks-v4.md"
  O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "porte : $nom → refusé" || bad "porte : $nom ($O)"; }
BON="VERDICT HOOKS GLOBAL-V4 : PREUVE OK ; TÉMOINS OK ; sceau $S0"
porte "verdict PREUVE REFUS" "VERDICT HOOKS GLOBAL-V4 : PREUVE REFUS ; TÉMOINS OK ; sceau $S0\n"
porte "verdict TÉMOINS ÉCHEC" "VERDICT HOOKS GLOBAL-V4 : PREUVE OK ; TÉMOINS ÉCHEC ; sceau $S0\n"
porte "verdict sans les témoins" "VERDICT HOOKS GLOBAL-V4 : PREUVE OK ; sceau $S0\n"
porte "sceau périmé" "VERDICT HOOKS GLOBAL-V4 : PREUVE OK ; TÉMOINS OK ; sceau 0123456789abcdef0123\n"
porte "deux verdicts" "VERDICT HOOKS GLOBAL-V4 : PREUVE REFUS ; TÉMOINS OK ; sceau $S0\n$BON\n"
porte "un autre sceau cité" "Sceau : \`0123456789abcdef0123\`\n$BON\n"
porte "ancienne bannière PREUVE HOOKS" "**PREUVE HOOKS GLOBAL-V4 : OK**\n$BON\n"
porte "verdict non ancré (gras)" "**$BON**\n"
porte "verdict suivi d un texte" "$BON (à revoir)\n"
porte "verdict en CRLF" "$BON\r\n"
PROOF; O="$(FRUN global-v4 compile)"; has "$O" "ARGS=compile" && pass "preuve rétablie : compile de nouveau accepté" || bad "preuve rétablie ($O)"
echo "{# x #}" >> "$G/macros/m.sql"
O="$(FRUN global-v4 parse)"; has "$O" "ARGS=parse" && pass "sceau périmé : parse (aucun hook) reste accepté, pour refaire la preuve" || bad "parse sous sceau périmé ($O)"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "❌ global-v4: the proof of its hooks (docs/hooks-v4.md) does not hold" && pass "doctor : preuve périmée, signalée" || bad "doctor preuve périmée ($(grep global-v4 <<<"$O"))"
cp "$FW/global/dbt_project.yml" "$W/global-pj"; echo 'on-run-start: ["select 1"]' >> "$FW/global/dbt_project.yml"
echo 'DBT_HOOKS_COMPILE_OK="global-v4 global"' >> "$FW/.devcontainer/dbt.conf"
O="$(FRUN global compile)"; has "$O" "ARGS=compile" && has "$O" "allowed for global " && ! has "$O" "proof of its hooks" && pass "global/ (listé, avec hook) : compile accepté comme avant, sans sceau — la v4 seule en a un" || bad "global sous preuve v4 périmée ($O)"
O="$(FRUN global check)"; has "$O" "hooks nobody has reviewed" && ! has "$O" "ARGS=" && pass "…global/ check (listé, avec hook) : refusé (check compte comme commande à hooks)" || bad "global check ($O)"
O="$(FRUN global compile --vars '{"edr_cli_run": true}')"; has "$O" 'ARGS=compile --vars {"edr_cli_run": true}' && pass "…global/ compile --vars (comparer-prod.sh) : accepté comme avant" || bad "global compile --vars ($O)"
cp "$W/global-pj" "$FW/global/dbt_project.yml"
sed -i '$ d' "$G/macros/m.sql"; [ "$(SEAL)" = "$S0" ] && pass "macro remise : le même sceau" || bad "sceau après remise"
echo 'DBT_HOOKS_COMPILE_OK="global-v4 v4/delta"' >> "$FW/.devcontainer/dbt.conf"
printf "{{ config(post_hook='select 1') }}\nselect 1\n" > "$FW/v4/delta/dbt/models/hooked.sql"
O="$(FRUN v4 delta compile)"; has "$O" "has no seal of its own" && ! has "$O" "ARGS=compile" && pass "v4/delta listé : refusé (une v4/<produit> n'a pas de sceau)" || bad "v4/delta listé ($O)"
rm -f "$FW/v4/delta/dbt/models/hooked.sql"
sed -i -e '/^DBT_HOOKS_COMPILE_OK=/d' -e '/^DBT_HOOKS_V4_PROOF=/d' "$FW/.devcontainer/dbt.conf"
rm -rf "$FW/docs"
rm -rf "$FW/global-v4"

echo "== v4 : destinations v1 / v2 / v4 =="
printf '%s\n%s\n' '{"database":"sandbox-prj","schema":"JDOE_run","name":"m","resource_type":"model"}' '{"database":"sandbox-prj","schema":"STG","name":"s","resource_type":"model"}' > "$W/d-v1.jsonl"
printf '%s\n%s\n' '{"database":"sandbox-prj","schema":"JDOE_DELTA__RUN","name":"m","resource_type":"model"}' '{"database":"sandbox-prj","schema":"JDOE_DELTA__STG","name":"s","resource_type":"model"}' > "$W/d-v2.jsonl"
printf '%s\n%s\n' '{"database":"sandbox-prj","schema":"JDOE_V4_DELTA__JDOE_RUN","name":"m","resource_type":"model"}' '{"database":"sandbox-prj","schema":"JDOE_V4_DELTA__STG","name":"s","resource_type":"model"}' > "$W/d-v4.jsonl"
cat > "$W/stubs/dbt-cwd" <<EOF
#!/bin/bash
case "\$PWD" in */v1/*) cat "$W/d-v1.jsonl" ;; */v2/*) cat "$W/d-v2.jsonl" ;; */v4/*) cat "$W/d-v4.jsonl" ;; esac
EOF
chmod +x "$W/stubs/dbt-cwd"; cp "$W/stubs/dbt-cwd" "$DBT_V1_VENV/bin/dbt"; cp "$W/stubs/dbt-cwd" "$DBT_BIN_DIR/dbt"
O="$(FRUN destinations delta)"
has "$O" "[delta] v1 vs v2: 0 node(s) written elsewhere" && pass "destinations delta : v1 vs v2 inchangé" || bad "v1 vs v2 ($O)"
has "$O" "[delta] v2 vs v4: 0 node(s) written elsewhere" && pass "…v2 vs v4 : préfixe de la v4 et double préfixe (…__JDOE_RUN) ignorés" || bad "v2 vs v4 ($O)"
has "$O" "[delta] v4: every node in the v4 space" && pass "…tout nœud de la v4 dans son espace" || bad "espace v4 ($O)"
printf '%s\n' '{"database":"sandbox-prj","schema":"JDOE_V4_DELTA__AUTRE","name":"s","resource_type":"model"}' '{"database":"sandbox-prj","schema":"JDOE_DELTA__RUN","name":"m","resource_type":"model"}' > "$W/d-v4.jsonl"
O="$(FRUN destinations delta)"
has "$O" "v2 vs v4: 1 node(s) written elsewhere" && pass "…un nœud déplacé par la v4 est signalé" || bad "déplacement v4 ($O)"
has "$O" "1 node(s) OUTSIDE the v4 space" && pass "…un nœud de la v4 hors de son espace aussi" || bad "hors espace v4 ($O)"
O="$(FRUN destinations rho)"; has "$O" "[rho] v4: 2 node(s)" && ! has "$O" " vs " && pass "destinations rho : la v4 seule, sans comparaison" || bad "destinations rho ($O)"
cp "$STUB_DBT" "$DBT_V1_VENV/bin/dbt"; cp "$STUB_DBT" "$DBT_BIN_DIR/dbt"

echo "== v4 : sync, verrou, liste, doctor =="
O="$(SYNC delta)"; has "$O" "delta/v4: up to date with home-delta/v4" && pass "sync delta : la v4 suivie comme v1/v2" || bad "sync v4 ($O)"
grep -q "not followed here: v3\$" <<<"$O" && pass "…v4 n'est plus « non suivie », v3 l'est toujours" || bad "NOTE branches ($O)"
O="$(SYNC rho)"; has "$O" "rho/v4: up to date with home-rho/v4" && pass "sync rho : à jour de son dépôt" || bad "sync rho ($O)"
O="$(LK lock)"; has "$O" "products.lock written" && has "$O" "alpha v4: not opened yet" && pass "just lock : écrit, la v4 non ouverte dite (rien à verrouiller)" || bad "lock v4 ($O)"
grep -qE "^delta +v4 +$(git -C "$FW" rev-parse delta/v4)  $W/homes/delta.git#v4$" "$LOCKF" && pass "…ligne delta v4 (commit exact, dépôt#v4)" || bad "lock delta v4"
grep -qE "^rho +v4 +$(git -C "$FW" rev-parse rho/v4)  $W/homes/rho.git#v4$" "$LOCKF" && pass "…ligne rho v4" || bad "lock rho v4"
refute "…aucune ligne v4 pour alpha" grep -qE '^alpha +v4 ' "$LOCKF"
O="$(LK lock-status)"; has "$O" "v4/delta/" && has "$O" "v4/rho/" && pass "lock-status : v4/delta/ et v4/rho/ suivies" || bad "lock-status v4 ($O)"
grep -qE "v4/alpha/ +not opened yet" <<<"$O" && pass "…v4/alpha/ : « not opened yet »" || bad "lock-status v4 non ouverte ($O)"
O="$(FRUN destinations alpha; echo "rc=$?")"; has "$O" "[alpha] v4: not opened yet" && has "$O" "[alpha] v1 vs v2" && pass "destinations alpha : v4 non ouverte dite, v1 vs v2 comme avant" || bad "destinations v4 non ouverte ($O)"
O="$(LK products)"; grep -qE '^rho +no +born here +v4=' <<<"$O" && grep -qE '^delta .* v4=' <<<"$O" && pass "just products : rho « born here », delta avec sa v4" || bad "products ($O)"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"
has "$O" "[v4 space" && has "$O" "✅ write guard v4" && has "$O" "✅ profiles/v4.env = profiles/dbt.env" && pass "doctor : section de l'espace v4 au vert" || bad "doctor v4 ($(grep -A8 'v4 space' <<<"$O"))"
has "$O" "✅ v4/delta/: .env -> profiles/v4.env" && has "$O" "rho: a referent, born here" && pass "doctor : .env de la v4, référent né ici" || bad "doctor v4 détails"
has "$O" "v4/alpha/: v4 not opened yet" && ! grep -q "❌ v4/alpha" <<<"$O" && pass "doctor : v4 non ouverte = information, pas une panne" || bad "doctor v4 non ouverte ($(grep alpha <<<"$O"))"
git -C "$FW" push -q origin "origin/alpha/v2:refs/heads/alpha/v4" 2>/dev/null
O="$(life "$FW" start)"
check "alpha publiée (dépôt origin) : v4/alpha/ suit origin/alpha/v4" test "$(git -C "$FW" rev-parse --abbrev-ref 'alpha/v4@{upstream}' 2>/dev/null)" = origin/alpha/v4
check "…verrous de push toujours inchangés" test "$(git config --global --get-all url.DISABLED://.pushInsteadOf | sort)" = "$LOCKS_BEFORE"
git config --global --unset-all url."file://$W/gh/".insteadOf

echo "== flux : la déclaration (.devcontainer/flux.conf), lue du fichier seul =="
# un flux = une copie de travail de la flotte dont la v4 écrit sous JDOE_V4_<FLUX>. Ici FW joue tour à tour la copie
# principale (ASMAIN : DBT_V4_MAIN_WS = FW) et une copie de flux (ASFLUX : DBT_V4_MAIN_WS = MAINW, une copie principale
# réduite à son dbt.conf, aux mêmes réglages partagés) ; les témoins à deux copies réelles viennent plus bas.
FLUXF="$FW/.devcontainer/flux.conf"
FLUX() { printf '%b' "$1" > "$FLUXF"; }
NOFLUX() { chmod -R u+rwx "$FLUXF" 2>/dev/null; rm -rf "$FLUXF"; }
MAINW="$W/copie-principale"; mkdir -p "$MAINW/.devcontainer"
SETMAIN() { sed -i '/^DBT_V4_MAIN_WS=/d' "$FW/.devcontainer/dbt.conf"; echo "DBT_V4_MAIN_WS=\"$1\"" >> "$FW/.devcontainer/dbt.conf"; }
ASMAIN() { SETMAIN "$FW"; }
ASFLUX() { SETMAIN "$MAINW"; cp "$FW/.devcontainer/dbt.conf" "$MAINW/.devcontainer/dbt.conf"; }
LIBF() { ( cd "$FW" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && "$@"' _ "$@" ) 2>&1; }
cp "$FW/.gitignore" "$W/gitignore-avant-flux"
printf '/.devcontainer/flux.conf\n/profiles/v4-*.env\n' >> "$FW/.gitignore"
ASMAIN
[ "$(LIBF dbt_v4_prefix)" = JDOE_V4 ] && [ "$(LIBF dbt_v4_env_file)" = "$FW/profiles/v4.env" ] && [ "$(LIBF dbt_v4_role)" = main ] \
  && pass "sans flux.conf, copie nommée par DBT_V4_MAIN_WS : la copie principale, l'espace v4 principal (JDOE_V4, profiles/v4.env)" || bad "sans flux ($(LIBF dbt_v4_prefix) $(LIBF dbt_v4_role))"
O="$(DBT_V4_FLUX=D006 FRUN v4 delta parse)"; grep -q 'PFX=JDOE_V4$' <<<"$O" && pass "DBT_V4_FLUX exporté par le shell : ignoré (le fichier seul déclare un flux)" || bad "flux pris de l'environnement ($O)"
ASFLUX
FLUX '# flux de D005\n\nDBT_V4_FLUX=D005\n'
[ "$(LIBF dbt_v4_prefix)" = JDOE_V4_D005 ] && [ "$(LIBF dbt_v4_env_file)" = "$FW/profiles/v4-D005.env" ] && [ "$(LIBF dbt_v4_role)" = flux ] \
  && pass "flux.conf (commentaire, ligne vide, DBT_V4_FLUX=D005) : JDOE_V4_D005, profiles/v4-D005.env" || bad "flux D005 ($(LIBF dbt_v4_prefix))"
O="$(DBT_V4_FLUX=D006 LIBF dbt_v4_prefix)"; [ "$O" = JDOE_V4_D005 ] && pass "…et un DBT_V4_FLUX exporté ne le change pas" || bad "flux exporté l'emporte ($O)"
FLUX 'DBT_V4_FLUX=D005'
[ "$(LIBF dbt_v4_prefix)" = JDOE_V4_D005 ] && pass "…la dernière ligne compte, même sans fin de ligne" || bad "dernière ligne sans LF ignorée ($(LIBF dbt_v4_prefix))"
FLUX '# x \0377 y\nDBT_V4_FLUX=D005\n'
[ "$(LC_ALL=C.UTF-8 LIBF dbt_v4_prefix)" = JDOE_V4_D005 ] && [ "$(LC_ALL=C LIBF dbt_v4_prefix)" = JDOE_V4_D005 ] \
  && pass "…un octet non UTF-8 dans un commentaire : accepté sous C.UTF-8 comme sous C (lu octet par octet, comme le miroir Python)" || bad "commentaire non UTF-8 selon la locale ($(LC_ALL=C.UTF-8 LIBF dbt_v4_prefix))"
# refusenv NOM CONTENU — une déclaration à laquelle on ne peut pas se fier : toute commande dbt refusée, v2 comprise
refusenv() {
  FLUX "$2"
  O="$(FRUN v2 delta parse)"; local O4; O4="$(LC_ALL=C.UTF-8 FRUN v4 delta parse)"
  if has "$O" "cannot be trusted" && ! has "$O" "ARGS=" && has "$O4" "cannot be trusted" && ! has "$O4" "ARGS="; then
    pass "flux.conf refusé ($1) : toute commande dbt refusée, v2 comprise"
  else bad "flux.conf accepté : $1 ($O | $O4)"; fi
}
refusenv "minuscule d005"            'DBT_V4_FLUX=d005\n'
refusenv "nom d'un paquet (DWH)"     'DBT_V4_FLUX=DWH\n'
refusenv "DWH_REF"                   'DBT_V4_FLUX=DWH_REF\n'
refusenv "deux chiffres"             'DBT_V4_FLUX=D05\n'
refusenv "quatre chiffres"           'DBT_V4_FLUX=D0050\n'
refusenv "lettre accentuée"          'DBT_V4_FLUX=É005\n'
refusenv "entre guillemets"          'DBT_V4_FLUX="D005"\n'
refusenv "export"                    'export DBT_V4_FLUX=D005\n'
refusenv "espace en tête"            ' DBT_V4_FLUX=D005\n'
refusenv "commentaire en fin"        'DBT_V4_FLUX=D005 # x\n'
refusenv "CRLF"                      'DBT_V4_FLUX=D005\r\n'
refusenv "deux déclarations"         'DBT_V4_FLUX=D005\nDBT_V4_FLUX=D006\n'
refusenv "deux déclarations, la dernière sans fin de ligne" 'DBT_V4_FLUX=D005\nDBT_V4_FLUX=D006'
refusenv "la même deux fois"         'DBT_V4_FLUX=D005\nDBT_V4_FLUX=D005\n'
refusenv "une autre variable"        'DBT_V4_FLUX=D005\nDATASET_PREFIX=JDOE_V4\n'
refusenv "fichier vide"              ''
refusenv "commentaires seuls"        '# rien\n'
refusenv "un octet NUL dans un commentaire" '# x \0000 y\nDBT_V4_FLUX=D005\n'
refusenv "une ligne d'espace cadratin U+2003 (une espace sous C.UTF-8, pas sous C)" 'DBT_V4_FLUX=D005\n\0342\0200\0203\n'
if [ "$(id -u)" != 0 ]; then
  FLUX 'DBT_V4_FLUX=D005\n'; chmod 000 "$FLUXF"
  O="$(FRUN v4 delta parse)"; has "$O" "cannot be trusted" && ! has "$O" "ARGS=" && pass "flux.conf refusé (illisible)" || bad "flux.conf illisible ($O)"
  chmod 644 "$FLUXF"
fi
FLUX 'DBT_V4_FLUX=D005\n'; mv "$FLUXF" "$W/flux-cible.conf"; ln -s "$W/flux-cible.conf" "$FLUXF"
O="$(FRUN v4 delta parse)"; has "$O" "cannot be trusted" && ! has "$O" "ARGS=" && pass "flux.conf refusé (un lien, même vers une déclaration valide)" || bad "flux.conf lien ($O)"
NOFLUX; ln -s "$W/nulle-part.conf" "$FLUXF"
O="$(FRUN v4 delta parse)"; has "$O" "cannot be trusted" && ! has "$O" "ARGS=" && pass "flux.conf refusé (un lien pendant : jamais lu comme « pas de flux »)" || bad "flux.conf lien pendant ($O)"
ASMAIN; O="$(STUB_LS_FILE="$W/ls-v4ok.jsonl" FRUN v4 delta run -s a)"; has "$O" "cannot be trusted" && ! has "$O" "ARGS=" && pass "…ni dans la copie principale (pas de repli sur l'espace principal)" || bad "lien pendant dans la copie principale ($O)"
ASFLUX
NOFLUX; mkdir "$FLUXF"
O="$(FRUN v4 delta parse)"; has "$O" "cannot be trusted" && pass "flux.conf refusé (un dossier)" || bad "flux.conf dossier ($O)"
NOFLUX
# dbt.conf (committé, partagé par toutes les copies) ne règle rien du flux
# confflux LIGNE [VAR=VALEUR exportée par le shell]
confflux() { local L="$1" E="${2:-}"
  cp "$FW/.devcontainer/dbt.conf" "$W/dbtconf-flux"; echo "$L" >> "$FW/.devcontainer/dbt.conf"
  O="$( [ -z "$E" ] || export "${E?}"; FRUN v4 delta parse)"
  has "$O" "set in .devcontainer/dbt.conf" && ! has "$O" "ARGS=" && pass "dbt.conf qui pose $L${E:+ (et $E exporté)} : refusé, jamais un flux" || bad "dbt.conf $L ($O)"
  cp "$W/dbtconf-flux" "$FW/.devcontainer/dbt.conf"; }
confflux 'DBT_V4_FLUX="D005"'
confflux 'DBT_V4_FLUX="D005"' DBT_V4_FLUX=D005
confflux "DBT_V4_FLUX_FILE=\"$W/flux-cible.conf\""
confflux "DBT_V4_FLUX_RE='.*'"
confflux "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=(.*)\$'"
confflux "_DBT_FLUX_BLANK_RE='.*'"
echo 'DBT_V4_FLUX="D005"' >> "$FW/.devcontainer/dbt.conf"
[ "$(LIBF dbt_v4_prefix)" = JDOE_V4 ] && pass "…et le flux qu'il poserait n'est le flux de personne (préfixe JDOE_V4, toutes les commandes refusées)" || bad "flux de dbt.conf retenu ($(LIBF dbt_v4_prefix))"
sed -i '/^DBT_V4_FLUX=/d' "$FW/.devcontainer/dbt.conf"
FLUX 'DBT_V4_FLUX=D005\n'
cp "$W/gitignore-avant-flux" "$FW/.gitignore"
O="$(FRUN v4 delta parse)"; has "$O" ".devcontainer/flux.conf is not ignored by git" && ! has "$O" "ARGS=" && pass "flux.conf non ignoré par git : refusé (git add -A le committerait)" || bad "flux non ignoré ($O)"
O="$(life "$FW" start)"; has "$O" "WARNING: flux D005 — .devcontainer/flux.conf is not ignored by git" && pass "…et just setup le dit" || bad "setup muet sur un flux non ignoré ($(grep -i flux <<<"$O" | head -3))"
printf '/.devcontainer/flux.conf\n' >> "$FW/.gitignore"
O="$(FRUN v4 delta parse)"; has "$O" "profiles/v4-D005.env is not ignored by git" && pass "…profiles/v4-D005.env non ignoré : refusé aussi" || bad "env du flux non ignoré ($O)"
printf '/profiles/v4-*.env\n' >> "$FW/.gitignore"
git -C "$FW" add -f .devcontainer/flux.conf
O="$(FRUN v4 delta parse)"; has "$O" ".devcontainer/flux.conf is tracked by git" && ! has "$O" "ARGS=" && pass "flux.conf suivi par git (git add -f) : refusé" || bad "flux suivi ($O)"
O="$(life "$FW" start)"; has "$O" "WARNING: flux D005 — .devcontainer/flux.conf is tracked by git" && pass "…et just setup le dit" || bad "setup muet sur un flux suivi"
git -C "$FW" rm -q --cached .devcontainer/flux.conf
O="$(FLUX 'DBT_V4_FLUX=d005\n'; FRUN destinations delta)"; has "$O" "cannot be trusted" && ! has "$O" "== " && pass "déclaration refusée : just destinations refusé aussi" || bad "destinations sous une déclaration refusée ($O)"
O="$(FLUX 'DBT_V4_FLUX=d005\n'; FRUN hooks-approve)"; has "$O" "cannot be trusted" && ! has "$O" "approved —" && pass "déclaration refusée : just hooks-approve refusé aussi" || bad "hooks-approve sous une déclaration refusée ($O)"
FLUX 'DBT_V4_FLUX=D005\n'
printf 'DBT_V4_FLUX=D005\n' > "$WS/.devcontainer/flux.conf"
O="$(RUN v2 parse)"; has "$O" "a flux exists in a fleet only" && ! has "$O" "ARGS=" && pass "flux.conf dans un projet seul (pas de flotte) : refusé" || bad "flux hors flotte ($O)"
O="$( (cd "$WS" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "❌ .devcontainer/flux.conf in a single-product workspace" && pass "…et doctor le dit" || bad "doctor flux hors flotte ($(grep -A2 '\[flux' <<<"$O"))"
rm -f "$WS/.devcontainer/flux.conf"

echo "== flux : la copie principale est nommée (DBT_V4_MAIN_WS), jamais devinée de l'absence d'un fichier =="
ASMAIN; FLUX 'DBT_V4_FLUX=D005\n'
O="$(FRUN v4 delta parse)"; has "$O" "in the MAIN copy" && ! has "$O" "ARGS=" && pass "flux.conf dans la copie principale : refusé (la copie principale n'est jamais un flux)" || bad "flux dans la copie principale ($O)"
NOFLUX
# orphan NOM — FW n'est ni la copie principale ni un flux : aucune commande v4, v1/v2/global en lecture seulement
orphan() {
  [ "$(LIBF dbt_v4_role)" = orphan ] || { bad "orpheline ($1) : rôle $(LIBF dbt_v4_role)"; return; }
  local O1 O2 O3 O4 O5
  O1="$(FRUN v4 delta parse)"; O2="$(FRUN global-v4 parse)"; O3="$(STUB_LS_FILE="$W/ls-v2ok.jsonl" FRUN v2 delta run -s a)"
  O4="$(FRUN v2 delta parse)"; O5="$(FRUN destinations delta)"
  if has "$O1" "orphan copy" && ! has "$O1" "ARGS=" && has "$O2" "orphan copy" && ! has "$O2" "ARGS=" \
     && has "$O3" "orphan copy" && ! has "$O3" "ARGS=" && has "$O4" "ARGS=parse" && has "$O5" "orphan copy"; then
    pass "copie orpheline ($1) : v4 et global-v4 refusés, v2 run refusé, destinations refusé ; v2 parse accepté"
  else bad "copie orpheline ($1) : $O1 | $O2 | $O3 | $O4 | $O5"; fi
}
SETMAIN "";           orphan "DBT_V4_MAIN_WS vide"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "❌ ORPHAN copy — DBT_V4_MAIN_WS is empty" && pass "…doctor : copie orpheline, dite" || bad "doctor orpheline ($(grep -i orphan <<<"$O" | head -2))"
O="$(FRUN hooks-approve)"; has "$O" "orphan copy" && pass "…hooks-approve refusé" || bad "hooks-approve orpheline ($O)"
SETMAIN ".";          orphan "DBT_V4_MAIN_WS relatif (« . », qui se résoudrait en FW depuis FW)"
SETMAIN "$W/ailleurs"; orphan "DBT_V4_MAIN_WS vers un dossier absent"
SETMAIN "$MAINW";     orphan "DBT_V4_MAIN_WS vers une autre copie, et pas de flux.conf"
ln -sfn "$FW" "$W/lien-fleet"; SETMAIN "$W/lien-fleet"; life "$FW" start >/dev/null
O="$(FRUN v4 delta parse)"; grep -q 'PFX=JDOE_V4$' <<<"$O" && pass "DBT_V4_MAIN_WS par un lien vers FW : la copie principale (chemin réel)" || bad "DBT_V4_MAIN_WS par un lien ($O)"
SETMAIN "$FW/"; [ "$(LIBF dbt_v4_role)" = main ] && pass "DBT_V4_MAIN_WS avec une barre finale : la copie principale" || bad "DBT_V4_MAIN_WS barre finale"
rm -f "$W/lien-fleet"; ASFLUX; FLUX 'DBT_V4_FLUX=D005\n'
SETMAIN ""; O="$(FRUN v4 delta parse)"; has "$O" "names no main copy by an absolute path" && ! has "$O" "ARGS=" && pass "un flux sans copie principale nommée (DBT_V4_MAIN_WS vide) : toute commande refusée" || bad "flux sans DBT_V4_MAIN_WS ($O)"
ASFLUX

echo "== flux : just setup — profiles/v4-<FLUX>.env, les .env de la v4 et de global-v4 =="
mkdir -p "$FW/global-v4"; printf 'name: fleet_global_v4\nprofile: "prof_global"\n' > "$FW/global-v4/dbt_project.yml"
SUM4="$(sha256sum < "$FW/profiles/v4.env")"
O="$(life "$FW" start)"
check "profiles/v4-D005.env : DATASET_PREFIX=JDOE_V4_D005" grep -qx 'DATASET_PREFIX=JDOE_V4_D005' "$FW/profiles/v4-D005.env"
check "…et sinon profiles/dbt.env à l'identique (généré)" diff <(tail -n +3 "$FW/profiles/v4-D005.env") <(sed 's/^DATASET_PREFIX=.*/DATASET_PREFIX=JDOE_V4_D005/' "$FW/profiles/dbt.env")
[ "$(sha256sum < "$FW/profiles/v4.env")" = "$SUM4" ] && pass "…profiles/v4.env (l'espace principal, committé) inchangé" || bad "v4.env réécrit dans un flux"
for P in v4/delta/dbt v4/rho/dbt global-v4; do
  check ".env de $P -> profiles/v4-D005.env" test "$(readlink -f "$FW/$P/.env")" = "$(readlink -f "$FW/profiles/v4-D005.env")"
done
check ".env de v2/delta : toujours profiles/dbt.env" test "$(readlink -f "$FW/v2/delta/dbt/.env")" = "$(readlink -f "$FW/profiles/dbt.env")"
check "réglages de la fenêtre v4/delta : envFile du flux" python3 -c "import json; d=json.load(open('$FW/v4/delta/.vscode/settings.json')); assert d['python.envFile'].endswith('profiles/v4-D005.env')"
check "git ne voit ni flux.conf ni profiles/v4-D005.env (ignorés)" test -z "$(git -C "$FW" status --porcelain --ignored=no -- .devcontainer/flux.conf profiles/v4-D005.env)"
has "$O" "the container (engines, ~/.bashrc, global git settings) is the main copy's" && has "$O" "bashrc (\`dbt\`, DBT_PROFILES_DIR) is the main copy's" \
  && pass "…et l'état du container (moteurs, ~/.bashrc, git global) laissé à la copie principale, dit" || bad "setup d'un flux et l'état du container ($(grep -iE 'container|bashrc' <<<"$O" | head -3))"

echo "== flux : le garde-fou — la v4 et global-v4 sous JDOE_V4_D005 seulement, rien ailleurs =="
O="$(FRUN v4 delta parse)"; grep -q 'PFX=JDOE_V4_D005$' <<<"$O" && pass "just v4 delta → DATASET_PREFIX=JDOE_V4_D005" || bad "v4 delta dans le flux ($O)"
O="$(FRUN global-v4 parse)"; grep -q 'PFX=JDOE_V4_D005$' <<<"$O" && pass "just global-v4 → DATASET_PREFIX=JDOE_V4_D005" || bad "global-v4 dans le flux ($O)"
O="$(CWD="$FW/v4/delta/dbt" FRUN auto parse)"; grep -q 'PFX=JDOE_V4_D005$' <<<"$O" && pass "\`dbt\` dans v4/delta/ du flux → même espace" || bad "auto v4 flux ($O)"
O="$(DATASET_PREFIX=JDOE_V4 FRUN v4 delta parse)"; grep -q 'PFX=JDOE_V4_D005$' <<<"$O" && pass "…même avec DATASET_PREFIX=JDOE_V4 exporté par le shell" || bad "préfixe exporté dans le flux ($O)"
for X in JDOE_V4_D005_DELTA__X JDOE_V4_D005 JDOE_V4_D005_delta__x; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"; has "$O" "all inside the sandbox" && has "$O" "ARGS=run -s a" && pass "flux : écriture v4 sous $X acceptée" || bad "flux : $X refusé ($O)"
done
for X in JDOE_V4_DELTA__X JDOE_V4 JDOE_V4_D006_DELTA__X JDOE_V4_D006 JDOE_V4_D005X JDOE_V4_D0050_X JDOE_DELTA__X JDOE_V4_d005_delta__x jdoe_v4_D005_X JDOE_V4_d005; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"
  has "$O" "outside the sandbox" && has "$O" "flux D005" && ! has "$O" "ARGS=" && pass "flux : écriture v4 sous $X refusée (l'espace principal, un autre flux, une borne, la v2, une autre casse)" || bad "flux : $X accepté ($O)"
done
FJ JDOE_V4_DELTA__X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN global-v4 run -s a)"; has "$O" "outside the sandbox" && ! has "$O" "ARGS=" && pass "flux : global-v4 sous l'espace principal refusé" || bad "global-v4 flux vers principal ($O)"
FJ JDOE_V4_D005_DELTA__X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN global-v4 run -s a)"; has "$O" "all inside the sandbox" && pass "flux : global-v4 sous JDOE_V4_D005_* accepté" || bad "global-v4 flux ($O)"
FJ JDOE_DELTA__X a > "$W/ls-f.jsonl"
# v1/v2/global dans un flux : une liste blanche (parse, ls, list, compile, show, deps), jamais une liste noire
for C in "v2 delta run -s a" "v1 delta run -s a" "global run -s a" "v2 delta seed -s a" "v2 delta test" "v2 delta docs generate" \
         "v2 delta run-operation m" "v2 delta source freshness" "v2 delta check" "global check" "v2 delta build -s a" "v2 delta snapshot" \
         "v2 delta clone -s a" "v2 delta retry" "global build -s a" "v2 delta debug" "v2 delta clean" "v2 delta --log-level debug run -s a" \
         "v2 delta compile -s run" "v2 delta" "global --quiet build -s a" "v1 delta test" "v1 delta check" "v2 delta frobnicate"; do
  # shellcheck disable=SC2086
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" DBT_ALLOW_RUN_OPERATION=1 FRUN $C)"
  has "$O" "a flux writes only its v4 space" && ! has "$O" "ARGS=" && pass "flux : \`$C\` refusé (v1/v2/global : liste blanche)" || bad "flux : $C accepté ($O)"
done
for C in "v2 delta parse" "v2 delta compile" "v1 delta parse" "global parse" "v2 delta list" "v2 delta deps" "v2 delta show -s a" "v2 delta --quiet parse"; do
  # shellcheck disable=SC2086
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN $C)"; ! has "$O" "⛔" && { has "$O" "ARGS=" || has "$O" "JDOE_DELTA__X"; } && pass "flux : \`$C\` accepté (lecture)" || bad "flux : $C refusé ($O)"
done
O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v2 delta ls)"; has "$O" "JDOE_DELTA__X" && ! has "$O" "⛔" && pass "flux : \`v2 delta ls\` accepté (lecture)" || bad "flux : v2 ls refusé ($O)"
O="$(FRUN v2 delta "compile show")"; has "$O" "a flux writes only its v4 space" && ! has "$O" "ARGS=" && pass "flux : un premier mot « compile show » (une espace) n'est pas une commande de la liste : refusé" || bad "flux : premier mot avec une espace ($O)"
printf 'DATASET_PREFIX=JDOE_V4\n' > "$FW/profiles/env/delta.env"
O="$(FRUN v4 delta parse)"; has "$O" "the v4 space is JDOE_V4_D005" && pass "flux : fichier d'env du produit qui repose JDOE_V4 → refusé" || bad "env produit dans le flux ($O)"
rm -f "$FW/profiles/env/delta.env"
ln -sfn ../../../profiles/v4.env "$FW/v4/delta/dbt/.env"
O="$(FRUN v4 delta parse)"; has "$O" "does not point to profiles/v4-D005.env" && pass "flux : .env de v4/delta vers profiles/v4.env (l'espace principal) → refusé" || bad ".env v4 principal dans le flux ($O)"
ln -sfn ../../../profiles/v4-D005.env "$FW/v4/delta/dbt/.env"
ln -sfn ../../../profiles/v4-D005.env "$FW/v2/delta/dbt/.env"
O="$(FRUN v2 delta parse)"; has "$O" "points to profiles/v4-D005.env" && pass "flux : .env de v2/delta vers profiles/v4-D005.env → refusé" || bad ".env v2 vers le flux ($O)"
ln -sfn ../../../profiles/dbt.env "$FW/v2/delta/dbt/.env"
cp "$FW/profiles/v4-D005.env" "$W/v4-D005.env"; sed -i 's/^DATASET_PREFIX=.*/DATASET_PREFIX=JDOE_V4/' "$FW/profiles/v4-D005.env"
O="$(FRUN v4 delta parse)"; has "$O" "the v4 space is JDOE_V4_D005" && pass "flux : profiles/v4-D005.env retouché (JDOE_V4) → refusé" || bad "env du flux retouché ($O)"
rm -f "$FW/profiles/v4-D005.env"
O="$(FRUN v4 delta parse)"; has "$O" "profiles/v4-D005.env is missing" && pass "flux : profiles/v4-D005.env absent → refusé" || bad "env du flux absent ($O)"
cp "$W/v4-D005.env" "$FW/profiles/v4-D005.env"
O="$(FRUN hooks-approve)"; has "$O" "approve them there, never from a flux" && pass "flux : hooks-approve refusé (la liste approuvée est celle de la copie principale)" || bad "hooks-approve dans un flux ($O)"
# le flux et sa copie principale partagent le bac à sable, les préfixes et les moteurs (lus dans le dbt.conf de la principale)
mainconf() { local V="$1" X="$2"
  cp "$MAINW/.devcontainer/dbt.conf" "$W/main-dbtconf"
  sed -i "/^$V=/d" "$MAINW/.devcontainer/dbt.conf"; echo "$V=\"$X\"" >> "$MAINW/.devcontainer/dbt.conf"
  O="$(FRUN v4 delta parse)"
  has "$O" "$V differs from the main copy's" && ! has "$O" "ARGS=" && pass "flux : $V autre que celui de la copie principale ($X) → toute commande refusée" || bad "flux : $V différent ($O)"
  cp "$W/main-dbtconf" "$MAINW/.devcontainer/dbt.conf"; }
mainconf DBT_BQ_PROJECT autre-prj
mainconf DBT_BQ_DATASET_PREFIX JDOEX
mainconf DBT_BQ_DATASET_PREFIX_V4 JDOE_W4
mainconf DBT_V1_PINS "dbt-core==1.10.9 dbt-bigquery==1.10.9"
mainconf DBT_V2_VERSION 2.0.8
mainconf DBT_V4_MAIN_WS "$W/autre"
mv "$MAINW/.devcontainer/dbt.conf" "$W/main-dbtconf"
O="$(FRUN v4 delta parse)"; has "$O" "has no .devcontainer/dbt.conf" && ! has "$O" "ARGS=" && pass "flux : la copie principale absente (pas de dbt.conf) → toute commande refusée" || bad "flux sans copie principale ($O)"
mv "$W/main-dbtconf" "$MAINW/.devcontainer/dbt.conf"

echo "== flux : les réglages du garde-fou (verrou 3) au moins aussi stricts que ceux de la copie principale =="
# un flux qui vit longtemps (la ligne harmonisée) peut retarder sur sa copie principale : plus strict passe, plus
# permissif refuse toute commande dbt — ex. une table que la copie principale a ajoutée depuis à DBT_SANDBOX_NEVER_BUILD
# strict VAR PRINCIPAL FLUX refus|accepte — VAR vaut PRINCIPAL dans le dbt.conf de la copie principale (« - » : absent),
# FLUX dans celui du flux
strict() { local V="$1" M="$2" F="$3" E="$4" O
  cp "$FW/.devcontainer/dbt.conf" "$W/strict-fw"; cp "$MAINW/.devcontainer/dbt.conf" "$W/strict-main"
  sed -i "/^$V=/d" "$FW/.devcontainer/dbt.conf" "$MAINW/.devcontainer/dbt.conf"
  [ "$M" = - ] || echo "$V=\"$M\"" >> "$MAINW/.devcontainer/dbt.conf"
  echo "$V=\"$F\"" >> "$FW/.devcontainer/dbt.conf"
  O="$(FRUN v4 delta parse)"
  if [ "$E" = refus ]; then
    has "$O" "cannot be trusted" && has "$O" "$V" && ! has "$O" "ARGS=" \
      && pass "flux : $V « $F », copie principale « $M » — plus permissif : toute commande refusée" || bad "flux : $V « $F » / « $M » accepté ($O)"
  else
    grep -q 'PFX=JDOE_V4_D005$' <<<"$O" && pass "flux : $V « $F », copie principale « $M » — aussi strict, ou plus : accepté" || bad "flux : $V « $F » / « $M » refusé ($O)"
  fi
  cp "$W/strict-fw" "$FW/.devcontainer/dbt.conf"; cp "$W/strict-main" "$MAINW/.devcontainer/dbt.conf"; }
strict DBT_SANDBOX_NEVER_BUILD "delta.a" "" refus
strict DBT_SANDBOX_NEVER_BUILD "delta.a delta.b" "delta.b" refus
strict DBT_SANDBOX_NEVER_BUILD "delta.a" "delta.b delta.a" accepte
strict DBT_SANDBOX_NEVER_BUILD "" "delta.a" accepte
strict DBT_HOOKS_COMPILE_OK "" "global-v4" refus
strict DBT_HOOKS_COMPILE_OK - "global-v4" refus
strict DBT_HOOKS_COMPILE_OK "global-v4" "global-v4 v4/delta" refus
strict DBT_HOOKS_COMPILE_OK "global-v4 delta" "global-v4" accepte
strict DBT_HOOKS_COMPILE_OK "global-v4" "" accepte
for V in DBT_HOOKS_REVIEWED DBT_HOOKS_REVIEWED_V2 DBT_ALLOW_RUN_OPERATION; do
  strict "$V" 0 1 refus; strict "$V" - 1 refus; strict "$V" 1 0 accepte; strict "$V" 1 1 accepte
done
cp "$MAINW/.devcontainer/dbt.conf" "$W/strict-main"; echo 'DBT_SANDBOX_NEVER_BUILD="delta.a"' >> "$MAINW/.devcontainer/dbt.conf"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"
has "$O" "❌ flux D005: DBT_SANDBOX_NEVER_BUILD here lacks what the main copy's names ($MAINW: delta.a)" && pass "…et doctor le dit (la table que la copie principale ne construit jamais)" || bad "doctor : réglage plus permissif ($(grep -i 'NEVER_BUILD' <<<"$O"))"
O="$(STUB_LS_FILE="$W/ls-v4ok.jsonl" FRUN v4 delta build -s a)"; has "$O" "cannot be trusted" && ! has "$O" "ARGS=" && pass "…\`v4 delta build -s a\` refusé avant toute résolution" || bad "build sous un réglage plus permissif ($O)"
cp "$W/strict-main" "$MAINW/.devcontainer/dbt.conf"

echo "== flux : aucun hook dans les espaces de la copie principale (v1/v2/global), quoi qu'approuve dbt.conf =="
# dbt v2 exécute les on-run-start au compile et au show. Dans un flux, ceux de v2/ ou de global/ écriraient l'espace de
# la copie principale (DATASET_PREFIX=JDOE) : refusés, même listés dans DBT_HOOKS_COMPILE_OK, sous DBT_HOOKS_REVIEWED_V2
# ou DBT_HOOKS_REVIEWED — les approbations de la copie principale, jamais celles d'une autre copie
printf "{{ config(post_hook='select 1') }}\nselect 1\n" > "$FW/v2/delta/dbt/models/hooked.sql"
cp "$FW/.devcontainer/dbt.conf" "$W/dbtconf-avant-hooks"
printf 'x\ty\tz\n' > "$FW/.devcontainer/hooks.approved"
printf 'DBT_HOOKS_COMPILE_OK="delta global"\nDBT_HOOKS_REVIEWED_V2=1\n' >> "$FW/.devcontainer/dbt.conf"
ASFLUX
FJ JDOE_DELTA__X a > "$W/ls-f.jsonl"
for C in "v2 delta compile" "v2 delta show -s a" "v2 delta --quiet compile -s a"; do
  # shellcheck disable=SC2086
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN $C)"
  has "$O" "flux D005: \`dbt" && has "$O" "runs no hook outside its v4 space" && has "$O" "models/hooked.sql" && has "$O" "DATASET_PREFIX=JDOE)" && ! has "$O" "ARGS=" \
    && pass "flux : \`$C\` refusé — le hook de delta écrirait l'espace de la copie principale (DBT_HOOKS_COMPILE_OK=delta, DBT_HOOKS_REVIEWED_V2=1 n'y font rien)" || bad "flux : $C sous hooks ($O)"
done
for C in "v2 delta parse" "v2 delta ls" "v2 delta deps"; do
  # shellcheck disable=SC2086
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN $C)"; ! has "$O" "⛔" && { has "$O" "ARGS=" || has "$O" "JDOE_DELTA__X"; } && pass "…\`$C\` accepté (aucun hook ne tourne)" || bad "flux : $C sous hooks refusé ($O)"
done
O="$(FRUN v2 beta compile)"; has "$O" "ARGS=compile" && ! has "$O" "⛔" && pass "flux : \`v2 beta compile\` accepté (beta ne déclare aucun hook)" || bad "flux : compile sans hook ($O)"
O="$(FRUN v1 delta compile)"; has "$O" "ARGS=compile" && pass "flux : \`v1 delta compile\` accepté (dbt Core n'exécute aucun hook au compile)" || bad "flux : v1 compile ($O)"
printf "{{ config(pre_hook='select 1') }}\nselect 1\n" > "$FW/v2/alpha/dbt/models/hooked_a.sql"
O="$(FRUN global compile)"; has "$O" "runs no hook outside its v4 space" && has "$O" "dbt_packages/alpha/models/hooked_a.sql" && ! has "$O" "ARGS=" \
  && pass "flux : \`global compile\` refusé — le hook d'un modèle d'un paquet local lié (alpha) est lu, DBT_HOOKS_COMPILE_OK=global n'y fait rien" || bad "flux : global compile sous hooks ($O)"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"
has "$O" "-> refused in this copy, which is not the main one" && has "$O" "dbt_packages/alpha/models/hooked_a.sql" && pass "doctor (flux) : les hooks de v2/delta et de global/ refusés ici, quoi qu'approuve dbt.conf" || bad "doctor : hooks d'une copie de flux ($(grep -A1 'hooks in' <<<"$O" | head -6))"
NOFLUX; ASMAIN
O="$(FRUN v2 delta compile)"; has "$O" "ARGS=compile" && has "$O" "allowed for delta (DBT_HOOKS_COMPILE_OK" && pass "copie principale : \`v2 delta compile\` accepté sous DBT_HOOKS_COMPILE_OK=delta, comme avant" || bad "principale : v2 compile ($O)"
O="$(FRUN global compile)"; has "$O" "ARGS=compile" && pass "copie principale : \`global compile\` accepté sous DBT_HOOKS_COMPILE_OK=global, comme avant" || bad "principale : global compile ($O)"
SETMAIN ""
O="$(FRUN v2 delta compile)"; has "$O" "orphan copy: \`dbt compile\` refused under v2/delta/" && ! has "$O" "ARGS=" && pass "copie orpheline : \`v2 delta compile\` refusé (hooks), même sous DBT_HOOKS_COMPILE_OK=delta" || bad "orpheline : v2 compile sous hooks ($O)"
ASFLUX; FLUX 'DBT_V4_FLUX=D005\n'
rm -f "$FW/v2/alpha/dbt/models/hooked_a.sql"
O="$(FRUN global compile)"; has "$O" "ARGS=compile" && pass "flux : sans ce hook, \`global compile\` accepté" || bad "flux : global compile sans hook ($O)"
ln -sfn ../../v2/nulle-part "$FW/global/dbt_packages/fantome"
O="$(FRUN global compile)"; has "$O" "dbt_packages/fantome (a link to no directory" && ! has "$O" "ARGS=" && pass "flux : un paquet local lié à rien : \`global compile\` refusé (ses hooks ne se lisent pas)" || bad "flux : lien pendant ($O)"
rm -f "$FW/global/dbt_packages/fantome"
mv "$FW/global/dbt_packages" "$W/global-pkgs"; mkdir "$FW/global/dbt_packages"
O="$(FRUN global compile)"; has "$O" "flux D005" && has "$O" "packages are not installed" && ! has "$O" "ARGS=" && pass "flux : paquets de global/ non installés : \`global compile\` refusé (leurs hooks ne se lisent pas)" || bad "flux : paquets non installés ($O)"
rmdir "$FW/global/dbt_packages"; mv "$W/global-pkgs" "$FW/global/dbt_packages"
printf 'DBT_HOOKS_REVIEWED=1\n' >> "$FW/.devcontainer/dbt.conf"; ASFLUX
O="$(FRUN v2 delta compile)"; has "$O" "runs no hook outside its v4 space" && ! has "$O" "ARGS=" && pass "flux : \`v2 delta compile\` refusé même sous DBT_HOOKS_REVIEWED=1" || bad "flux : REVIEWED=1 ouvre les hooks ($O)"
cp "$W/dbtconf-avant-hooks" "$FW/.devcontainer/dbt.conf"; ASFLUX
rm -f "$FW/.devcontainer/hooks.approved" "$FW/v2/delta/dbt/models/hooked.sql"

echo "== flux : un nom de flux qui se lirait comme un paquet de l'espace v4 =="
mkdir -p "$FW/global-v4/dbt_packages/d005_utils"
O="$(FRUN v4 delta parse)"; has "$O" "flux D005 reads as a package of the v4 space (d005_utils)" && ! has "$O" "ARGS=" && pass "paquet d005_utils dans global-v4 : le flux D005 est refusé" || bad "collision nom de paquet ($O)"
O="$(life "$FW" start)"; has "$O" "WARNING: flux D005 — flux D005 reads as a package" && pass "…et just setup le dit" || bad "setup muet sur un nom de paquet ($(grep -i flux <<<"$O" | head -3))"
rmdir "$FW/global-v4/dbt_packages/d005_utils"; mkdir -p "$FW/global-v4/dbt_packages/d005"
O="$(FRUN v4 delta parse)"; has "$O" "reads as a package of the v4 space (d005)" && ! has "$O" "ARGS=" && pass "paquet nommé exactement d005 : le flux D005 est refusé" || bad "paquet homonyme exact ($O)"
rmdir "$FW/global-v4/dbt_packages/d005"; mkdir -p "$FW/global-v4/dbt_packages/d0050"
O="$(FRUN v4 delta parse)"; has "$O" "PFX=JDOE_V4_D005" && pass "…d0050 ne se lit pas comme D005 (borne « _ ») : accepté" || bad "borne du nom de paquet ($O)"
rmdir "$FW/global-v4/dbt_packages/d0050"; rmdir "$FW/global-v4/dbt_packages" 2>/dev/null
life "$FW" start >/dev/null

echo "== flux : la copie principale n'écrit jamais l'espace d'un flux =="
NOFLUX; ASMAIN; life "$FW" start >/dev/null
for X in JDOE_V4_D005_DELTA__X JDOE_V4_D005 JDOE_V4_s001_x JDOE_V4_Z999 jdoe_v4_DELTA__X JDOE_v4_DELTA__X; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"
  has "$O" "outside the sandbox" && has "$O" "never a flux's" && ! has "$O" "ARGS=" && pass "principal : écriture v4 sous $X refusée (l'espace d'un flux, ou une autre casse du préfixe)" || bad "principal : $X accepté ($O)"
done
for X in JDOE_V4_DELTA__X JDOE_V4_DWH_X JDOE_V4_D05_X JDOE_V4_D0050_X JDOE_V4_DD005 JDOE_V4_delta__x; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"; has "$O" "all inside the sandbox" && pass "principal : écriture v4 sous $X acceptée (pas la forme d'un flux)" || bad "principal : $X refusé ($O)"
done
for X in JDOE_V4_D005_X jdoe_v4_x JDOE_v4; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v2 delta run -s a)"; has "$O" "never JDOE_V4" && pass "v2 sous $X : refusé (l'espace v4, flux compris, en toute casse)" || bad "v2 vers $X ($O)"
done
ASFLUX; FLUX 'DBT_V4_FLUX=D005\n'; life "$FW" start >/dev/null; NOFLUX; ASMAIN
O="$(life "$FW" start)"
check "flux retiré, la copie redevenue principale (DBT_V4_MAIN_WS), just setup : .env de v4/delta -> profiles/v4.env de nouveau" test "$(readlink -f "$FW/v4/delta/dbt/.env")" = "$(readlink -f "$FW/profiles/v4.env")"
check "…et global-v4/.env aussi" test "$(readlink -f "$FW/global-v4/.env")" = "$(readlink -f "$FW/profiles/v4.env")"
ASFLUX; FLUX 'DBT_V4_FLUX=D005\n'; life "$FW" start >/dev/null; NOFLUX
O="$(life "$FW" start)"
has "$O" "ORPHAN" && has "$O" "this copy WAS flux D005" && pass "flux.conf effacé d'une copie de flux, just setup : copie orpheline, l'ancien flux nommé — jamais la copie principale" || bad "flux effacé, setup ($(grep -iE 'orphan|flux' <<<"$O" | head -4))"
check "…plus de .env dans v4/delta (aucun espace v4 lu par l'extension)" test ! -e "$FW/v4/delta/dbt/.env" -a ! -L "$FW/v4/delta/dbt/.env"
check "…ni dans global-v4/" test ! -e "$FW/global-v4/.env" -a ! -L "$FW/global-v4/.env"
FJ JDOE_V4_DELTA__X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"; has "$O" "orphan copy" && ! has "$O" "ARGS=" && pass "…et l'écriture sous l'espace principal JDOE_V4 refusée" || bad "ex-flux vers l'espace principal ($O)"
ASMAIN; life "$FW" start >/dev/null

echo "== la ligne harmonisée : le flux H (JDOE_V4_H) — elle n'écrit que là, et la ligne ISO (la copie principale) jamais là =="
ASFLUX; FLUX 'DBT_V4_FLUX=H\n'; O="$(life "$FW" start)"
[ "$(LIBF dbt_v4_prefix)" = JDOE_V4_H ] && [ "$(LIBF dbt_v4_env_file)" = "$FW/profiles/v4-H.env" ] && [ "$(LIBF dbt_v4_role)" = flux ] \
  && grep -qx 'DATASET_PREFIX=JDOE_V4_H' "$FW/profiles/v4-H.env" && test "$(readlink -f "$FW/v4/delta/dbt/.env")" = "$(readlink -f "$FW/profiles/v4-H.env")" \
  && pass "flux.conf DBT_V4_FLUX=H, la ligne harmonisée : JDOE_V4_H, profiles/v4-H.env, le .env de v4/delta y pointe" || bad "flux H ($(LIBF dbt_v4_prefix) $(LIBF dbt_v4_role))"
has "$O" "flux H: the HARMONIZED line" && pass "…et just setup le dit" || bad "setup muet sur la ligne harmonisée ($(grep -i flux <<<"$O" | head -3))"
has "$O" "WARNING: flux H — separated from the ISO line in BigQuery only, not in git" && pass "…et qu'elle n'est séparée de la ligne ISO que dans BigQuery, pas dans git (branche v4 commune)" || bad "setup muet sur git et la ligne harmonisée ($(grep -i 'flux H' <<<"$O" | head -3))"
O="$(FRUN v4 delta parse)"; grep -q 'PFX=JDOE_V4_H$' <<<"$O" && pass "just v4 delta (ligne harmonisée) → DATASET_PREFIX=JDOE_V4_H" || bad "v4 delta sous H ($O)"
for X in JDOE_V4_H_DELTA__X JDOE_V4_H JDOE_V4_H_delta__x; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"; has "$O" "all inside the sandbox" && has "$O" "ARGS=run -s a" && pass "ligne harmonisée : écriture v4 sous $X acceptée" || bad "ligne harmonisée : $X refusé ($O)"
done
for X in JDOE_V4_DELTA__X JDOE_V4 JDOE_V4_D005_DELTA__X JDOE_V4_HR_X JDOE_V4_HDELTA__X JDOE_V4_h_delta__x jdoe_v4_H_X JDOE_DELTA__X; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"
  has "$O" "outside the sandbox" && has "$O" "flux H" && ! has "$O" "ARGS=" && pass "ligne harmonisée : écriture v4 sous $X refusée (la ligne ISO, un flux, une borne, une autre casse, la v2)" || bad "ligne harmonisée : $X accepté ($O)"
done
FJ JDOE_V4_DELTA__X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN global-v4 run -s a)"; has "$O" "outside the sandbox" && ! has "$O" "ARGS=" && pass "ligne harmonisée : global-v4 sous l'espace de la ligne ISO (JDOE_V4_*) refusé" || bad "global-v4 H vers ISO ($O)"
FJ JDOE_DELTA__X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v2 delta run -s a)"; has "$O" "a flux writes only its v4 space" && ! has "$O" "ARGS=" \
  && pass "ligne harmonisée : \`v2 delta run\` refusé (la v2 est commune aux deux lignes : la copie principale seule y écrit)" || bad "v2 run sous H ($O)"
O="$(FRUN v2 delta parse)"; has "$O" "ARGS=parse" && pass "…\`v2 delta parse\` accepté (lecture)" || bad "v2 parse sous H ($O)"
# un paquet de l'espace v4 qui se lirait comme H : refusé ; hr, non (borne « _ »)
mkdir -p "$FW/global-v4/dbt_packages/h_utils"
O="$(FRUN v4 delta parse)"; has "$O" "flux H reads as a package of the v4 space (h_utils)" && ! has "$O" "ARGS=" && pass "paquet h_utils dans global-v4 : la ligne harmonisée refusée (ses datasets seraient les siens)" || bad "collision H ($O)"
rmdir "$FW/global-v4/dbt_packages/h_utils"; mkdir -p "$FW/global-v4/dbt_packages/hr"
O="$(FRUN v4 delta parse)"; has "$O" "PFX=JDOE_V4_H" && pass "…un paquet hr ne se lit pas comme H : accepté" || bad "borne H, paquet ($O)"
rmdir "$FW/global-v4/dbt_packages/hr"; rmdir "$FW/global-v4/dbt_packages" 2>/dev/null
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"
has "$O" "✅ this copy is flux H; the main copy is $MAINW" && has "$O" "flux H is the HARMONIZED line" && has "$O" "✅ profiles/v4-H.env = profiles/dbt.env with DATASET_PREFIX=JDOE_V4_H" \
  && pass "doctor : la ligne harmonisée (flux H), sa copie principale, son environnement" || bad "doctor H ($(grep -iE 'flux|this copy' <<<"$O"))"
has "$O" "❌ flux H: the two lines are separated in BigQuery only, not in git" && has "$O" "commit and push nothing on v4 from this copy" \
  && pass "doctor : la ligne harmonisée n'est pas séparée dans git — dit comme un problème (rien à committer sur v4 d'ici)" || bad "doctor H et git ($(grep -i 'git' <<<"$O" | head -3))"
printf 'VERDICT HOOKS GLOBAL-V4 FLUX H : PREUVE OK ; TÉMOINS OK ; sceau 0123456789abcdef0123\n' > "$W/verdict-h.md"
[ "$(LIBF dbt_hooks_v4_verdict_line abc H)" = "VERDICT HOOKS GLOBAL-V4 FLUX H : PREUVE OK ; TÉMOINS OK ; sceau abc" ] \
  && LIBF dbt_hooks_v4_verdict "$W/verdict-h.md" 0123456789abcdef0123 H >/dev/null && ! LIBF dbt_hooks_v4_verdict "$W/verdict-h.md" 0123456789abcdef0123 >/dev/null \
  && ! LIBF dbt_hooks_v4_verdict "$W/verdict-h.md" 0123456789abcdef0123 D005 >/dev/null \
  && pass "verdict de la ligne harmonisée (« … FLUX H : … ») : valable pour H, ni pour la copie principale ni pour un autre flux" || bad "verdict H"
# la déclaration : H seul, en capitale
refusenv "minuscule h"                'DBT_V4_FLUX=h\n'
refusenv "H suivi d'un chiffre"       'DBT_V4_FLUX=H1\n'
refusenv "HH"                         'DBT_V4_FLUX=HH\n'
refusenv "H_"                         'DBT_V4_FLUX=H_\n'
refusenv "une autre lettre seule (G)" 'DBT_V4_FLUX=G\n'
# la ligne harmonisée effacée (git clean -X) : orpheline, jamais la ligne ISO — et elle dit qu'elle était H
FLUX 'DBT_V4_FLUX=H\n'; life "$FW" start >/dev/null; NOFLUX
[ -f "$FW/profiles/v4-D005.env" ] && mv "$FW/profiles/v4-D005.env" "$W/v4-D005.env.cote"
O="$(life "$FW" start)"
has "$O" "ORPHAN" && has "$O" "this copy WAS flux H" && pass "flux.conf effacé de la ligne harmonisée, just setup : copie orpheline, « this copy WAS flux H » — jamais la ligne ISO" || bad "ex-ligne H ($(grep -iE 'orphan|flux' <<<"$O" | head -4))"
[ -f "$W/v4-D005.env.cote" ] && mv "$W/v4-D005.env.cote" "$FW/profiles/v4-D005.env"
# la ligne ISO : la copie principale n'écrit jamais l'espace de la ligne harmonisée
ASMAIN; life "$FW" start >/dev/null
for X in JDOE_V4_H_DELTA__X JDOE_V4_H JDOE_V4_h_delta__x JDOE_V4_h; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"
  has "$O" "outside the sandbox" && has "$O" "nor the harmonized line's" && ! has "$O" "ARGS=" && pass "ligne ISO (copie principale) : écriture v4 sous $X refusée (l'espace de la ligne harmonisée, toute casse)" || bad "ligne ISO : $X accepté ($O)"
done
for X in JDOE_V4_HR_X JDOE_V4_HDELTA__X JDOE_V4_DELTA__H JDOE_V4_DELTA__H_X; do FJ "$X" a > "$W/ls-f.jsonl"
  O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v4 delta run -s a)"; has "$O" "all inside the sandbox" && pass "ligne ISO : écriture v4 sous $X acceptée (pas l'espace de la ligne harmonisée)" || bad "ligne ISO : $X refusé ($O)"
done
FJ JDOE_V4_H_X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" FRUN v2 delta run -s a)"; has "$O" "never JDOE_V4" && pass "v2 sous JDOE_V4_H_X : refusé (l'espace v4, ligne harmonisée comprise)" || bad "v2 vers H ($O)"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "and the harmonized line's, JDOE_V4_H / JDOE_V4_H_*, are never written from here" && pass "doctor : la copie principale dit qu'elle n'écrit jamais l'espace de la ligne harmonisée" || bad "doctor ISO et H ($(grep -i 'no flux' <<<"$O"))"
sed -i 's/^DBT_BQ_DATASET_PREFIX_V4=.*/DBT_BQ_DATASET_PREFIX_V4="JDOE_V4_H"/' "$FW/.devcontainer/dbt.conf"
O="$(FRUN v4 delta parse)"; has "$O" "every v4 command is refused" && pass "DBT_BQ_DATASET_PREFIX_V4='JDOE_V4_H' (l'espace de la ligne harmonisée pris pour l'espace principal) : v4 refusée" || bad "préfixe v4 JDOE_V4_H accepté ($O)"
sed -i 's/^DBT_BQ_DATASET_PREFIX_V4=.*/DBT_BQ_DATASET_PREFIX_V4="JDOE_V4"/' "$FW/.devcontainer/dbt.conf"
PFXOK JDOE_V4_HR && PFXOK JDOE_V4_HD005 && ! PFXOK JDOE_H_V4 && ! PFXOK JDOE_V4_h \
  && pass "_dbt_v4_prefix_ok : un segment H (toute casse) refusé ; HR, HD005 acceptés" || bad "_dbt_v4_prefix_ok et H"

echo "== flux : destinations dans un flux =="
printf '%s\n%s\n' '{"database":"sandbox-prj","schema":"JDOE_V4_D005_DELTA__JDOE_RUN","name":"m","resource_type":"model"}' '{"database":"sandbox-prj","schema":"JDOE_V4_D005_DELTA__STG","name":"s","resource_type":"model"}' > "$W/d-v4.jsonl"
printf '%s\n%s\n' '{"database":"sandbox-prj","schema":"JDOE_DELTA__RUN","name":"m","resource_type":"model"}' '{"database":"sandbox-prj","schema":"JDOE_DELTA__STG","name":"s","resource_type":"model"}' > "$W/d-v2.jsonl"
cp "$W/stubs/dbt-cwd" "$DBT_V1_VENV/bin/dbt"; cp "$W/stubs/dbt-cwd" "$DBT_BIN_DIR/dbt"
ASFLUX; FLUX 'DBT_V4_FLUX=D005\n'; life "$FW" start >/dev/null
O="$(FRUN destinations delta)"
has "$O" "[delta] v2 vs v4: 0 node(s) written elsewhere" && pass "destinations delta (flux) : v2 vs v4, préfixe du flux ignoré" || bad "v2 vs v4 flux ($O)"
has "$O" "[delta] v4: every node in the v4 space (sandbox-prj, JDOE_V4_D005 / JDOE_V4_D005_*, flux D005)" && pass "…tout nœud de la v4 dans l'espace du flux" || bad "espace du flux ($O)"
printf '%s\n' '{"database":"sandbox-prj","schema":"JDOE_V4_DELTA__STG","name":"s","resource_type":"model"}' > "$W/d-v4.jsonl"
O="$(FRUN destinations delta)"; has "$O" "1 node(s) OUTSIDE the v4 space (JDOE_V4_D005_*, flux D005)" && pass "…un nœud sous l'espace principal : hors de l'espace du flux" || bad "hors espace flux ($O)"
cp "$STUB_DBT" "$DBT_V1_VENV/bin/dbt"; cp "$STUB_DBT" "$DBT_BIN_DIR/dbt"

echo "== flux : la preuve des hooks de global-v4 vaut pour un flux, et pour lui seul =="
G="$FW/global-v4"; mkdir -p "$G/macros" "$G/dbt_packages" "$FW/docs"
printf 'name: fleet_global_v4\nprofile: "prof_global"\non-run-start: ["select 1"]\n' > "$G/dbt_project.yml"
printf 'packages:\n  - local: ../v4/delta/dbt\n' > "$G/packages.yml"
printf 'packages:\n- local: ../v4/delta/dbt\n  name: delta\nsha1_hash: 0\n' > "$G/package-lock.yml"
ln -sfn ../../v4/delta/dbt "$G/dbt_packages/delta"
printf 'DBT_HOOKS_COMPILE_OK="global-v4"\nDBT_HOOKS_V4_PROOF="docs/hooks-v4.md"\n' >> "$FW/.devcontainer/dbt.conf"
ASFLUX   # la copie principale aux mêmes réglages (un flux ne peut que les resserrer)
# VLINEAT FICHIER SCEAU [FLUX] — une ligne de verdict dans FICHIER ; VLINE SCEAU [FLUX] — dans la preuve que CETTE copie
# lit (dbt_hooks_v4_proof_path : docs/hooks-v4.md pour la copie principale, docs/hooks-v4-<FLUX>.md pour un flux)
VLINEAT() { printf 'VERDICT HOOKS GLOBAL-V4%s : PREUVE OK ; TÉMOINS OK ; sceau %s\n' "${3:+ FLUX $3}" "$2" > "$FW/$1"; }
VLINE() { VLINEAT "$(LIBF dbt_hooks_v4_proof_path)" "$@"; }
NOFLUX; SM="$(SEAL)"
FLUX 'DBT_V4_FLUX=D005\n'; S5="$(SEAL)"
FLUX 'DBT_V4_FLUX=D006\n'; S6="$(SEAL)"
FLUX 'DBT_V4_FLUX=D005\n'
[[ "$S5" =~ ^[0-9a-f]{20}$ ]] && [ "$S5" != "$SM" ] && [ "$S5" != "$S6" ] && pass "sceau : un par flux (principal $SM, D005 $S5, D006 $S6)" || bad "sceaux ($SM $S5 $S6)"
[ "$(LIBF dbt_hooks_v4_verdict_line abc D005)" = "VERDICT HOOKS GLOBAL-V4 FLUX D005 : PREUVE OK ; TÉMOINS OK ; sceau abc" ] && pass "ligne de verdict d'un flux : « VERDICT HOOKS GLOBAL-V4 FLUX D005 : … »" || bad "ligne de verdict ($(LIBF dbt_hooks_v4_verdict_line abc D005))"
[ "$(LIBF dbt_hooks_v4_proof_path)" = docs/hooks-v4-D005.md ] && pass "flux D005 : sa preuve est un fichier à lui, docs/hooks-v4-D005.md (DBT_HOOKS_V4_PROOF, -D005 avant l'extension)" || bad "chemin de la preuve du flux ($(LIBF dbt_hooks_v4_proof_path))"
# shellcheck disable=SC2034  # lues par dbt_hooks_v4_proof_path, dans le même sous-shell
PP() { ( source "$FW/.devcontainer/lib-dbt.sh"; DBT_HOOKS_V4_PROOF="$1"; DBT_V4_FLUX="$2"; dbt_hooks_v4_proof_path ); }
[ "$(PP docs/flotte/HOOKS_V4.md H)" = docs/flotte/HOOKS_V4-H.md ] && [ "$(PP a.b/preuve D005)" = a.b/preuve-D005 ] && [ "$(PP x.y.md D005)" = x.y-D005.md ] \
  && [ "$(PP .preuve H)" = .preuve-H ] && [ "$(PP docs/p.md '')" = docs/p.md ] && [ -z "$(PP '' H)" ] \
  && pass "dbt_hooks_v4_proof_path : -<FLUX> avant l'extension du dernier composant (un point dans un dossier ne compte pas) ; sans flux, DBT_HOOKS_V4_PROOF ; vide, vide" || bad "dbt_hooks_v4_proof_path ($(PP a.b/preuve D005) $(PP x.y.md D005) $(PP .preuve H))"
VLINE "$S5" D005; O="$(FRUN global-v4 compile)"; has "$O" "ARGS=compile" && has "$O" "seal $S5, docs/hooks-v4-D005.md, flux D005" && pass "flux D005, preuve du flux D005 (son fichier) : compile accepté, et dit pourquoi" || bad "preuve du flux ($O)"
VLINE "$S5"; O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "…verdict sans « FLUX D005 » (celui de la copie principale), même au sceau du flux : refusé" || bad "verdict principal dans le flux ($O)"
VLINE "$SM"; O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "…la preuve de la copie principale : refusée dans le flux" || bad "preuve principale dans le flux ($O)"
VLINE "$S5" D006; O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "…verdict d'un autre flux (D006) au sceau de D005 : refusé" || bad "verdict d'un autre flux ($O)"
VLINE "$S6" D006; O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "…la preuve du flux D006 : refusée dans D005" || bad "preuve d'un autre flux ($O)"
# chaque copie lit SA preuve : la bonne ligne du flux, mais dans le fichier de la copie principale, ne vaut rien ici ;
# et les deux preuves tiennent ensemble dans un même arbre (le jour où la branche du flux revient sur main)
rm -f "$FW/docs/hooks-v4-D005.md"; VLINEAT docs/hooks-v4.md "$S5" D005
O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && has "$O" "docs/hooks-v4-D005.md" && ! has "$O" "ARGS=compile" \
  && pass "…la ligne du flux D005 au bon sceau, mais dans le fichier de la copie principale (docs/hooks-v4.md) : refusée, et son fichier nommé" || bad "preuve du flux dans le fichier principal ($O)"
VLINEAT docs/hooks-v4.md "$SM"; VLINE "$S5" D005
O="$(FRUN global-v4 compile)"; has "$O" "ARGS=compile" && pass "…la preuve de la copie principale et celle du flux, chacune dans son fichier : le flux compile sous la sienne" || bad "deux preuves, le flux ($O)"
cp "$FW/profiles/v4.env" "$W/v4-env-sauve"; echo "ELEMENTARY=1" >> "$FW/profiles/v4.env"
[ "$(SEAL)" = "$S5" ] && pass "sceau du flux : indépendant de profiles/v4.env (l'environnement principal, que le flux ne lit pas)" || bad "sceau du flux et v4.env"
cp "$W/v4-env-sauve" "$FW/profiles/v4.env"
echo "ELEMENTARY=1" >> "$FW/profiles/v4-D005.env"
O="$(FRUN global-v4 compile)"; [ "$(SEAL)" != "$S5" ] && has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "…profiles/v4-D005.env retouché : sceau changé, compile refusé" || bad "env du flux hors du sceau ($O)"
cp "$W/v4-D005.env" "$FW/profiles/v4-D005.env"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"
has "$O" "✅ global-v4: compile/show allowed — the proof of its hooks holds (seal $S5, docs/hooks-v4-D005.md, flux D005)" && pass "doctor : preuve du flux valable (son fichier), dite" || bad "doctor preuve flux ($(grep global-v4 <<<"$O"))"
has "$O" "✅ flux D005 (.devcontainer/flux.conf)" && has "$O" "✅ profiles/v4-D005.env = profiles/dbt.env with DATASET_PREFIX=JDOE_V4_D005" && pass "doctor : le flux, son environnement" || bad "doctor flux ($(grep -i flux <<<"$O"))"
has "$O" "✅ this copy is flux D005; the main copy is $MAINW" && pass "doctor : la copie de flux et sa copie principale, dites" || bad "doctor rôle flux ($(grep -i 'this copy' <<<"$O"))"
has "$O" "git is shared: this copy's worktrees follow the products' branches the main copy follows" && ! has "$O" "flux H: the two lines" \
  && pass "doctor (flux D005) : git partagé avec la copie principale, dit ; pas l'alerte de la ligne harmonisée" || bad "doctor flux et git ($(grep -i 'git' <<<"$O" | head -3))"
has "$O" "✅ v4/delta/: .env -> profiles/v4-D005.env" && has "$O" "✅ global-v4/.env -> profiles/v4-D005.env" && pass "doctor : .env de la v4 et de global-v4 sur l'environnement du flux" || bad "doctor .env flux ($(grep '\.env' <<<"$O"))"
FLUX 'DBT_V4_FLUX=H\n'; life "$FW" start >/dev/null; SH="$(SEAL)"
[[ "$SH" =~ ^[0-9a-f]{20}$ ]] && [ "$SH" != "$SM" ] && [ "$SH" != "$S5" ] && [ "$SH" != "$S6" ] && pass "sceau de la ligne harmonisée (flux H) : le sien ($SH)" || bad "sceau H ($SH)"
VLINE "$SH" H; O="$(FRUN global-v4 compile)"; has "$O" "ARGS=compile" && has "$O" "seal $SH, docs/hooks-v4-H.md, flux H" && pass "ligne harmonisée, sa preuve (VERDICT … FLUX H) : compile de global-v4 accepté" || bad "preuve H ($O)"
VLINE "$SM"; O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "…la preuve de la ligne ISO (la copie principale) : refusée dans la ligne harmonisée" || bad "preuve ISO sous H ($O)"
VLINE "$S5" D005; O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "…la preuve du flux D005 : refusée dans la ligne harmonisée" || bad "preuve D005 sous H ($O)"
FLUX 'DBT_V4_FLUX=D005\n'; life "$FW" start >/dev/null
NOFLUX; ASMAIN; life "$FW" start >/dev/null
O="$(FRUN global-v4 compile)"; has "$O" "ARGS=compile" && has "$O" "seal $SM, docs/hooks-v4.md)" && pass "flux retiré : la copie principale compile sous SA preuve (docs/hooks-v4.md), restée là pendant le flux" || bad "deux preuves, la principale ($O)"
VLINEAT docs/hooks-v4.md "$S5" D005
O="$(FRUN global-v4 compile)"; has "$O" "does not hold" && ! has "$O" "ARGS=compile" && pass "…la preuve du flux D005 recopiée dans son fichier : refusée" || bad "preuve du flux hors du flux ($O)"
[ "$(SEAL)" = "$SM" ] && pass "…et le sceau principal est celui d'avant le flux" || bad "sceau principal changé"
VLINE "$SM"; O="$(FRUN global-v4 compile)"; has "$O" "ARGS=compile" && pass "…sa propre preuve : compile accepté" || bad "preuve principale ($O)"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "✅ no flux (.devcontainer/flux.conf absent)" && has "$O" "✅ this copy is the MAIN one" && pass "doctor : copie principale, pas de flux, dit" || bad "doctor sans flux ($(grep -iE 'flux|this copy' <<<"$O"))"
ASFLUX
FLUX 'DBT_V4_FLUX=d005\n'; [ -z "$(SEAL)" ] && pass "flux.conf invalide : pas de sceau" || bad "sceau sous un flux invalide"
O="$( (cd "$FW" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "❌ flux: .devcontainer/flux.conf is not a regular file holding one line" && pass "doctor : déclaration refusée, signalée" || bad "doctor flux invalide ($(grep -i flux <<<"$O"))"
O="$(life "$FW" start)"
check "déclaration refusée, just setup : plus de .env dans v4/delta (aucun espace v4 lu par l'extension)" test ! -e "$FW/v4/delta/dbt/.env" -a ! -L "$FW/v4/delta/dbt/.env"
check "…ni dans global-v4/" test ! -e "$FW/global-v4/.env" -a ! -L "$FW/global-v4/.env"
has "$O" "WARNING: flux" && pass "…et dit" || bad "retrait silencieux"
VLINE "$SM" D005
LIBF dbt_hooks_v4_verdict "$FW/docs/hooks-v4.md" "$SM" D005 >/dev/null && ! LIBF dbt_hooks_v4_verdict "$FW/docs/hooks-v4.md" "$SM" 'D00.' >/dev/null \
  && pass "dbt_hooks_v4_verdict : un nom de flux mal formé (D00., un motif qui couvrirait D005) ne vaut rien" || bad "verdict flux mal formé"
NOFLUX; ASMAIN; life "$FW" start >/dev/null
sed -i -e '/^DBT_HOOKS_COMPILE_OK=/d' -e '/^DBT_HOOKS_V4_PROOF=/d' "$FW/.devcontainer/dbt.conf"
rm -rf "$FW/docs" "$FW/global-v4"

echo "== flux : \`dbt\` dans la copie de travail d'un autre espace (un flux), et hors de tout projet =="
AW="$W/copie-flux"; mkdir -p "$AW/.devcontainer" "$AW/v4/delta/dbt/models"
cp "$FW/.devcontainer/dbt-run.sh" "$FW/.devcontainer/lib-dbt.sh" "$AW/.devcontainer/"; printf 'DBT_V4_FLUX=D007\n' > "$AW/.devcontainer/flux.conf"
printf 'name: delta\n' > "$AW/v4/delta/dbt/dbt_project.yml"
O="$(CWD="$AW/v4/delta/dbt/models" FRUN auto run -s a)"; has "$O" "a dbt project of another workspace ($AW, a flux)" && ! has "$O" "ARGS=" && pass "\`dbt\` dans le projet d'une copie de flux : refusé, jamais dbt v2 brut" || bad "copie de flux lancée en brut ($O)"
ln -sfn "$AW/v4/delta/dbt" "$W/lien-aw"
O="$(CWD="$W/lien-aw" FRUN auto run -s a)"; has "$O" "a dbt project of another workspace" && ! has "$O" "ARGS=" && pass "…atteint par un lien depuis ailleurs : refusé aussi (chemin réel)" || bad "lien vers une copie de flux ($O)"
rm -f "$W/lien-aw"
O="$(CWD="$AW" FRUN auto --version)"; has "$O" "dbt 2.0.0" && pass "…à la racine de cette copie, hors de tout projet : dbt --version, comme avant" || bad "auto racine d'une copie ($O)"
mkdir -p "$W/libre/m"; printf 'name: libre\n' > "$W/libre/dbt_project.yml"
O="$(CWD="$W/libre/m" FRUN auto parse)"; has "$O" "ARGS=parse" && pass "un projet dbt hors de tout espace de travail : inchangé (dbt v2 nu)" || bad "projet libre ($O)"
O="$(CWD="$W/libre/m" FRUN auto run --project-dir "$FW/v4/delta/dbt")"; has "$O" "refused outside a project the guard knows" && ! has "$O" "ARGS=" && pass "…mais jamais avec --project-dir (un projet du coordinateur choisi d'ailleurs)" || bad "projet libre --project-dir ($O)"
# hors de tout projet : une liste blanche, et jamais un projet choisi par la ligne de commande ou l'environnement
O="$(CWD="$FW" FRUN auto run --project-dir v4/delta/dbt -s a)"; has "$O" "refused outside a project the guard knows" && ! has "$O" "ARGS=" && pass "racine : dbt run --project-dir v4/delta/dbt → refusé" || bad "racine --project-dir ($O)"
O="$(CWD="$FW" FRUN auto build --project-dir=v2/delta/dbt)"; has "$O" "refused outside a project the guard knows" && ! has "$O" "ARGS=" && pass "racine : dbt build --project-dir=v2/delta/dbt → refusé" || bad "racine --project-dir= ($O)"
O="$(CWD="$FW" FRUN auto parse --profiles-dir /x)"; has "$O" "refused outside a project the guard knows" && ! has "$O" "ARGS=" && pass "racine : --profiles-dir → refusé" || bad "racine --profiles-dir ($O)"
O="$(CWD="$FW" FRUN auto deps --packages-install-path /x)"; has "$O" "refused outside a project the guard knows" && ! has "$O" "ARGS=" && pass "racine : --packages-install-path → refusé" || bad "racine --packages-install-path ($O)"
O="$(CWD="$FW" DBT_PROJECT_DIR="$FW/v4/delta/dbt" FRUN auto run)"; has "$O" "DBT_PROJECT_DIR is set" && ! has "$O" "ARGS=" && pass "racine : DBT_PROJECT_DIR=v4/delta/dbt dbt run → refusé" || bad "racine DBT_PROJECT_DIR ($O)"
O="$(CWD="$FW" DBT_PACKAGES_INSTALL_PATH=/x FRUN auto --version)"; has "$O" "DBT_PACKAGES_INSTALL_PATH is set" && ! has "$O" "ARGS=" && pass "racine : DBT_PACKAGES_INSTALL_PATH → refusé" || bad "racine DBT_PACKAGES_INSTALL_PATH ($O)"
mkdir -p "$W/ailleurs-vide"
O="$(CWD="$W/ailleurs-vide" FRUN auto run --project-dir "$FW/v4/delta/dbt")"; has "$O" "refused outside a project the guard knows" && ! has "$O" "ARGS=" && pass "hors de l'espace : dbt run --project-dir \$FW/v4/delta/dbt → refusé" || bad "ailleurs --project-dir ($O)"
O="$(CWD="$FW" FRUN auto run -s a)"; has "$O" "outside every dbt project" && ! has "$O" "ARGS=" && pass "racine, hors de tout projet : dbt run → refusé (liste blanche)" || bad "racine run ($O)"
O="$(CWD="$W/ailleurs-vide" FRUN auto --log-level debug run)"; has "$O" "outside every dbt project" && ! has "$O" "ARGS=" && pass "ailleurs, hors de tout projet : dbt --log-level debug run → refusé" || bad "ailleurs run ($O)"
O="$(CWD="$FW" FRUN auto system update)"; has "$O" "ARGS=system update" && pass "racine : dbt system update → dbt v2 nu (liste blanche)" || bad "racine system ($O)"
rmdir "$W/ailleurs-vide"
# un dossier de l'espace de travail atteint par un lien : aiguillé par son chemin réel
ln -sfn "$FW/v4/delta/dbt" "$W/lien-v4"
O="$(CWD="$W/lien-v4" FRUN auto parse)"; grep -q 'PFX=JDOE_V4$' <<<"$O" && has "$O" "CWD=$FW/v4/delta/dbt" && pass "\`dbt\` dans un lien vers v4/delta/dbt : le garde-fou de la v4 (chemin réel)" || bad "lien vers la v4 ($O)"
O="$(CWD="$W/lien-v4" FRUN auto run)"; has "$O" "without a selection" && pass "…\`dbt run\` y passe par le garde-fou" || bad "lien vers la v4, run ($O)"
rm -f "$W/lien-v4"
rm -rf "$AW" "$W/libre"

echo "== flux : deux copies réelles — le just setup d'un flux ne touche pas à l'état du container =="
ASMAIN; NOFLUX; printf '/.devcontainer/flux.conf\n/profiles/v4-*.env\n' >> "$FW/.gitignore"
git config --global url."file://$W/gh/".insteadOf "https://github.com/"   # epsilon : son dépôt reste joignable, sans réseau
life "$FW" start >/dev/null
BASHRC0="$(sha256sum < "$HOME/.bashrc")"; GC0="$(git config --global --list | grep -v '^safe\.directory=' | sort)"
NUV0="$(grep -c '^uv ' "$STUB_LOG")"; NI0="$(grep -c '^installer' "$STUB_LOG")"
CF="$W/copie-flux-reelle"; git clone -q "$W/fleet-origin.git" "$CF" 2>/dev/null
mkdir -p "$CF/.devcontainer" "$CF/profiles"
for f in dbt.conf products.conf referents.conf lib-dbt.sh dbt-run.sh dbt-doctor.sh; do [ -f "$FW/.devcontainer/$f" ] && cp "$FW/.devcontainer/$f" "$CF/.devcontainer/"; done
cp -a "$FW/profiles/." "$CF/profiles/"; rm -f "$CF/profiles/v4-"*.env; cp "$FW/.gitignore" "$CF/.gitignore"
printf 'DBT_V4_FLUX=D007\n' > "$CF/.devcontainer/flux.conf"
CRUN() { ( cd "${CWD:-$CF}" && bash "$CF/.devcontainer/dbt-run.sh" "$@" ) 2>&1; }
LIBC() { ( cd "$CF" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && "$@"' _ "$@" ) 2>&1; }
O="$(life "$CF" start)"
[ "$(LIBC dbt_v4_role)" = flux ] && test "$(readlink -f "$CF/v4/delta/dbt/.env")" = "$(readlink -f "$CF/profiles/v4-D007.env")" \
  && pass "copie de flux réelle (un clone, flux D007) : préparée — v4/delta, son .env sur profiles/v4-D007.env" || bad "copie de flux réelle ($(LIBC dbt_v4_role); $(tail -5 <<<"$O"))"
[ "$(sha256sum < "$HOME/.bashrc")" = "$BASHRC0" ] && pass "…~/.bashrc inchangé (\`dbt\` et DBT_PROFILES_DIR visent toujours la copie principale)" || bad "réécriture de ~/.bashrc par le flux ($(grep -E '^export DBT_PROFILES_DIR|^dbt\(\)' "$HOME/.bashrc"))"
[ "$(git config --global --list | grep -v '^safe\.directory=' | sort)" = "$GC0" ] && pass "…git config --global inchangé (safe.directory à part : ajouté pour ses worktrees)" || bad "git global réécrit par le flux ($(diff <(printf '%s\n' "$GC0") <(git config --global --list | grep -v '^safe\.directory=' | sort)))"
[ "$(grep -c '^uv ' "$STUB_LOG")" = "$NUV0" ] && [ "$(grep -c '^installer' "$STUB_LOG")" = "$NI0" ] && pass "…aucun moteur installé ni reconstruit (uv, installeur dbt v2)" || bad "moteurs touchés par le flux"
O="$( (cd "$FW/v2/delta/dbt" && bash -c 'source "$HOME/.bashrc" >/dev/null 2>&1; dbt parse') 2>&1)"; has "$O" "ARGS=parse" && has "$O" "CWD=$FW/v2/delta/dbt" && pass "…\`dbt parse\` tapé dans la copie principale, nouveau terminal : toujours son garde-fou" || bad "dbt de la copie principale après le flux ($O)"
FJ JDOE_V4_D007_DELTA__X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" CRUN v4 delta run -s a)"; has "$O" "all inside the sandbox" && has "$O" "PFX=JDOE_V4_D007" && pass "…sa v4 écrit sous JDOE_V4_D007_*" || bad "flux réel, v4 sous son espace ($O)"
FJ JDOE_V4_DELTA__X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" CRUN v4 delta run -s a)"; has "$O" "outside the sandbox" && ! has "$O" "ARGS=" && pass "…jamais sous l'espace principal JDOE_V4" || bad "flux réel vers l'espace principal ($O)"
O="$( (cd "$CF" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "✅ this copy is flux D007; the main copy is $FW" && pass "…doctor : la copie de flux et sa copie principale" || bad "doctor copie de flux ($(grep -i 'this copy' <<<"$O"))"
# une épingle de moteur autre que celle de la copie principale : jamais installée, et toute commande refusée
sed -i 's/^DBT_V1_PINS=.*/DBT_V1_PINS="dbt-core==1.10.9 dbt-bigquery==1.10.9"/' "$CF/.devcontainer/dbt.conf"
O="$(life "$CF" start)"
[ "$(grep -c '^uv ' "$STUB_LOG")" = "$NUV0" ] && has "$O" "never rebuilt from here" && pass "épingle dbt Core du flux autre que celle de la copie principale : venv commun jamais reconstruit, dit" || bad "épingle du flux ($(grep -iE 'pins|dbt Core' <<<"$O" | head -3))"
O="$(CRUN v4 delta parse)"; has "$O" "DBT_V1_PINS differs from the main copy's" && ! has "$O" "ARGS=" && pass "…et toute commande dbt de la copie de flux refusée" || bad "épingle du flux, commande ($O)"
O="$( (cd "$CF" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_engines "$PWD"') 2>&1)"
[ "$(grep -c '^uv ' "$STUB_LOG")" = "$NUV0" ] && [ "$(grep -c '^installer' "$STUB_LOG")" = "$NI0" ] && has "$O" "never from this copy" && pass "…dbt_engines (onCreateCommand) de la copie de flux : aucun moteur installé" || bad "dbt_engines de la copie de flux ($O)"
cp "$FW/.devcontainer/dbt.conf" "$CF/.devcontainer/dbt.conf"
# un flux dont le dbt.conf ne nomme aucune copie principale : refusé, et jamais propriétaire du container
sed -i 's/^DBT_V4_MAIN_WS=.*/DBT_V4_MAIN_WS=""/' "$CF/.devcontainer/dbt.conf"
O="$(life "$CF" start)"
[ "$(sha256sum < "$HOME/.bashrc")" = "$BASHRC0" ] && [ "$(grep -c '^uv ' "$STUB_LOG")" = "$NUV0" ] && has "$O" "is the main copy's" \
  && pass "copie de flux sans copie principale nommée (DBT_V4_MAIN_WS vide) : ~/.bashrc et moteurs laissés quand même" || bad "flux sans DBT_V4_MAIN_WS propriétaire du container ($(grep -E '^export DBT_PROFILES_DIR' "$HOME/.bashrc"))"
O="$(CRUN v4 delta parse)"; has "$O" "names no main copy by an absolute path" && ! has "$O" "ARGS=" && pass "…et toute commande dbt y est refusée" || bad "flux sans DBT_V4_MAIN_WS, commande ($O)"
cp "$FW/.devcontainer/dbt.conf" "$CF/.devcontainer/dbt.conf"
mv "$HOME/.bigqueryrc" "$W/bigqueryrc-sauve"; echo 'DBT_UPSTREAM_PUSH_LOCK=0' >> "$CF/.devcontainer/dbt.conf"
life "$CF" start >/dev/null
[ ! -e "$HOME/.bigqueryrc" ] && pass "…~/.bigqueryrc absent : jamais créé par la copie de flux" || bad "création de ~/.bigqueryrc par le flux"
[ "$(git -C "$CF" config --get remote.up-alpha.pushurl)" = DISABLED ] && pass "…DBT_UPSTREAM_PUSH_LOCK=0 dans la copie de flux : son remote up-alpha reste verrouillé (pushurl DISABLED)" || bad "flux qui déverrouille son remote ($(git -C "$CF" config --get remote.up-alpha.pushurl))"
mv "$W/bigqueryrc-sauve" "$HOME/.bigqueryrc"; cp "$FW/.devcontainer/dbt.conf" "$CF/.devcontainer/dbt.conf"
# les réglages git globaux : la copie de flux n'ajoute que des verrous — les trois couches du verrou 4 comprises —, ne
# réécrit ni HTTPS→SSH ni le reste de core.sshCommand (les clés épinglées de la copie principale), ne remplace jamais la
# garde installée, ne lève rien
GSET() { ( cd "$1" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && _dbt_upstream_urls() { echo "git@git.invalid:grp/x.git"; } && dbt_git_setup' ) 2>&1; }
# GSETC CFG COPIE [EVAL] — dbt_git_setup de COPIE sur la configuration globale CFG (une upstream ssh, git.invalid) ; EVAL
# après dbt_load_conf (un réglage du dbt.conf de la copie)
GSETC() { ( cd "$2" && GIT_CONFIG_GLOBAL="$1" bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && eval "$1" && _dbt_upstream_urls() { echo "git@git.invalid:grp/x.git"; } && dbt_git_setup' _ "${3:-:}" ) 2>&1; }
GC() { GIT_CONFIG_GLOBAL="$1" git config --global "${@:2}"; }
KEY="git.invalid ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAkeyforteststestsaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
echo "$KEY" > "$CF/.devcontainer/upstream_known_hosts"; echo "$KEY" > "$FW/.devcontainer/upstream_known_hosts"
cp "$SRC/"*"git-ssh-garde.sh"* "$CF/.devcontainer/git-ssh-garde.sh"
KHM="$W/autre/.devcontainer/upstream_known_hosts"; GQ="$(printf '%q' "$GI")"; GV="$W/verrou4-invite"; mkdir -p "$GV"
cp "$GI" "$GV/garde.principale"
# (a) aucune garde encore : posée devant les clés épinglées de la copie principale, jamais celles du flux
: > "$GV/s1.cfg"; GC "$GV/s1.cfg" core.sshCommand "ssh -o \"UserKnownHostsFile=$KHM\""
O="$(GSETC "$GV/s1.cfg" "$CF")"
[ "$(GC "$GV/s1.cfg" --get core.sshCommand)" = "bash $GQ --hosts=git.invalid -o \"UserKnownHostsFile=$KHM\"" ] \
  && [ -z "$(GC "$GV/s1.cfg" --get url.git@git.invalid:.insteadOf)" ] \
  && [ "$(GC "$GV/s1.cfg" --get-all url.DISABLED://.pushInsteadOf | grep -c 'git\.invalid')" = 13 ] && has "$O" "ADDED by this copy" \
  && pass "copie de flux, hôte SSH : verrou 4 ajouté (13 préfixes, la garde ssh devant les clés épinglées de la copie principale) ; HTTPS→SSH laissé à la copie principale" \
  || bad "git global de la copie de flux ($(GC "$GV/s1.cfg" --get core.sshCommand) | $O)"
! GC "$GV/s1.cfg" --get core.sshCommand | grep -qF "$CF/" && pass "…core.sshCommand ne nomme aucun chemin de la copie de flux" || bad "core.sshCommand nomme la copie de flux ($(GC "$GV/s1.cfg" --get core.sshCommand))"
# (a) la garde couvre déjà l'hôte : core.sshCommand laissé octet pour octet
SCM="bash $GQ --hosts=git.invalid -o \"UserKnownHostsFile=$KHM\""
: > "$GV/s2.cfg"; GC "$GV/s2.cfg" core.sshCommand "$SCM"; O="$(GSETC "$GV/s2.cfg" "$CF")"
[ "$(GC "$GV/s2.cfg" --get core.sshCommand)" = "$SCM" ] && has "$O" "left as it is" \
  && pass "…la garde de la copie principale couvre l'hôte : core.sshCommand laissé octet pour octet" || bad "garde de la principale réécrite par le flux ($(GC "$GV/s2.cfg" --get core.sshCommand))"
# (a) la garde d'un autre hôte : l'hôte ajouté à --hosts=, le reste gardé
: > "$GV/s3.cfg"; GC "$GV/s3.cfg" core.sshCommand "bash $GQ --hosts=autre.invalid -o \"UserKnownHostsFile=$KHM\""; GSETC "$GV/s3.cfg" "$CF" >/dev/null
[ "$(GC "$GV/s3.cfg" --get core.sshCommand)" = "bash $GQ --hosts=autre.invalid,git.invalid -o \"UserKnownHostsFile=$KHM\"" ] \
  && pass "…une garde sur un autre hôte : git.invalid ajouté à --hosts=, autre.invalid et les clés de la principale gardés" || bad "hôtes de la garde ($(GC "$GV/s3.cfg" --get core.sshCommand))"
# (a) DBT_UPSTREAM_PUSH_LOCK=0 dans le dbt.conf du flux : la garde n'est jamais retirée
: > "$GV/s5.cfg"; GC "$GV/s5.cfg" core.sshCommand "$SCM"; O="$(GSETC "$GV/s5.cfg" "$CF" 'DBT_UPSTREAM_PUSH_LOCK=0')"
[ "$(GC "$GV/s5.cfg" --get core.sshCommand)" = "$SCM" ] && [ "$(GC "$GV/s5.cfg" --get-all url.DISABLED://.pushInsteadOf | grep -c 'git\.invalid')" = 13 ] && has "$O" "never lifts a lock" \
  && pass "…DBT_UPSTREAM_PUSH_LOCK=0 dans le flux : la garde ssh et les 13 préfixes restent, et c'est dit" || bad "flux qui retire la garde ($(GC "$GV/s5.cfg" --get core.sshCommand) | $O)"
# (a) la garde installée est celle de la copie principale : jamais remplacée depuis le flux ; absente, posée
echo "# la copie installée par la copie principale" >> "$GI"; G0="$(sha256sum < "$GI")"
: > "$GV/s4.cfg"; GC "$GV/s4.cfg" core.sshCommand "ssh -o \"UserKnownHostsFile=$KHM\""; GSETC "$GV/s4.cfg" "$CF" >/dev/null
[ "$(sha256sum < "$GI")" = "$G0" ] && [ "$(GC "$GV/s4.cfg" --get core.sshCommand)" = "bash $GQ --hosts=git.invalid -o \"UserKnownHostsFile=$KHM\"" ] \
  && pass "…la garde installée (~/.local/libexec), autre que celle du flux : jamais remplacée depuis le flux" || bad "garde installée remplacée par le flux"
rm -f "$GI"; : > "$GV/s4b.cfg"; GSETC "$GV/s4b.cfg" "$CF" >/dev/null
cmp -s "$GI" "$CF/.devcontainer/git-ssh-garde.sh" && [ "$(GC "$GV/s4b.cfg" --get core.sshCommand)" = "bash $GQ --hosts=git.invalid" ] \
  && pass "…aucune garde installée, aucun core.sshCommand : la garde posée, sans clés épinglées du flux" || bad "garde absente ($(GC "$GV/s4b.cfg" --get core.sshCommand))"
cp "$GV/garde.principale" "$GI"
# (b) selon l'état du container, jamais selon le dbt.conf du flux
: > "$GV/s6.cfg"; GC "$GV/s6.cfg" url.git@git.invalid:.insteadOf "https://git.invalid/"; GSETC "$GV/s6.cfg" "$CF" 'DBT_UPSTREAM_HTTPS_TO_SSH=0' >/dev/null
[ "$(GC "$GV/s6.cfg" --get-all http.https://git.invalid.proxy | tail -1)" = "http://127.0.0.1:9" ] \
  && [ "$(GC "$GV/s6.cfg" --get-all credential.https://git.invalid.helper | tail -1)" = "$(LIBC _dbt_https_quitter git.invalid)" ] \
  && [ "$(GC "$GV/s6.cfg" --get url.git@git.invalid:.insteadOf)" = "https://git.invalid/" ] \
  && pass "…le container lit https://git.invalid par ssh, le flux dit DBT_UPSTREAM_HTTPS_TO_SSH=0 : proxy mort et quitteur ajoutés quand même, HTTPS→SSH laissé" || bad "couche (b) du flux selon son dbt.conf"
: > "$GV/s7.cfg"; GC "$GV/s7.cfg" --add http.https://git.invalid.proxy "http://127.0.0.1:9"; GSETC "$GV/s7.cfg" "$CF" >/dev/null
[ "$(GC "$GV/s7.cfg" --get-all http.https://git.invalid.proxy | tail -1)" = "http://127.0.0.1:9" ] && [ -z "$(GC "$GV/s7.cfg" --get url.git@git.invalid:.insteadOf)" ] \
  && pass "…le container lit git.invalid par https : la couche https laissée telle quelle (le proxy mort posé avant n'est pas retiré)" || bad "flux qui lève la couche https"
# témoin : la copie principale, elle, réécrit core.sshCommand avec SES clés épinglées
: > "$GV/s8.cfg"; GC "$GV/s8.cfg" core.sshCommand "ssh -o \"UserKnownHostsFile=$KHM\""; GSETC "$GV/s8.cfg" "$FW" >/dev/null
has "$(GC "$GV/s8.cfg" --get core.sshCommand)" "UserKnownHostsFile=$FW/.devcontainer/upstream_known_hosts" && pass "…la copie principale, elle, le réécrit (le témoin voit une réécriture)" || bad "copie principale et core.sshCommand ($(GC "$GV/s8.cfg" --get core.sshCommand))"
# et sur la configuration globale du container (HOME factice, remise telle quelle ensuite) : le flux n'y lève rien
cp "$HOME/.gitconfig" "$GV/gitconfig.avant"
for P in "git@git.invalid:" "ssh://git@git.invalid/" "https://git.invalid/"; do git config --global --fixed-value --unset-all url.DISABLED://.pushInsteadOf "$P" 2>/dev/null; done
echo 'DBT_UPSTREAM_PUSH_LOCK=0' >> "$CF/.devcontainer/dbt.conf"
O="$(GSET "$CF")"; git config --global --get-all url.DISABLED://.pushInsteadOf | grep -qxF "git@git.invalid:" && has "$O" "never lifts a lock" && pass "…DBT_UPSTREAM_PUSH_LOCK=0 dans la copie de flux : le verrou n'est jamais levé, et c'est dit" || bad "flux qui lève un verrou ($O)"
cp "$FW/.devcontainer/dbt.conf" "$CF/.devcontainer/dbt.conf"; cp "$GV/gitconfig.avant" "$HOME/.gitconfig"
rm -f "$FW/.devcontainer/upstream_known_hosts" "$CF/.devcontainer/upstream_known_hosts" "$CF/.devcontainer/git-ssh-garde.sh"
# un nettoyage ordinaire efface flux.conf (ignoré) : la copie devient orpheline, jamais la copie principale
git -C "$CF" clean -fdXq
[ ! -e "$CF/.devcontainer/flux.conf" ] && [ ! -e "$CF/profiles/v4-D007.env" ] && [ -d "$CF/v4/delta/dbt" ] \
  && pass "git clean -fdX dans la copie de flux : flux.conf et profiles/v4-D007.env effacés, worktrees intacts" || bad "git clean -fdX ($(ls "$CF/.devcontainer"))"
O="$(life "$CF" start)"
[ "$(LIBC dbt_v4_role)" = orphan ] && has "$O" "this copy WAS flux D007" && pass "…just setup : copie orpheline, l'ancien flux nommé — jamais la copie principale" || bad "setup après git clean ($(LIBC dbt_v4_role); $(grep -iE 'orphan|flux' <<<"$O" | head -3))"
FJ JDOE_V4_DELTA__X a > "$W/ls-f.jsonl"
O="$(STUB_LS_FILE="$W/ls-f.jsonl" CRUN v4 delta run -s a)"; has "$O" "orphan copy" && ! has "$O" "ARGS=" && pass "…écriture v4 sous l'espace principal JDOE_V4 refusée" || bad "ex-flux vers l'espace principal ($O)"
O="$(CRUN v4 delta parse)"; has "$O" "orphan copy" && ! has "$O" "ARGS=" && pass "…toute commande v4 refusée (parse compris)" || bad "orpheline, v4 parse ($O)"
O="$(STUB_LS_FILE="$W/ls-v2ok.jsonl" CRUN v2 delta build -s a)"; has "$O" "orphan copy" && ! has "$O" "ARGS=" && pass "…v2 build refusé (l'espace de la copie principale)" || bad "orpheline, v2 build ($O)"
O="$(CRUN v2 delta parse)"; has "$O" "ARGS=parse" && pass "…v2 parse accepté (lecture)" || bad "orpheline, v2 parse ($O)"
check "…plus de .env dans sa v4/delta" test ! -e "$CF/v4/delta/dbt/.env" -a ! -L "$CF/v4/delta/dbt/.env"
[ "$(sha256sum < "$HOME/.bashrc")" = "$BASHRC0" ] && pass "…~/.bashrc toujours celui de la copie principale" || bad "réécriture de ~/.bashrc par l'orpheline"
O="$( (cd "$CF" && bash .devcontainer/dbt-doctor.sh) 2>/dev/null)"; has "$O" "❌ ORPHAN copy — this copy is $(cd "$CF" && pwd -P), the main copy is DBT_V4_MAIN_WS=\"$FW\"" && pass "…doctor : copie orpheline, dite" || bad "doctor orpheline réelle ($(grep -i orphan <<<"$O" | head -2))"
# un clone neuf sans flux.conf : une copie orpheline, pas une deuxième copie principale
CG="$W/clone-neuf"; git clone -q "$W/fleet-origin.git" "$CG" 2>/dev/null; mkdir -p "$CG/.devcontainer" "$CG/profiles"
for f in dbt.conf products.conf referents.conf lib-dbt.sh dbt-run.sh dbt-doctor.sh; do [ -f "$FW/.devcontainer/$f" ] && cp "$FW/.devcontainer/$f" "$CG/.devcontainer/"; done
cp -a "$FW/profiles/." "$CG/profiles/"; rm -f "$CG/profiles/v4-"*.env; cp "$FW/.gitignore" "$CG/.gitignore"
life "$CG" start >/dev/null
O="$( (cd "$CG" && bash .devcontainer/dbt-run.sh v4 delta parse) 2>&1)"; has "$O" "orphan copy" && ! has "$O" "ARGS=" && pass "clone neuf sans flux.conf : copie orpheline, aucune commande v4" || bad "clone neuf ($O)"
[ "$(sha256sum < "$HOME/.bashrc")" = "$BASHRC0" ] && pass "…et son just setup laisse ~/.bashrc à la copie principale" || bad "réécriture de ~/.bashrc par un clone neuf"
rm -rf "$CF" "$CG"
git config --global --unset-all url."file://$W/gh/".insteadOf
cp "$W/gitignore-avant-flux" "$FW/.gitignore"
life "$FW" start >/dev/null

echo "== Paquets v1 incomplets : deps relancé au create =="
DP="$WS/v1/dbt"; DEPS() { ( cd "$WS" && bash -c 'source .devcontainer/lib-dbt.sh && dbt_load_conf "$PWD" && _dbt_v1_deps' ) 2>&1; }
printf 'packages:\n  - package: dbt-labs/dbt_utils\n    version: 1.3.0\n  - git: "https://git.example.com/p.git"\n' > "$DP/packages.yml"
mkdir -p "$DP/dbt_packages/dbt_utils"; : > "$DBT_LOG"
O="$(DEPS)"; has "$O" "v1 packages (dbt deps)" && grep -q "ARGS=deps" "$DBT_LOG" && pass "2 paquets déclarés, 1 installé : deps relancé" || bad "paquets incomplets non réinstallés ($O)"
mkdir -p "$DP/dbt_packages/p"; : > "$DBT_LOG"
O="$(DEPS)"; [ -z "$O" ] && ! grep -q "ARGS=deps" "$DBT_LOG" && pass "…tous installés : deps sauté" || bad "deps relancé à tort ($O)"
# un transitif installé (dbt_date) masque le paquet git manquant : le verrou en liste 3
rm -rf "$DP/dbt_packages/p"; mkdir -p "$DP/dbt_packages/dbt_date"
printf 'packages:\n  - package: dbt-labs/dbt_utils\n  - git: "https://git.example.com/p.git"\n  - package: godatadriven/dbt_date\n' > "$DP/package-lock.yml"; : > "$DBT_LOG"
O="$(DEPS)"; grep -q "ARGS=deps" "$DBT_LOG" && pass "…transitif installé, paquet déclaré absent : vu par package-lock.yml" || bad "transitif masque le manquant ($O)"
rm -f "$DP/package-lock.yml"
rm -rf "$DP/dbt_packages" "$DP/packages.yml"

echo "== Aucune fuite hors du bac à sable de test =="
refute "le vrai ~/.gitconfig n'a pas reçu le verrou" grep -q "git.invalid" /home/"$(id -un)"/.gitconfig
check "la vraie ~/.local/libexec/git-ssh-garde.sh n'a pas été touchée" test "$(sha256sum "$REAL_GI" 2>/dev/null || echo absent)" = "$REAL_GI_AVANT"
check "l'upstream n'a toujours qu'une branche" test "$(git -C "$W/upstream.git" for-each-ref refs/heads | wc -l)" = 1

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mTOUS LES CONTRÔLES PASSENT\033[0m"; else echo -e "\033[31mECHECS DETECTES\033[0m"; fi
exit "$fail"
