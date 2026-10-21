#!/usr/bin/env bash
# =============================================================================
# test-flux-mutants.sh — les témoins du flux savent-ils refuser ? (mutants)
# -----------------------------------------------------------------------------
# Pour chaque garde listée ci-dessous (lib-dbt.sh, dbt-run.sh, dbt-doctor.sh :
# le sous-espace v4 d'une copie de travail, la copie principale nommée, les
# copies orphelines, l'état du container, la liste blanche hors de l'espace v4,
# `dbt` hors de tout projet) : une copie jetable du dépôt où CETTE garde est
# retirée ou affaiblie — un « mutant » —, puis scripts/test-lib-dbt.sh sur cette
# copie. Un mutant doit faire échouer au moins un contrôle ; un mutant qui passe
# est une garde que rien ne teste.
#   - d'abord la copie non mutée : la suite doit y passer, sinon rien ne vaut ;
#   - chaque mutant remplace un texte EXACT du code, présent une seule fois :
#     un texte introuvable arrête tout (le code a changé, la liste doit suivre).
# Ce qu'il voit : les gardes de la liste, une par mutant. Ce qu'il ne voit pas :
# une garde absente de la liste ; les gardes redondantes, qu'aucun mutant seul ne
# peut tuer parce qu'une autre garde fait le même refus (elles sont nommées en
# fin de liste, sans mutant) ; ce que test-lib-dbt.sh ne simule pas (BigQuery,
# le vrai moteur dbt, l'extension dbt). « Tous tués » veut dire : chaque garde
# DE LA LISTE a un témoin qui refuse sans elle — pas que toute garde en a un.
#
# Usage :  scripts/test-flux-mutants.sh [-j N] [NOM…]   (défaut : tous, 6 à la fois)
# Sortie : une ligne par mutant (TUÉ, avec le premier contrôle tombé, ou SURVIT),
#          puis « TÉMOINS test-flux-mutants : OK (…) » — code 0 —, ou ÉCHEC — code 1.
# Hors ligne (les bouchons de test-lib-dbt.sh), ~1 min par mutant ; n'écrit que
# dans un dossier temporaire, effacé à la fin.
# Prérequis : ceux de test-lib-dbt.sh (git, bash, python3).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
J=6
if [ "${1:-}" = "-j" ]; then J="${2:?-j N}"; shift 2; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- les mutants : NOM, fichier (L lib-dbt.sh, R dbt-run.sh, D dbt-doctor.sh), texte exact, remplacement ----------
cat > "$WORK/mutants.py" <<'PY'
M = [
  # la déclaration (.devcontainer/flux.conf), lue du fichier seul
  ("conf-dbt-conf-accepte", "L", '  if [ -n "${_DBT_CONF_FLUX_SET:-}" ]; then\n    DBT_V4_FLUX=""\n', '  if false; then\n    DBT_V4_FLUX=""\n'),
  ("conf-dbt-conf-flux-retenu", "L", '    DBT_V4_FLUX=""\n    DBT_V4_FLUX_ERR="$_DBT_CONF_FLUX_SET', '    DBT_V4_FLUX_ERR="$_DBT_CONF_FLUX_SET'),
  ("conf-dbt-conf-releve-ignore", "L", '  _DBT_CONF_FLUX_SET="$(_dbt_flux_changed "$_DBT_CONF_FLUXSNAP")"\n', '  _DBT_CONF_FLUX_SET=""\n'),
  ("conf-env-exporte-masque", "L", '  DBT_V4_FLUX=""\n  unset DBT_V4_FLUX_FILE DBT_V4_FLUX_ERR\n', '  unset DBT_V4_FLUX_FILE DBT_V4_FLUX_ERR\n'),
  ("conf-syntaxe-libre", "L", "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789])$'",
                              "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([^ ]+)$'"),
  ("conf-plusieurs-lignes", "L", '  [ "$N" = 1 ] || return 1\n', '  [ "$N" -ge 1 ] || return 1\n'),
  ("conf-lien-accepte", "L", '  { [ -f "$F" ] && [ ! -L "$F" ] && [ -r "$F" ]; } || return 1\n', '  { [ -f "$F" ] && [ -r "$F" ]; } || return 1\n'),
  ("conf-lien-pendant-sans-flux", "L", '  [ -e "$F" ] || [ -L "$F" ] || return 0\n', '  [ -e "$F" ] || return 0\n'),
  ("conf-derniere-ligne-sans-LF-ignoree", "L", '  while IFS= read -r L || [ -n "$L" ]; do\n', '  while IFS= read -r L; do\n'),
  ("conf-NUL-accepte", "L", '  [ "$(tr -d \'\\000\' < "$F" | wc -c)" = "$(wc -c < "$F")" ] || return 1\n', ''),
  ("conf-locale-du-shell", "L", '  local F="${1:-}" L N=0 X="" LC_ALL=C\n', '  local F="${1:-}" L N=0 X=""\n'),
  ("conf-commentaires-refuses", "L", '    [[ "$L" =~ $_DBT_FLUX_BLANK_RE ]] && continue\n', ''),
  ("conf-hors-flotte", "L", '  if [ -n "$F" ] && ! dbt_is_fleet; then\n', '  if false; then\n'),
  ("conf-flux-dans-la-principale", "L", '  if [ -n "$F" ] && _dbt_is_main_ws; then\n', '  if false; then\n'),
  # ce qui rend une déclaration indigne de confiance
  ("git-suivi-accepte", "L", '    if git -C "$DBT_WS" ls-files --error-unmatch -- "$X" >/dev/null 2>&1; then\n', '    if false; then\n'),
  ("git-non-ignore-accepte", "L", '    elif ! git -C "$DBT_WS" check-ignore -q -- "$X" 2>/dev/null; then\n', '    elif false; then\n'),
  ("paquet-homonyme-accepte", "L", '  C="$(_dbt_flux_clash)"\n', '  C=""\n'),
  ("paquet-homonyme-sans-borne", "L", 'if (u == f || index(u, f "_") == 1) print $0', 'if (index(u, f) == 1) print $0'),
  ("paquet-homonyme-exact-accepte", "L", 'if (u == f || index(u, f "_") == 1) print $0', 'if (index(u, f "_") == 1) print $0'),
  ("garde-flux-muette", "R", '  [ -z "$PB" ] && return 0\n', '  return 0\n'),
  # le flux et sa copie principale : mêmes réglages partagés, une copie principale nommée et présente
  ("flux-principale-ignoree", "L", '  _dbt_flux_main_problem\n  return 0\n', '  return 0\n'),
  ("flux-principale-egale-toujours", "L", '  [ "$M" = "$H" ] && return 0\n', '  return 0\n'),
  ("flux-principale-absente-ok", "L", '  [ -f "$C" ] || return 1\n', '  [ -f "$C" ] || return 0\n'),
  ("flux-principale-sans-nom-ok", "L", '  case "${DBT_V4_MAIN_WS:-}" in\n    /*) ;;\n', '  case "/${DBT_V4_MAIN_WS:-}" in\n    /*) ;;\n'),
  # la copie principale nommée ; les orphelines
  ("role-orphelin-devient-principal", "L", '  elif _dbt_is_main_ws; then echo main\n  else echo orphan; fi\n', '  else echo main; fi\n'),
  ("role-flotte-sans-v4-orpheline", "L", '  elif ! _dbt_v4_declared; then return 0\n', '  elif false; then return 0\n'),
  ("principal-chemin-non-resolu", "L", 'B="$(cd "$DBT_V4_MAIN_WS" 2>/dev/null && pwd -P)" || return 1',
                                       'B="$(printf %s "$DBT_V4_MAIN_WS")" || return 1'),
  ("principal-chemin-relatif", "L", '  case "${DBT_V4_MAIN_WS:-}" in /*) ;; *) return 1 ;; esac\n', ''),
  ("role-guard-absente", "R", '  role_guard "$V" "$@"\n', ''),
  ("orphelin-v4-permis", "R", '    [ "$R" = orphan ] && orphan_refuse "\\`dbt ${1:-…}\\` under $(_dbt_show "$V")"\n', '    :\n'),
  ("orphelin-destinations-permis", "R", '  [ "$(dbt_v4_role)" != orphan ] || orphan_refuse "just destinations"\n', ''),
  ("orphelin-hooks-approve-permis", "R", '  [ "$(dbt_v4_role)" != orphan ] || orphan_refuse "just hooks-approve', '  true || orphan_refuse "just hooks-approve'),
  ("setup-orphelin-lie-la-v4", "L", '        elif [ -f "$ENVF" ] && [ -z "${DBT_V4_FLUX_ERR:-}" ] && [ "$ROLE" != orphan ]; then\n',
                                    '        elif [ -f "$ENVF" ] && [ -z "${DBT_V4_FLUX_ERR:-}" ]; then\n'),
  ("setup-orphelin-comme-principal", "L", '  if [ "$(dbt_v4_role)" = orphan ]; then\n    dbt_v4_orphan_why', '  if false; then\n    dbt_v4_orphan_why'),
  ("setup-orphelin-ancien-flux-tu", "L", '  [ -z "$V" ] || echo "this copy WAS flux $V', '  true || echo "this copy WAS flux $V'),
  # l'état du container : écrit par la copie principale seule
  ("conteneur-flux-proprietaire", "L", '  [ -z "${DBT_V4_FLUX:-}${DBT_V4_FLUX_ERR:-}" ] || return 1\n  [ -n "${DBT_V4_MAIN_WS:-}" ] || return 0\n',
                                       '  [ -n "${DBT_V4_MAIN_WS:-}" ] || return 0\n'),
  ("conteneur-orphelin-proprietaire", "L", '  [ -n "${DBT_V4_MAIN_WS:-}" ] || return 0\n  _dbt_is_main_ws\n}\n', '  return 0\n}\n'),
  ("bashrc-par-une-autre-copie", "L", '  if ! _dbt_owns_container; then\n    echo "  ~/.bashrc', '  if false; then\n    echo "  ~/.bashrc'),
  ("moteurs-par-une-autre-copie", "L", '  if _dbt_owns_container; then\n    echo "[dbt] engine v1', '  if true; then\n    echo "[dbt] engine v1'),
  ("moteurs-oncreate-par-une-autre-copie", "L", '  if ! _dbt_owns_container; then\n    echo "[dbt] engines:', '  if false; then\n    echo "[dbt] engines:'),
  ("moteurs-epingle-muette", "L", '      echo "  WARNING: this copy pins', '      true "  WARNING: this copy pins'),
  ("git-invite-sshcommand", "L", '  if [ "$OWN" = 0 ]; then\n    echo "  the container\'s git settings', '  if false; then\n    echo "  the container\'s git settings'),
  ("git-invite-insteadof", "L", '    if [ "$OWN" = 0 ]; then\n      :\n', '    if false; then\n      :\n'),
  ("git-invite-leve-le-verrou", "L", '    if [ "${DBT_UPSTREAM_PUSH_LOCK:-1}" != "0" ] || [ "$OWN" = 0 ]; then\n',
                                     '    if [ "${DBT_UPSTREAM_PUSH_LOCK:-1}" != "0" ]; then\n'),
  ("pushurl-invite-leve", "L", '    if [ "${DBT_UPSTREAM_PUSH_LOCK:-1}" != "0" ] || ! _dbt_owns_container; then\n',
                               '    if [ "${DBT_UPSTREAM_PUSH_LOCK:-1}" != "0" ]; then\n'),
  ("bigqueryrc-par-une-autre-copie", "L", '  if [ ! -f "${HOME:-}/.bigqueryrc" ] && _dbt_owns_container; then\n', '  if [ ! -f "${HOME:-}/.bigqueryrc" ]; then\n'),
  # les espaces
  ("prefixe-v4-forme-de-flux", "L", '    [[ "$(_dbt_upper "$X")" =~ $DBT_V4_FLUX_RE ]] && return 1\n', '    :\n'),
  ("prefixe-v4-forme-de-flux-casse", "L", '    [[ "$(_dbt_upper "$X")" =~ $DBT_V4_FLUX_RE ]] && return 1\n', '    [[ "$X" =~ $DBT_V4_FLUX_RE ]] && return 1\n'),
  ("env-du-flux-ignore", "L", 'dbt_v4_env_file() { printf \'%s\' "$DBT_WS/profiles/v4${DBT_V4_FLUX:+-$DBT_V4_FLUX}.env"; }',
                              'dbt_v4_env_file() { printf \'%s\' "$DBT_WS/profiles/v4.env"; }'),
  ("ecrit-espace-principal-depuis-flux", "R", 'function here(s) { if (fx != "") return exact(s, qx "_" fx);', 'function here(s) { if (fx != "") return exact(s, qx);'),
  ("principal-ecrit-un-flux", "R", 'return exact(s, qx) && !fluxlike(s) }', 'return exact(s, qx) }'),
  ("forme-de-flux-sans-borne", "R", 'return r ~ /^[A-Z][0-9][0-9][0-9]$/ || r ~ /^[A-Z][0-9][0-9][0-9]_/ }', 'return r ~ /^[A-Z][0-9][0-9][0-9]/ }'),
  ("flux-accepte-sans-casse", "R", 'if (fx != "") return exact(s, qx "_" fx);', 'if (fx != "") return anycase(s, qx "_" fx);'),
  ("principal-accepte-sans-casse", "R", 'return exact(s, qx) && !fluxlike(s) }', 'return anycase(s, qx) && !fluxlike(s) }'),
  ("v2-refuse-en-casse-exacte", "R", '(!v4 && qx!="" && anycase($3,qx))', '(!v4 && qx!="" && exact($3,qx))'),
  ("prefixe-principal-dans-flux", "R", '    [ "${DATASET_PREFIX:-}" = "$X" ] \\\n', '    [ "${DATASET_PREFIX:-}" = "$X" ] || [ "${DATASET_PREFIX:-}" = "$DBT_BQ_DATASET_PREFIX_V4" ] \\\n'),
  ("env-v4-principal-dans-flux", "R", '    [ -z "$P" ] || [ "$L" = "$(readlink -f "$E4")" ] \\\n', '    [ -z "$P" ] || [ "$L" = "$(readlink -f "$E4")" ] || _dbt_is_v4_env "$L" \\\n'),
  ("env-flux-lu-par-v2", "R", '    [ -z "$P" ] || [ -z "$L" ] || ! _dbt_is_v4_env "$L" \\\n', '    [ -z "$P" ] || [ -z "$L" ] || [ "$L" != "$(readlink -f "$WS/profiles/v4.env")" ] \\\n'),
  ("export-env-principal", "R", '    BASE="$(dbt_v4_env_file)"\n', '    BASE="$WS/profiles/v4.env"\n'),
  ("destinations-prefixe-principal", "R", '    "$(dbt_v4_prefix)" <<\'PY\'\n', '    "${DBT_BQ_DATASET_PREFIX_V4:-}" <<\'PY\'\n'),
  # v1/v2/global hors de la copie principale : une liste blanche
  ("liste-blanche-absente", "R", '  dbt_read_only_args "$@" && return 0\n', '  return 0\n'),
  ("liste-blanche-premier-mot-libre", "L", '  case " $DBT_FLUX_READ_CMDS " in *" $C0 "*) ;; *) return 1 ;; esac\n', ''),
  ("liste-blanche-premier-mot-a-espace", "L", '  case "$C0" in ""|*[!a-z-]*) return 1 ;; esac\n', ''),
  ("liste-blanche-mots-libres", "L", '    case " $DBT_KNOWN_CMDS " in *" $A "*) case " $DBT_FLUX_READ_CMDS " in *" $A "*) ;; *) return 1 ;; esac ;; esac\n', ''),
  ("check-hors-liste-v2", "L", '    v1) printf \'%s\' "run build seed snapshot test freshness retry" ;;\n    *)',
                               '    v1) printf \'%s\' "run build seed snapshot test freshness retry" ;;\n    v2|global) printf \'%s\' "run build seed snapshot test freshness retry clone compile show docs" ;;\n    *)'),
  ("hooks-approve-dans-flux", "R", '  [ -z "${DBT_V4_FLUX:-}" ] \\\n    || die "flux $DBT_V4_FLUX: the approved hooks', '  true \\\n    || die "flux $DBT_V4_FLUX: the approved hooks'),
  ("destinations-sans-garde-de-flux", "R", '  local N RC=0\n  flux_guard\n', '  local N RC=0\n'),
  ("hooks-approve-sans-garde-de-flux", "R", '  flux_guard\n  [ -z "${DBT_V4_FLUX:-}" ] \\\n', '  [ -z "${DBT_V4_FLUX:-}" ] \\\n'),
  # `dbt` hors de l'espace de travail, hors de tout projet
  ("dbt-brut-dans-une-copie", "R", '      if [ -n "$L" ] && [ -f "$UP/.devcontainer/dbt-run.sh" ] && [ -f "$UP/.devcontainer/lib-dbt.sh" ]; then\n', '      if false; then\n'),
  ("dbt-brut-copie-par-un-lien", "R", '  for D in "$PWD" "$(pwd -P)"; do\n', '  for D in "$PWD"; do\n'),
  ("dbt-lien-dans-l-espace", "R", 'cd "$WS${CP#"$WSP"}" 2>/dev/null || die "cannot enter $WS${CP#"$WSP"}"', ':'),
  ("dbt-brut-project-dir", "R", '      --project-dir|--project-dir=*|--profiles-dir|--profiles-dir=*|--packages-install-path|--packages-install-path=*)\n        die "\\`dbt … ${A%%=*}\\` refused outside',
                                '      --jamais)\n        die "\\`dbt … ${A%%=*}\\` refused outside'),
  ("dbt-brut-DBT_PROJECT_DIR", "R", '  [ -z "${DBT_PROJECT_DIR:-}" ] \\\n    || die "DBT_PROJECT_DIR is set (\'$DBT_PROJECT_DIR\'): plain dbt v2',
                                    '  true \\\n    || die "DBT_PROJECT_DIR is set (\'$DBT_PROJECT_DIR\'): plain dbt v2'),
  ("dbt-brut-DBT_PACKAGES_INSTALL_PATH", "R", '  [ -z "${DBT_PACKAGES_INSTALL_PATH:-}" ] \\\n    || die "DBT_PACKAGES_INSTALL_PATH is set (\'$DBT_PACKAGES_INSTALL_PATH\'): plain dbt v2',
                                              '  true \\\n    || die "DBT_PACKAGES_INSTALL_PATH is set (\'$DBT_PACKAGES_INSTALL_PATH\'): plain dbt v2'),
  ("dbt-brut-hors-projet-tout-permis", "R", '  if [ -z "$INPROJ" ]; then\n', '  if false; then\n'),
  # le cycle de vie
  ("setup-env-du-flux-principal", "L", '    _dbt_v4_env_render "$DBT_V4_FLUX" > "$TMP"\n', '    _dbt_v4_env_render > "$TMP"\n'),
  ("setup-global-v4-principal", "L", '  [ -f "$DBT_WS/global-v4/dbt_project.yml" ] && _dbt_link_env "$DBT_WS/global-v4" "$E" fix\n',
                                     '  [ -f "$DBT_WS/global-v4/dbt_project.yml" ] && _dbt_link_env "$DBT_WS/global-v4" "$DST" fix\n'),
  ("setup-env-v4-principal", "L", '      ENVF="$P_ENV"; [ "$V" = v4 ] && ENVF="$(dbt_v4_env_file)"\n', '      ENVF="$P_ENV"; [ "$V" = v4 ] && ENVF="$DBT_WS/profiles/v4.env"\n'),
  ("setup-lien-garde-sous-refus", "L", '        elif [ -f "$ENVF" ] && [ -z "${DBT_V4_FLUX_ERR:-}" ] && [ "$ROLE" != orphan ]; then\n',
                                       '        elif [ -f "$ENVF" ] && [ "$ROLE" != orphan ]; then\n'),
  ("setup-global-v4-garde-sous-refus", "L", '    echo "  WARNING: flux — $DBT_V4_FLUX_ERR: every dbt command is refused, and no .env of the v4 space is linked"\n    [ -L "$DBT_WS/global-v4/.env" ] && rm -f "$DBT_WS/global-v4/.env"\n',
                                            '    echo "  WARNING: flux — $DBT_V4_FLUX_ERR: every dbt command is refused, and no .env of the v4 space is linked"\n'),
  ("setup-muet-sur-un-flux-indigne", "L", '    [ -z "$PB" ] || printf \'%s\\n\' "$PB" | sed "s/^/  WARNING: flux $DBT_V4_FLUX — /; s/\\$/ (every dbt command is refused until then)/"\n', '    :\n'),
  # la preuve des hooks de global-v4
  ("sceau-sans-flux", "L", '  [ -z "$F" ] || E4="profiles/v4-$F.env"\n', '  :\n'),
  ("verdict-sans-flux", "L", '  if [ -n "${3:-}" ]; then [[ "$3" =~ $DBT_V4_FLUX_RE ]] || return 1; X="GLOBAL-V4 FLUX $3"; fi\n', '  :\n'),
  ("verdict-motif-libre", "L", '[[ "$3" =~ $DBT_V4_FLUX_RE ]] || return 1; X=', 'X='),
  ("garde-fou-verdict-sans-flux", "R", '  dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S" "${DBT_V4_FLUX:-}" \\\n', '  dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S" \\\n'),
  # le doctor
  ("doctor-flux-muet", "D", '  FPB="$(dbt_v4_flux_problem)"\n', '  FPB=""\n'),
  ("doctor-verdict-sans-flux", "D", '        elif dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S" "${DBT_V4_FLUX:-}"; then\n',
                                    '        elif dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S"; then\n'),
  ("doctor-orpheline-muette", "D", '    orphan) while IFS= read -r L; do\n', '    orphan-jamais) while IFS= read -r L; do\n'),
  ("doctor-role-flux-muet", "D", '    flux)   ok "this copy is flux', '    flux-jamais)   ok "this copy is flux'),
]
# Gardes redondantes, sans mutant (un mutant seul ne peut pas les tuer, une autre garde fait le même refus) :
#   - [ -r "$F" ] dans _dbt_flux_parse : un fichier illisible ne se lit pas non plus (read échoue, 0 déclaration) ;
#   - la classe explicite _DBT_FLUX_BLANK_RE : sous LC_ALL=C (conf-locale-du-shell), [[:space:]] est la même ;
#   - safe.directory, ajouté (jamais retiré) par une copie de flux pour ses propres worktrees : pas une garde.
PY
python3 - "$WORK" "$REPO_ROOT" "$@" <<'PY'
import sys
work, root, only = sys.argv[1], sys.argv[2], sys.argv[3:]
exec(open(f"{work}/mutants.py", encoding="utf-8").read())
F = {k: f"{root}/template/.devcontainer/{{% if dbt_workspace %}}{n}{{% endif %}}" for k, n in
     (("L", "lib-dbt.sh"), ("R", "dbt-run.sh"), ("D", "dbt-doctor.sh"))}
noms = [m[0] for m in M]
assert len(set(noms)) == len(noms), "deux mutants du même nom"
bad = [n for n in only if n not in noms]
if bad:
    sys.exit(f"mutant inconnu : {' '.join(bad)} — connus : {' '.join(noms)}")
for nom, f, old, new in M:
    n = open(F[f], encoding="utf-8").read().count(old)
    if n != 1:
        sys.exit(f"⛔ mutant {nom} : texte trouvé {n} fois dans {F[f].rsplit('/', 1)[1]} (il faut 1) — le code a changé, la liste doit suivre")
    if old == new:
        sys.exit(f"⛔ mutant {nom} : le remplacement est le texte lui-même")
with open(f"{work}/noms", "w") as o:
    o.write("\n".join(n for n in noms if not only or n in only) + "\n")
PY
[ $? -eq 0 ] || exit 1

# --- la copie non mutée d'abord ------------------------------------------------------------------------------------
cp -a "$REPO_ROOT" "$WORK/base"
if ! bash "$WORK/base/scripts/test-lib-dbt.sh" > "$WORK/base.log" 2>&1; then
  echo "⛔ la suite échoue sans mutant : rien ne peut être conclu"; grep FAIL "$WORK/base.log" | head -5
  echo "TÉMOINS test-flux-mutants : ÉCHEC"; exit 1
fi
echo "copie non mutée : $(sed 's/\x1b\[[0-9;]*m//g' "$WORK/base.log" | grep -c '^  OK ') contrôle(s), tous passent"

# --- un mutant par copie, J à la fois ------------------------------------------------------------------------------
muter() {   # muter NOM — la copie, la mutation, la suite ; écrit $WORK/NOM.rc et $WORK/NOM.log
  local N="$1"
  cp -a "$WORK/base" "$WORK/m-$N"
  python3 - "$WORK" "$WORK/m-$N" "$N" <<'PY'
import sys
work, root, nom = sys.argv[1:4]
exec(open(f"{work}/mutants.py", encoding="utf-8").read())
F = {k: f"{root}/template/.devcontainer/{{% if dbt_workspace %}}{n}{{% endif %}}" for k, n in
     (("L", "lib-dbt.sh"), ("R", "dbt-run.sh"), ("D", "dbt-doctor.sh"))}
(_, f, old, new), = [m for m in M if m[0] == nom]
s = open(F[f], encoding="utf-8").read()
assert s.count(old) == 1
open(F[f], "w", encoding="utf-8").write(s.replace(old, new))
PY
  bash "$WORK/m-$N/scripts/test-lib-dbt.sh" > "$WORK/$N.log" 2>&1
  echo $? > "$WORK/$N.rc"
  rm -rf "$WORK/m-$N"
}
export -f muter; export WORK
xargs -a "$WORK/noms" -P "$J" -I{} bash -c 'muter "$1"' _ {}

TUES=0; SURV=0
while IFS= read -r N; do
  [ -n "$N" ] || continue
  FIRST="$(grep -m1 FAIL "$WORK/$N.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/^ *FAIL *//' | cut -c1-110)"
  if [ "$(cat "$WORK/$N.rc" 2>/dev/null)" != 0 ] && [ -n "$FIRST" ]; then
    TUES=$((TUES + 1)); printf '  TUÉ    %-40s %s (%s contrôle(s) tombé(s))\n' "$N" "$FIRST" "$(grep -c FAIL "$WORK/$N.log")"
  else
    SURV=$((SURV + 1)); printf '  SURVIT %-40s aucun contrôle ne tombe : cette garde n\x27est pas testée\n' "$N"
  fi
done < "$WORK/noms"
echo
if [ "$SURV" = 0 ] && [ "$TUES" -gt 0 ]; then
  echo "TÉMOINS test-flux-mutants : OK ($TUES mutant(s) de la liste, tous tués)"
else
  echo "TÉMOINS test-flux-mutants : ÉCHEC ($SURV mutant(s) survivant(s) sur $((TUES + SURV)))"; exit 1
fi
