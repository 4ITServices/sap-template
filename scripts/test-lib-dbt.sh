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
has "$(tail -1 "$STUB_LOG")" "--output json --output-keys database schema name resource_type -s a" && pass "…la sélection de l'utilisateur est celle qui est contrôlée" || bad "contrôle fait sur une autre sélection"
O="$(RUN v1 compile -s a)"
has "$O" "ARGS=compile -s a" && pass "lecture (compile) : aucun contrôle de destination" || bad "compile bloqué ($O)"

printf "{{ config(post_hook='truncate table x') }}\nselect 1\n" > "$WS/v1/dbt/models/hooked.sql"
O="$(RUN v1 run -s a)"; has "$O" "has hooks" && pass "projet avec hooks : écriture refusée tant que non relus" || bad "hooks non détectés ($O)"
conf "$WS" 'DBT_HOOKS_REVIEWED=1'
O="$(RUN v1 run -s a)"; has "$O" "ARGS=run -s a" && pass "…acceptée après DBT_HOOKS_REVIEWED=1" || bad "hooks relus mais écriture refusée ($O)"
rm -f "$WS/v1/dbt/models/hooked.sql"; conf "$WS"

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
cp "$STUB_DBT" "$DBT_V1_VENV/bin/dbt"; cp "$STUB_DBT" "$DBT_BIN_DIR/dbt"

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

echo "== Aucune fuite hors du bac à sable de test =="
refute "le vrai ~/.gitconfig n'a pas reçu le verrou" grep -q "git.invalid" /home/"$(id -un)"/.gitconfig
check "l'upstream n'a toujours qu'une branche" test "$(git -C "$W/upstream.git" for-each-ref refs/heads | wc -l)" = 1

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mTOUS LES CONTRÔLES PASSENT\033[0m"; else echo -e "\033[31mECHECS DETECTES\033[0m"; fi
exit "$fail"
