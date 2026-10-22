#!/usr/bin/env bash
# =============================================================================
# test-flux-mutants.sh — les témoins du flux savent-ils refuser ? (mutants)
# -----------------------------------------------------------------------------
# Pour chaque garde listée ci-dessous (lib-dbt.sh, dbt-run.sh, dbt-doctor.sh :
# le sous-espace v4 d'une copie de travail, la copie principale nommée, les
# copies orphelines, l'état du container, la liste blanche hors de l'espace v4,
# aucun hook hors de l'espace v4 d'une copie qui n'est pas la principale, les
# réglages du garde-fou au moins aussi stricts que ceux de la copie principale,
# la preuve d'un flux dans son propre fichier, la ligne harmonisée dans git — ses
# branches v4-h (une copie v4 qui n'est pas un worktree comprise), sa garde de push
# (main, master, la branche par défaut du remote, une redescente hors de la v4
# publiée, git-lfs), son verrou products-h.lock, clone/state/--state/--defer/
# --manage-state refusés, de la ligne de commande, de l'environnement et des
# fichiers de réglages —, un flux qui est un clone, le verrou refusé dans une
# copie orpheline, les extensions dbt coupées hors de l'espace d'une copie
# invitée, les paquets d'une copie invitée lus par un lecteur strict et installés
# tels que verrouillés, `dbt` hors de tout projet ; le contrôle n° 3 : toute branche
# ni supprimée ni réécrite depuis la copie H, une autre génération jamais poussée,
# product-new/product-add/referent-add et le miroir à la copie principale seule,
# dbt login/init/system aussi, --target-path/--log-path jamais dans une autre copie,
# une copie v4 racine d'un autre dépôt refusée, une orpheline sans copie v4, la
# branche de ligne créée pour une copie déjà là, dbt_cloud.yml et les formes YAML
# non lues refusées, le report de l'extension éteint et h.code-workspace dans la
# ligne H) : une copie jetable du dépôt où CETTE garde est
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

# --- les mutants : NOM, fichier (L lib-dbt.sh, R dbt-run.sh, D dbt-doctor.sh, G git-push-garde-h.sh), texte exact, remplacement
cat > "$WORK/mutants.py" <<'PY'
M = [
  # la déclaration (.devcontainer/flux.conf), lue du fichier seul
  ("conf-dbt-conf-accepte", "L", '  if [ -n "${_DBT_CONF_FLUX_SET:-}" ]; then\n    DBT_V4_FLUX=""\n', '  if false; then\n    DBT_V4_FLUX=""\n'),
  ("conf-dbt-conf-flux-retenu", "L", '    DBT_V4_FLUX=""\n    DBT_V4_FLUX_ERR="$_DBT_CONF_FLUX_SET', '    DBT_V4_FLUX_ERR="$_DBT_CONF_FLUX_SET'),
  ("conf-dbt-conf-releve-ignore", "L", '  _DBT_CONF_FLUX_SET="$(_dbt_flux_changed "$_DBT_CONF_FLUXSNAP")"\n', '  _DBT_CONF_FLUX_SET=""\n'),
  ("conf-env-exporte-masque", "L", '  DBT_V4_FLUX=""\n  unset DBT_V4_FLUX_FILE DBT_V4_FLUX_ERR\n', '  unset DBT_V4_FLUX_FILE DBT_V4_FLUX_ERR\n'),
  ("conf-syntaxe-libre", "L", "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789]|H)$'",
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
  ("flux-principale-egale-toujours", "L", '  if [ "$M" != "$H" ]; then\n    diff', '  if false; then\n    diff'),
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
  # le verrou 4 dans une copie qui ne possède pas le container : ajouté, jamais levé ni réécrit (dbt_git_setup)
  ("verrou4-invite-garde-ssh-absente", "L", '  if [ "$OWN" = 0 ]; then _dbt_push_lock_ssh_guest $ALL_HOSTS\n', '  if [ "$OWN" = 0 ]; then :\n'),
  ("verrou4-invite-reecrit-sshcommand", "L", '  if [ "$OWN" = 0 ]; then _dbt_push_lock_ssh_guest $ALL_HOSTS\n', '  if [ "$OWN" = 0 ]; then _dbt_push_lock_ssh 1 $ALL_HOSTS\n'),
  ("verrou4-invite-remplace-la-garde", "L", '      if [ ! -f "$G" ] && ! _dbt_ssh_guard_install; then\n', '      if ! _dbt_ssh_guard_install; then\n'),
  ("verrou4-invite-cles-du-flux", "L", '    case "$CUR" in "ssh "*) CMD="$CMD ${CUR#ssh }" ;; esac\n', '    CMD="$CMD -o \\"UserKnownHostsFile=$(_dbt_known_hosts) $HOME/.ssh/known_hosts\\""\n'),
  ("verrou4-invite-hotes-perdus", "L", '    CMD="${CUR/"$OLD"/--hosts=${H// /,}}"\n', '    CMD="bash $Q --hosts=${MISS// /,}"\n'),
  ("verrou4-invite-https-selon-sa-conf", "L", '         || { [ "$OWN" = 0 ] && _dbt_container_https_over_ssh "$HOST"; }; then\n',
                                              '         || { [ "$OWN" = 0 ] && _dbt_https_read_over_ssh "$HOST" "$SSH_HOSTS"; }; then\n'),
  ("verrou4-invite-leve-https", "L", '      elif [ "$OWN" = 0 ]; then\n        # the container reads', '      elif false; then\n        # the container reads'),
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
  # la ligne harmonisée : le flux H, son espace <…_V4>_H, que la ligne ISO (la copie principale) n'écrit jamais
  ("ligne-h-refusee", "L", "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789]|H)$'",
                           "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789])$'"),
  ("ligne-h-toute-lettre", "L", "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789]|H)$'",
                                "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789]|[ABCDEFGHIJKLMNOPQRSTUVWXYZ])$'"),
  ("ligne-h-hors-forme-de-flux", "L", "  DBT_V4_FLUX_RE='^([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789]|H)$'\n",
                                      "  DBT_V4_FLUX_RE='^([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789])$'\n"),
  ("ligne-h-vestige-tu", "L", "s/^v4-([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789]{3}|H)\\.env$/\\1/p", "s/^v4-([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789]{3})\\.env$/\\1/p"),
  ("iso-ecrit-la-ligne-h", "R", 'if (r == "H" || index(r, "H_") == 1) return 1', 'if (0) return 1'),
  ("iso-ligne-h-sans-borne", "R", 'if (r == "H" || index(r, "H_") == 1) return 1', 'if (index(r, "H") == 1) return 1'),
  ("iso-ligne-h-exacte-seule", "R", 'if (r == "H" || index(r, "H_") == 1) return 1', 'if (r == "H") return 1'),
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
  ("garde-fou-verdict-sans-flux", "R", '  dbt_hooks_v4_verdict "$WS/$PF" "$S" "${DBT_V4_FLUX:-}" \\\n', '  dbt_hooks_v4_verdict "$WS/$PF" "$S" \\\n'),
  # les réglages du garde-fou (verrou 3) : au moins aussi stricts dans un flux que dans sa copie principale
  ("strict-ignore", "L", '  _dbt_flux_strict_problem "$DBT_V4_MAIN_WS"\n}\n', '}\n'),
  ("strict-never-build-plus-permissif", "L", '    [ -z "$X" ] || echo "DBT_SANDBOX_NEVER_BUILD here lacks', '    true || echo "DBT_SANDBOX_NEVER_BUILD here lacks'),
  ("strict-compile-ok-plus-permissif", "L", '    [ -z "$X" ] || echo "DBT_HOOKS_COMPILE_OK here names', '    true || echo "DBT_HOOKS_COMPILE_OK here names'),
  ("strict-ouvertures-plus-permissives", "L", '    [ "${!W:-0}" = 1 ] && [ "$M" != 1 ] \\\n', '    false && [ "$M" != 1 ] \\\n'),
  ("strict-defauts-herites-du-flux", "L", '    DBT_SANDBOX_NEVER_BUILD=""; DBT_HOOKS_COMPILE_OK=""; DBT_HOOKS_REVIEWED=0; DBT_HOOKS_REVIEWED_V2=0\n    DBT_ALLOW_RUN_OPERATION=0\n', ''),
  # aucun hook dans les espaces de la copie principale (v1/v2/global) depuis une copie qui ne l'est pas
  ("invite-hooks-ouverts", "R", '  if [ -n "$CMD_HOOKS$CMD_WRITE" ] && guest_space "$V"; then\n    guest_hooks_guard "$V"\n  elif',
                                '  if false; then\n    guest_hooks_guard "$V"\n  elif'),
  ("invite-hooks-orphelin-ouvert", "R", '  case "$(dbt_v4_role)" in flux|orphan) return 0 ;; esac\n  return 1\n}\n', '  case "$(dbt_v4_role)" in flux) return 0 ;; esac\n  return 1\n}\n'),
  ("invite-hooks-v4-aussi", "R", '  dbt_is_v4 "${1:-}" && return 1\n  case "$(dbt_v4_role)" in flux|orphan) return 0 ;; esac\n',
                                 '  case "$(dbt_v4_role)" in flux|orphan) return 0 ;; esac\n'),
  ("invite-hooks-liens-non-lus", "R", '  H="$(dbt_hook_sources_deep "$PROJ")"\n', '  H="$(dbt_hook_sources "$PROJ")"\n'),
  ("invite-hooks-paquets-non-installes", "R", '  dbt_packages_unchecked "$PROJ" \\\n    && refuse "$WHO:', '  false \\\n    && refuse "$WHO:'),
  ("invite-hooks-lien-pendant-ignore", "L", '      printf \'%s\\n\' "${L#"$PROJ"/} (a link to no directory: its hooks cannot be read)"; continue\n', '      continue\n'),
  ("doctor-invite-paquets-muet", "D", '    [ -z "$PK" ] || info "$(label "$V"): compile/show refused in this copy', '    true || info "$(label "$V"): compile/show refused in this copy'),
  ("doctor-invite-hooks-comme-principal", "D", '  if ! dbt_is_v4 "$V" && case "$(dbt_v4_role)" in flux|orphan) true ;; *) false ;; esac; then\n',
                                               '  if false; then\n'),
  # la preuve des hooks de global-v4 d'un flux : un fichier à lui
  ("preuve-fichier-commun", "L", '  if [ -z "$P" ] || [ -z "$F" ]; then printf \'%s\' "$P"; return 0; fi\n', '  printf \'%s\' "$P"; return 0\n'),
  ("preuve-garde-fou-fichier-principal", "R", '  PF="$(dbt_hooks_v4_proof_path)"\n', '  PF="$DBT_HOOKS_V4_PROOF"\n'),
  ("preuve-doctor-fichier-principal", "D", '        elif dbt_hooks_v4_verdict "$WS/$(dbt_hooks_v4_proof_path)" "$S" "${DBT_V4_FLUX:-}"; then\n',
                                           '        elif dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S" "${DBT_V4_FLUX:-}"; then\n'),
  # la ligne harmonisée séparée de la ligne ISO dans git aussi — dit ; un flux <A999> ne l'est que dans BigQuery — dit
  ("ligne-h-git-doctor-muet", "D", '              info "flux H, in git: its v4 copies follow', '              true "flux H, in git: its v4 copies follow'),
  ("ligne-h-garde-doctor-muette", "D", '                || ok "flux H: its push guard runs on every push', '                || true "flux H: its push guard runs on every push'),
  ("ligne-h-git-setup-muet", "L", '             [ "$DBT_V4_FLUX" != H ] || echo "[dbt] flux H, in git:', '             true || echo "[dbt] flux H, in git:'),
  ("flux-git-partage-doctor-muet", "D", '              info "git is shared: this copy', '              true "git is shared: this copy'),
  # aucun hook depuis une copie invitée : ses paquets tous installés (dbt v2 installerait le reste au compile)
  ("invite-paquets-incomplets-admis", "R", '  PK="$(_dbt_packages_guest_problem "$PROJ")"\n', '  PK=""\n'),
  ("invite-paquets-lecteur-en-echec-admis", "L", '  if [ "$RC" != 0 ]; then echo "its packages cannot be read', '  if false; then echo "its packages cannot be read'),
  ("invite-paquets-liste-en-ligne-admise", "L", '                if v not in ("", "[]"):\n', '                if False:\n'),
  ("invite-paquets-sans-verrou-tu", "L", '    if lock is None:\n        print(f"{src[0]} declares packages and there is no package-lock.yml', '    if False:\n        print(f"{src[0]} declares packages and there is no package-lock.yml'),
  ("invite-paquets-empreinte-ignoree", "L", '        if lock.get("sha1_hash") != h:\n', '        if False:\n'),
  ("invite-paquets-declare-hors-verrou-admis", "L", '            if not any(le.get(k) == e[k] for le in locked):\n', '            if False:\n'),
  ("invite-paquets-verrou-non-installe-admis", "L", '    elif not os.path.isdir(os.path.join(proj, "dbt_packages", nm)):\n', '    elif False:\n'),
  ("invite-paquets-entree-sans-cle-admise", "L", '                if len([i for i in ID if i in e]) != 1:\n', '                if False:\n'),
  ("invite-paquets-deux-fichiers-admis", "L", '    if len(src) > 1:\n', '    if False:\n'),
  ("invite-paquets-cle-inconnue-admise", "L", '        if k not in KEYS or k in cur or not (v or "").strip():\n', '        if k in cur or not (v or "").strip():\n'),
  ("invite-paquets-ancre-admise", "L", '    if not v or v[0] in "[]{}&*!|>%@`,#?:-" or re.search(r":(\\s|$)", v):\n', '    if not v:\n'),
  ("invite-paquets-tabulation-admise", "L", '        if "\\t" in line or "\\r" in line:\n', '        if False:\n'),
  ("invite-paquets-utf8-admis", "L", '    except UnicodeDecodeError:\n        raise Unread(f"{name}: not UTF-8")\n', '    except UnicodeDecodeError:\n        text = ""\n'),
  ("invite-paquets-cle-double-admise", "L", '        if k not in KEYS or k in cur or not (v or "").strip():\n', '        if k not in KEYS or not (v or "").strip():\n'),
  ("invite-paquets-valeur-vide-admise", "L", '        if k not in KEYS or k in cur or not (v or "").strip():\n', '        if k not in KEYS or k in cur:\n'),
  ("invite-paquets-guillemet-admis", "L", '        if len(v) < 2 or v[-1] != q or q in v[1:-1] or (q == \'"\' and "\\\\" in v):\n', '        if False:\n'),
  ("invite-paquets-booleen-libre", "L", '        if v not in ("true", "false"):\n', '        if False:\n'),
  ("invite-paquets-liste-de-versions-non-lue", "L", '    if key == "version" and v.startswith("[")', '    if False and v.startswith("[")'),
  ("invite-paquets-marqueur-admis", "L", '        if line in ("---", "...") or line.startswith(("--- ", "... ")):\n', '        if False:\n'),
  # la ligne harmonisée dans git : ses branches, <p>/v4-h (v4-h là où vivent les branches du produit)
  ("ligne-h-branche-v4-commune", "L", '  _dbt_is_line_h && H4="-h"\n', '  :\n'),
  ("ligne-h-branche-referent", "L", 'P_HB4="v4$H4"; P_B4="$N/v4$H4"; P_WT4=', 'P_HB4="v4"; P_B4="$N/v4"; P_WT4='),
  ("ligne-h-branche-locale-produit", "L", 'P_B2="$N/v2"; P_B4="$N/v4$H4"\n', 'P_B2="$N/v2"; P_B4="$N/v4"\n'),
  ("ligne-h-branche-dans-son-depot", "L", 'P_HB2="v2"; P_HB4="v4$H4"; P_MIRROR=', 'P_HB2="v2"; P_HB4="v4"; P_MIRROR='),
  ("ligne-h-branche-sur-origin", "L", 'P_HB4="$N/v4$H4"; P_MIRROR="$N/upstream"', 'P_HB4="$N/v4"; P_MIRROR="$N/upstream"'),
  ("ligne-h-ouverture-tue", "L", "    if _dbt_is_line_h; then\n      # the harmonized line's branch is opened where", "    if false; then\n      # the harmonized line's branch is opened where"),
  ("ligne-h-setup-copie-hors-ligne-tue", "L", '        dbt_v4_line_h_branch_problem | while IFS= read -r X; do\n          echo "  WARNING: ${P_TAG}$X', '        true || dbt_v4_line_h_branch_problem | while IFS= read -r X; do\n          echo "  WARNING: ${P_TAG}$X'),
  ("ligne-h-sync-avance-une-autre-branche", "L", 'if _dbt_is_line_h && [ "$(git -C "$W" symbolic-ref -q --short HEAD 2>/dev/null)" != "$B" ]; then', 'if false; then'),
  ("ligne-h-sync-v4-iso-non-suivie", "L", '    if _dbt_is_line_h && dbt_v4_enabled; then EX="$EX|${P_HB4%-h}"; fi\n', ''),
  ("ligne-h-verrou-commun", "L", '  if _dbt_is_line_h; then DBT_LOCK_FILE="$DBT_WS/.devcontainer/products-h.lock"; fi\n', ''),
  ("ligne-h-verrou-message-commun", "R", 'LOCKN="$(basename "$DBT_LOCK_FILE")"\n\ndie()', 'LOCKN=products.lock\n\ndie()'),
  ("ligne-h-verrou-doctor-nom-commun", "D", '  LOCKN="$(basename "$DBT_LOCK_FILE")"\n  echo "[lock', '  LOCKN=products.lock\n  echo "[lock'),
  # une copie v4/<p> qui n'est pas sur <p>/v4-h : refusée
  ("ligne-h-copie-v4-jamais-verifiee", "L", '  _dbt_is_line_h && dbt_v4_enabled || return 0\n  W="$(_dbt_wt v4)"', '  return 0\n  W="$(_dbt_wt v4)"'),
  ("ligne-h-copie-detachee-toujours-admise", "L", '    [ -n "$C" ] && _dbt_has_ref "refs/heads/$P_B4" && git -C "$W" merge-base --is-ancestor "$C" "refs/heads/$P_B4" 2>/dev/null && return 0\n', '    return 0\n'),
  ("ligne-h-copie-sur-une-autre-branche", "L", '  if [ "$B" != "$P_B4" ]; then\n    echo "$(_dbt_show v4) is on $B', '  if false; then\n    echo "$(_dbt_show v4) is on $B'),
  ("ligne-h-suivi-non-verifie", "L", '  [ "$U" = "$P_HOME/$P_HB4" ] \\\n    || echo "$P_B4 tracks', '  true \\\n    || echo "$P_B4 tracks'),
  ("ligne-h-garde-de-branche-absente", "R", '  role_guard "$V" "$@"\n  line_h_guard "$V"\n', '  role_guard "$V" "$@"\n'),
  ("ligne-h-garde-de-branche-sans-global-v4", "R", '    global-v4) PB="$(for N in $(dbt_members); do', '    global-v4-jamais) PB="$(for N in $(dbt_members); do'),
  ("ligne-h-destinations-sans-garde-de-branche", "R", '  ! dbt_v4_enabled || line_h_guard v4\n', ''),
  ("ligne-h-destinations-global-v4-sans-garde", "R", '  case "${1:-}" in global) ;; ""|global-v4) line_h_guard global-v4 ;; esac\n', ''),
  # sa garde de push : posée, vérifiée, jamais contournée en silence
  ("ligne-h-garde-jamais-posee", "L", '  _dbt_is_line_h || return 0\n  S="$(_dbt_push_guard_h_src)"\n', '  return 0\n  S="$(_dbt_push_guard_h_src)"\n'),
  ("ligne-h-garde-posee-non-executable", "L", '  mkdir -p "$(dirname "$D")" && cat "$S" > "$D" && chmod 755 "$D"', '  mkdir -p "$(dirname "$D")" && cat "$S" > "$D"'),
  ("ligne-h-garde-ecrase-un-autre-hook", "L", '    elif [ -L "$D" ] || [ ! -f "$D" ] || ! grep -qF "$_DBT_PUSH_GUARD_H_MARK" "$D"; then\n', '    elif false; then\n'),
  ("ligne-h-garde-lfs-non-reconnu", "L", '    if [ -f "$D" ] && [ ! -L "$D" ] && cmp -s "$D" <(_dbt_lfs_pre_push_hook); then\n', '    if false; then\n'),
  ("ligne-h-garde-jamais-verifiee", "L", '  [ "$F" != H ] || _dbt_push_guard_h_problem\n', ''),
  ("ligne-h-garde-retouchee-admise", "L", '  { [ -f "$D" ] && [ ! -L "$D" ] && [ -x "$D" ] && cmp -s "$S" "$D"; } \\\n', '  { [ -f "$D" ] && [ ! -L "$D" ] && [ -x "$D" ]; } \\\n'),
  ("ligne-h-garde-non-executable-admise", "L", '  { [ -f "$D" ] && [ ! -L "$D" ] && [ -x "$D" ] && cmp -s "$S" "$D"; } \\\n', '  { [ -f "$D" ] && [ ! -L "$D" ] && cmp -s "$S" "$D"; } \\\n'),
  ("ligne-h-garde-lien-admis", "L", '  { [ -f "$D" ] && [ ! -L "$D" ] && [ -x "$D" ] && cmp -s "$S" "$D"; } \\\n', '  { [ -f "$D" ] && [ -x "$D" ] && cmp -s "$S" "$D"; } \\\n'),
  ("ligne-h-garde-hookspath-ignore", "L", '    [ -n "$H" ] && [ "$(realpath -m -- "$H")" = "$(realpath -m -- "${D%/*}")" ] \\\n', '    true \\\n'),
  ("ligne-h-garde-hookspath-par-copie-ignore", "L", '  [ "$WC" != true ] || mapfile -t -O 1 WTS', '  true || mapfile -t -O 1 WTS'),
  # ce que refuse la garde de push (git-push-garde-h.sh)
  ("poussee-h-v4", "G", '    v1|v2|v4|*/v1|*/v2|*/v4)\n', '    v1|v2|*/v1|*/v2|*/v4)\n'),
  ("poussee-h-v2", "G", '    v1|v2|v4|*/v1|*/v2|*/v4)\n', '    v1|v4|*/v1|*/v2|*/v4)\n'),
  ("poussee-h-v1", "G", '    v1|v2|v4|*/v1|*/v2|*/v4)\n', '    v2|v4|*/v1|*/v2|*/v4)\n'),
  ("poussee-h-x-v4-sur-origin", "G", '    v1|v2|v4|*/v1|*/v2|*/v4)\n', '    v1|v2|v4|*/v1|*/v2)\n'),
  ("poussee-h-x-v2-sur-origin", "G", '    v1|v2|v4|*/v1|*/v2|*/v4)\n', '    v1|v2|v4|*/v1|*/v4)\n'),
  ("poussee-h-x-v1-sur-origin", "G", '    v1|v2|v4|*/v1|*/v2|*/v4)\n', '    v1|v2|v4|*/v2|*/v4)\n'),
  ("poussee-h-creation-libre", "G", '    [ -n "$P" ] && [ "$P" = "$LOID" ] \\\n', '    true \\\n'),
  ("poussee-h-creation-depuis-une-v4-quelconque", "G", '    [ -n "$P" ] && [ "$P" = "$LOID" ] \\\n', '    [ -n "$P" ] \\\n'),
  ("poussee-h-reecriture", "G", '  elif ! git cat-file -e "$ROID^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$ROID" "$LOID" 2>/dev/null; then\n', '  elif false; then\n'),
  ("poussee-h-sortie-permissive", "G", '  } >&2\n  exit 1\nfi\n', '  } >&2\n  exit 0\nfi\n'),
  ("poussee-h-main", "G", '    main|master)\n', '    master)\n'),
  ("poussee-h-master", "G", '    main|master)\n', '    main)\n'),
  ("poussee-h-branche-par-defaut", "G", '      if [ -n "$DEF" ] && [ "$B" = "$DEF" ]; then\n', '      if false; then\n'),
  ("poussee-h-redescente-admise", "G", '    [ -z "$X" ] \\\n      || BAD=', '    true \\\n      || BAD='),
  ("poussee-h-redescente-de-v4-refusee", "G", '  elif ! L="$(git rev-list "$LOID" --not "$ROID" ${P:+"$P"} 2>/dev/null)"; then\n', '  elif ! L="$(git rev-list "$LOID" --not "$ROID" 2>/dev/null)"; then\n'),
  ("poussee-h-lfs-non-relaye", "G", '  printf \'%s\' "${IN:+$IN$\'\\n\'}" | git lfs pre-push "$@"\n  exit $?\n', '  exit 0\n'),
  ("poussee-h-sans-lfs-admis", "G", '  exit 2\n', '  exit 0\n'),
  # clone, --state, --defer, --manage-state (et leurs variables) : refusés dans la ligne H
  ("ligne-h-etat-options-ignorees", "R", '    case " $DBT_LINE_H_STATE_ARGS " in *" ${A%%=*} "*) STATEARGS+=("${A%%=*}") ;; esac\n', ''),
  ("ligne-h-etat-variables-ignorees", "R", '    for E in $(compgen -e | LC_ALL=C grep -E "$DBT_LINE_H_STATE_ENV_RE"); do STATEARGS+=("$E (exported)"); done\n', ''),
  ("ligne-h-etat-variable-vide-admise", "R", '    for E in $(compgen -e | LC_ALL=C grep -E "$DBT_LINE_H_STATE_ENV_RE"); do STATEARGS+=', '    for E in $(compgen -e | LC_ALL=C grep -E "$DBT_LINE_H_STATE_ENV_RE"); do [ -z "${!E:-}" ] || STATEARGS+='),
  ("ligne-h-etat-permis", "R", '    [ -z "${STATEARGS[*]-}" ] \\\n      || refuse "flux H (the harmonized line)', '    true \\\n      || refuse "flux H (the harmonized line)'),
  ("ligne-h-clone-permis", "L", 'DBT_LINE_H_STATE_ARGS="clone state', 'DBT_LINE_H_STATE_ARGS="state'),
  ("ligne-h-commande-state-permise", "L", '="clone state --state', '="clone --state'),
  ("ligne-h-state-permis", "L", ' state --state --defer', ' state --defer'),
  ("ligne-h-defer-permis", "L", ' --state --defer --defer-state', ' --state --defer-state'),
  ("ligne-h-defer-state-permis", "L", ' --defer-state --favor-state', ' --favor-state'),
  ("ligne-h-favor-state-permis", "L", ' --favor-state --manage-state ', ' --manage-state '),
  ("ligne-h-manage-state-permis", "L", ' --manage-state --run-cache-mode', ' --run-cache-mode'),
  ("ligne-h-run-cache-mode-permis", "L", ' --run-cache-mode --task-cache-url"', ' --task-cache-url"'),
  ("ligne-h-task-cache-url-permis", "L", ' --run-cache-mode --task-cache-url"', ' --run-cache-mode"'),
  ("ligne-h-env-STATE-permis", "L", "(STATE|DEFER|TASK_CACHE|RUN_CACHE|BUILD_CACHE)'", "(DEFER|TASK_CACHE|RUN_CACHE|BUILD_CACHE)'"),
  ("ligne-h-env-DEFER-permis", "L", "(STATE|DEFER|TASK_CACHE|RUN_CACHE|BUILD_CACHE)'", "(STATE|TASK_CACHE|RUN_CACHE|BUILD_CACHE)'"),
  ("ligne-h-env-TASK_CACHE-permis", "L", "(STATE|DEFER|TASK_CACHE|RUN_CACHE|BUILD_CACHE)'", "(STATE|DEFER|RUN_CACHE|BUILD_CACHE)'"),
  ("ligne-h-env-RUN_CACHE-permis", "L", "(STATE|DEFER|TASK_CACHE|RUN_CACHE|BUILD_CACHE)'", "(STATE|DEFER|TASK_CACHE|BUILD_CACHE)'"),
  ("ligne-h-env-BUILD_CACHE-permis", "L", "(STATE|DEFER|TASK_CACHE|RUN_CACHE|BUILD_CACHE)'", "(STATE|DEFER|TASK_CACHE|RUN_CACHE)'"),
  ("ligne-h-reglages-ignores", "R", '    while IFS= read -r E; do [ -z "$E" ] || STATEARGS+=("$E"); done < <(dbt_line_h_state_settings_problem "$PROJ")\n', ''),
  ("ligne-h-user-settings-ignore", "L", '    printf \'%s\\n\' "${HOME:-/nonexistent}/.dbt/user_settings.yml" "$P/dbt_project.yml"\n', '    printf \'%s\\n\' "$P/dbt_project.yml"\n'),
  ("ligne-h-dbt-project-ignore", "L", '    printf \'%s\\n\' "${HOME:-/nonexistent}/.dbt/user_settings.yml" "$P/dbt_project.yml"\n', '    printf \'%s\\n\' "${HOME:-/nonexistent}/.dbt/user_settings.yml"\n'),
  ("ligne-h-paquet-local-declare-ignore", "L", '      [ -f "$F" ] || continue\n      LC_ALL=C sed -nE "s@', '      continue\n      LC_ALL=C sed -nE "s@'),
  ("ligne-h-paquet-local-lie-ignore", "L", '    for L in "$P"/dbt_packages/*; do [ -L "$L" ] && printf', '    for L in; do [ -L "$L" ] && printf'),
  ("reglages-bloc-flags-ignore", "L", '          if (v == "") f = 1\n', '          if (v == "") f = 0\n'),
  ("reglages-flags-en-ligne-ignore", "L", '          else if (v ~ /^\\{.*\\}[ ]*$/) flow(v)\n', '          else if (v ~ /^\\{.*\\}[ ]*$/) f = 0\n'),
  ("reglages-forme-libre-admise", "L", '          else { print "flags: a form not read (" v ")"; exit }\n', '          else f = 0\n'),
  ("reglages-cle-de-tete-ignoree", "L", '        if (index(keys, " " norm(k) " ")) print norm(k)\n', ''),
  ("reglages-ancre-admise", "L", '        print "flags: a merge key, an anchor or an alias: a form not read"; exit\n', '        f = f\n'),
  ("reglages-tabulation-admise", "L", '      if (l ~ /\\t/) { print "a tab: a form not read"; exit }\n', ''),
  ("reglages-tiret-non-lu", "L", 'gsub("-", "_", k); return k }', 'return k }'),
  ("reglages-casse-non-lue", "L", 'function norm(k) { k = tolower(k); gsub(', 'function norm(k) { gsub('),
  ("reglages-commentaire-de-fin-lu-comme-une-cle", "L", '      sub(/[ \\t]#.*$/, "", l)\n', ''),
  ("doctor-user-settings-muet", "D", '              [ -z "$X" ] && ok "flux H: ~/.dbt/user_settings.yml turns no dbt State', '              true && ok "flux H: ~/.dbt/user_settings.yml turns no dbt State'),
  # la ligne harmonisée dans git : une copie v4/<p> qui n'est pas un worktree ; la branche de la copie principale
  ("ligne-h-copie-dossier-admise", "L", '      && echo "$(_dbt_show v4) is there but is not a worktree of this copy', '      && true "$(_dbt_show v4) is there but is not a worktree of this copy'),
  # un flux est un clone : son dépôt est le sien, jamais celui de la copie principale
  ("flux-git-dossier-admis", "L", '  { [ -d "$O" ] && [ ! -L "$O" ] && [ "$G" = "$O" ]; } \\\n', '  true \\\n'),
  ("flux-git-partage-admis", "L", '  [ "$(realpath -m -- "$M")" != "$G" ] \\\n', '  true \\\n'),
  ("flux-git-garde-fou-ignore", "L", '  [ -n "$F" ] || return 0\n  _dbt_flux_git_problem\n', '  [ -n "$F" ] || return 0\n'),
  ("flux-git-cycle-pose-quand-meme", "L", '  if [ "$(dbt_v4_role)" = flux ] && [ -n "$(_dbt_flux_git_problem)" ]; then\n', '  if false; then\n'),
  # le verrou : écrit et rejoué par la copie principale, ou par un flux sain
  ("verrou-orphelin-ecrit", "R", '  [ "$(dbt_v4_role)" != orphan ] \\\n    || orphan_refuse "just $1', '  true \\\n    || orphan_refuse "just $1'),
  ("verrou-declaration-refusee-ecrit", "R", 'lock_guard() {\n  flux_guard\n', 'lock_guard() {\n'),
  ("verrou-ecrit-sans-garde", "R", '  lock_guard lock\n', ''),
  ("verrou-rejoue-sans-garde", "R", '  lock_guard lock-checkout\n', ''),
  # les extensions dbt d'une copie qui n'est pas la principale : coupées là où elles calculeraient dans ses espaces
  ("editeur-flux-non-coupe", "L", '    flux) dbt_is_v4 "${1:-}" || echo "flux $DBT_V4_FLUX', '    flux) dbt_is_v4 "${1:-}" || true "flux $DBT_V4_FLUX'),
  ("editeur-orphelin-non-coupe", "L", '    orphan) echo "orphan copy: no space of its own" ;;\n', ''),
  ("editeur-refus-non-coupe", "L", '    refused) echo "flux declaration refused: no space anybody vouches for" ;;\n', ''),
  ("editeur-coupure-non-ecrite", "L", '  if [ -n "$WHY" ]; then\n    ALLOW=\'[".vscode"]\'\n', '  if false; then\n    ALLOW=\'[".vscode"]\'\n'),
  ("editeur-power-user-non-ecarte", "L", '  if [ -n "$WHY" ]; then\n    ALLOW=\'[".vscode"]\'\n', '  if [ -n "$WHY" ]; then\n    :\n'),
  ("editeur-global-non-coupe", "L", '        _dbt_editor_settings "$F" v2 \'[".vscode"]\' "$ENVF" "$WHY" "$NS"\n', '        :\n'),
  ("editeur-global-coupure-laissee", "L", '      rm -f "$F"; rmdir "$DBT_WS/$A/.vscode" 2>/dev/null || true\n', '      :\n'),
  ("editeur-global-a-soi-muet", "L", '        echo "  WARNING: $A/.vscode/settings.json is yours', '        true "  WARNING: $A/.vscode/settings.json is yours'),
  ("editeur-fichier-a-soi-muet", "L", '        echo "  WARNING: ${P_TAG}$(_dbt_show "$V").vscode/settings.json is yours', '        true "  WARNING: ${P_TAG}$(_dbt_show "$V").vscode/settings.json is yours'),
  ("doctor-editeur-muet", "D", '          && ok "$SHOW: the dbt extensions are cut in a window opened on it ($WHY)" \\\n          || ko', '          && ok "$SHOW: the dbt extensions are cut in a window opened on it ($WHY)" \\\n          || true'),
  ("doctor-editeur-global-muet", "D", '      && ok "$A/: the dbt extensions are cut in a window opened on it ($WHY)" \\\n      || ko', '      && ok "$A/: the dbt extensions are cut in a window opened on it ($WHY)" \\\n      || true'),
  ("doctor-racine-muette", "D", '    flux)   info "⚠ a VS Code window opened on this copy\'s ROOT', '    flux-jamais)   info "⚠ a VS Code window opened on this copy\'s ROOT'),
  ("doctor-hub-profil-coupe-muet", "D", '    ! _dbt_hub_has "$WS/profiles/profiles.yml" "$DBT_GUEST_EDITOR_PROFILE" \\\n', '    true \\\n'),
  # le contrôle n° 3 : la garde de push — toute branche ni supprimée ni réécrite ; une autre génération, jamais
  ("poussee-h-generation-admise", "G", '      elif [[ "$B" =~ ^(.*/)?v[0123456789]+(-[^/]*)?$ ]]; then\n', '      elif false; then\n'),
  ("poussee-h-suppression-autre-branche-admise", "G", '      elif nul "$LOID"; then\n        BAD="$BAD"$\'\\n\'"   $RREF: deleting a branch', '      elif false; then\n        BAD="$BAD"$\'\\n\'"   $RREF: deleting a branch'),
  ("poussee-h-reecriture-autre-branche-admise", "G", '      elif ! nul "$ROID" && { ! git cat-file -e "$ROID^{commit}" 2>/dev/null || ! git merge-base --is-ancestor "$ROID" "$LOID" 2>/dev/null; }; then\n', '      elif false; then\n'),
  # ce que seule la copie principale fait : product-new, product-add, referent-add ; le miroir
  ("copie-principale-seule-produit-ajoute", "R", '  main_only_guard product-add\n', ''),
  ("copie-principale-seule-referent-ajoute", "R", '  main_only_guard referent-add\n', ''),
  ("copie-principale-seule-produit-nouveau", "R", '  main_only_guard product-new\n', ''),
  ("copie-principale-seule-orpheline-admise", "R", '  case "$R" in flux|orphan|refused) ;; *) return 0 ;; esac\n  refuse "$(case', '  case "$R" in flux|refused) ;; *) return 0 ;; esac\n  refuse "$(case'),
  ("copie-principale-seule-refus-admis", "R", '  case "$R" in flux|orphan|refused) ;; *) return 0 ;; esac\n  refuse "$(case', '  case "$R" in flux|orphan) ;; *) return 0 ;; esac\n  refuse "$(case'),
  ("miroir-pousse-depuis-une-invitee", "R", '  case "$(dbt_v4_role)" in\n    flux|orphan|refused)\n      echo "→ mirror on $P_HOME ($P_MIRROR): NOT pushed', '  case "$(dbt_v4_role)" in\n    jamais)\n      echo "→ mirror on $P_HOME ($P_MIRROR): NOT pushed'),
  # dbt login, init, system : l'état du container, la copie principale seule
  ("dbt-etat-du-container-invite-permis", "R", '    case "${1:-}" in login|init|system)\n      case "$(dbt_v4_role)" in flux|orphan|refused)\n', '    case "${1:-}" in jamais)\n      case "$(dbt_v4_role)" in flux|orphan|refused)\n'),
  ("dbt-system-invite-permis", "R", '    case "${1:-}" in login|init|system)\n      case "$(dbt_v4_role)" in flux|orphan|refused)\n', '    case "${1:-}" in login|init)\n      case "$(dbt_v4_role)" in flux|orphan|refused)\n'),
  ("dbt-init-invite-permis", "R", '    case "${1:-}" in login|init|system)\n      case "$(dbt_v4_role)" in flux|orphan|refused)\n', '    case "${1:-}" in login|system)\n      case "$(dbt_v4_role)" in flux|orphan|refused)\n'),
  ("dbt-etat-du-container-orpheline-permis", "R", '    case "${1:-}" in login|init|system)\n      case "$(dbt_v4_role)" in flux|orphan|refused)\n', '    case "${1:-}" in login|init|system)\n      case "$(dbt_v4_role)" in flux|refused)\n'),
  ("dbt-login-autre-espace-permis", "R", '      if [ -z "$L" ] && [ -f "$UP/.devcontainer/dbt-run.sh" ] && [ -f "$UP/.devcontainer/lib-dbt.sh" ]; then\n', '      if false; then\n'),
  # --target-path, --log-path et leurs variables : jamais dans une autre copie
  ("invite-chemins-ignores", "R", '  case "$PWD/" in "$PROJ/"*) guest_paths_guard "$PWD" "$@" ;; *) guest_paths_guard "$PROJ" "$@" ;; esac\n', ''),
  ("invite-chemins-mot-suivant-ignore", "R", '      --target-path|--log-path) NX="$A" ;;\n', ''),
  ("invite-chemins-log-path-ignore", "R", '      --target-path|--log-path) NX="$A" ;;\n', '      --target-path) NX="$A" ;;\n'),
  ("invite-chemins-forme-egal-ignoree", "R", '      --target-path=*|--log-path=*) PS+=("${A%%=*} ${A#*=}") ;;\n', ''),
  ("invite-chemins-variables-ignorees", "R", '  for N in $(compgen -e | LC_ALL=C grep -E "$DBT_GUEST_PATH_ENV_RE"); do PS+=("$N ${!N}"); done\n', ''),
  ("invite-chemins-env-TARGET_PATH-ignore", "R", "DBT_GUEST_PATH_ENV_RE='^_?DBT_[A-Z0-9_]*(TARGET_PATH|LOG_PATH)$'", "DBT_GUEST_PATH_ENV_RE='^_?DBT_[A-Z0-9_]*(LOG_PATH)$'"),
  ("invite-chemins-env-LOG_PATH-ignore", "R", "DBT_GUEST_PATH_ENV_RE='^_?DBT_[A-Z0-9_]*(TARGET_PATH|LOG_PATH)$'", "DBT_GUEST_PATH_ENV_RE='^_?DBT_[A-Z0-9_]*(TARGET_PATH)$'"),
  ("invite-chemins-liens-non-resolus", "R", '    R="$(realpath -m -- "$R" 2>/dev/null)" || R=""\n', ''),
  ("invite-chemins-orpheline-admise", "R", '  case "$(dbt_v4_role)" in flux|orphan) ;; *) return 0 ;; esac\n  for A in "$@"; do\n    if [ -n "$NX" ]', '  case "$(dbt_v4_role)" in flux) ;; *) return 0 ;; esac\n  for A in "$@"; do\n    if [ -n "$NX" ]'),
  # le verrou de la ligne H nommé dans lock-status et le doctor
  ("verrou-h-description-commune", "L", '  LK="$(basename "${DBT_LOCK_FILE:-products.lock}")"\n', '  LK=products.lock\n'),
  # une copie v4/<p> racine d'un autre dépôt ; la branche de ligne créée pour une copie déjà là ; une orpheline sans copie v4
  ("ligne-h-copie-autre-depot-admise", "L", '  if [ -z "$G" ] || [ -z "$M" ] || [ "$(realpath -m -- "$G")" != "$(realpath -m -- "$M")" ]; then\n    echo "$(_dbt_show v4) is the root of another git repository', '  if false; then\n    echo "$(_dbt_show v4) is the root of another git repository'),
  ("ligne-h-branche-jamais-recreee", "L", '        _dbt_has_ref "refs/heads/$B" || _dbt_ensure_branch v4 >/dev/null 2>&1 || true\n', ''),
  ("orphelin-cree-ses-copies-v4", "L", '        case "$(dbt_v4_role)" in orphan|refused)\n          echo "  ${P_TAG}${SHOW}: not created', '        case "$(dbt_v4_role)" in jamais)\n          echo "  ${P_TAG}${SHOW}: not created'),
  # dbt State : les formes qu'un lecteur ne lit pas, le bloc dbt-cloud, dbt_cloud.yml
  ("reglages-cle-complexe-admise", "L", '      if (l ~ /^[ ]*(-[ ]+)?\\?/) { print "a complex key (?): a form not read"; exit }\n', ''),
  ("reglages-forme-de-tete-admise", "L", '        if (l !~ ("^(-[ ]+)?[\\"" q "A-Za-z0-9_]")) { print "a top-level line that is no plain key', '        if (0) { print "a top-level line that is no plain key'),
  ("reglages-contenu-apres-marqueur-ignore", "L", '        if (l ~ /^(---|\\.\\.\\.)[ ]*$/) next\n', '        if (l ~ /^(---|\\.\\.\\.)/) next\n'),
  ("reglages-cle-echappee-admise", "L", '        if (k ~ /\\\\/) { print "a key written with an escape: a form not read"; exit }\n', ''),
  ("reglages-cle-echappee-sous-flags-admise", "L", '      if (kk ~ /\\\\/) { print "flags: a key written with an escape: a form not read"; exit }\n', ''),
  ("reglages-bloc-dbt-cloud-ignore", "L", ' run_cache_mode task_cache_url dbt_cloud"', ' run_cache_mode task_cache_url"'),
  ("ligne-h-dbt-cloud-yml-ignore", "L", '    { [ -e "$F" ] || [ -L "$F" ]; } && echo "${F#"$DBT_WS"/}: dbt Cloud\'s settings', '    false && echo "${F#"$DBT_WS"/}: dbt Cloud\'s settings'),
  ("ligne-h-dbt-cloud-yml-projet-ignore", "L", '  for F in "${HOME:-/nonexistent}/.dbt/dbt_cloud.yml" "$P/dbt_cloud.yml"; do\n', '  for F in "${HOME:-/nonexistent}/.dbt/dbt_cloud.yml"; do\n'),
  # l'extension dbt de la ligne H : son report éteint dans l'espace v4 ; h.code-workspace
  ("editeur-ligne-h-report-non-ecrit", "L", '  [ -z "${6:-}" ] || CUT="$CUT$_DBT_EDITOR_NO_STATE"\n', ''),
  ("editeur-ligne-h-v4-sans-report", "L", '      NS=""; [ "$V" = v4 ] && _dbt_is_line_h && NS=1\n', '      NS=""\n'),
  ("editeur-ligne-h-report-hors-v4", "L", '      NS=""; [ "$V" = v4 ] && _dbt_is_line_h && NS=1\n', '      NS=""; _dbt_is_line_h && NS=1\n'),
  ("editeur-ligne-h-global-v4-sans-report", "L", '    NS=""; dbt_is_v4 "$A" && _dbt_is_line_h && NS=1\n', '    NS=""\n'),
  ("editeur-ligne-h-fichier-a-soi-muet", "L", '        echo "  WARNING: ${P_TAG}$(_dbt_show "$V").vscode/settings.json, yours (no generated marker), leaves', '        true "  WARNING: ${P_TAG}$(_dbt_show "$V").vscode/settings.json, yours (no generated marker), leaves'),
  ("editeur-ligne-h-espace-de-travail-absent", "L", '  done\n  dbt_ensure_line_h_workspace\n  return 0\n', '  done\n  return 0\n'),
  ("editeur-ligne-h-espace-de-travail-sans-v4", "L", '    FOLDERS="$FOLDERS"$\'\\n\'"    { \\"path\\": \\"${W#"$DBT_WS"/}\\" },"\n', ''),
  ("editeur-ligne-h-espace-de-travail-non-ignore", "L", 'grep -qxF "/h.code-workspace" "$EXCL" 2>/dev/null || echo "/h.code-workspace" >> "$EXCL"', ':'),
  ("editeur-ligne-h-espace-de-travail-laisse", "L", '    if [ -f "$F" ] && grep -q \'"dbt-project.generated"\' "$F"; then rm', '    if false; then rm'),
  ("doctor-ligne-h-report-muet", "D", '          || ko "$SHOW: the dbt extension\'s deferral is NOT off', '          || true "$SHOW: the dbt extension\'s deferral is NOT off'),
  ("doctor-ligne-h-global-v4-report-muet", "D", '      && ok "global-v4/: the dbt extension\'s deferral is off in a window opened on it" \\\n', '      && true "global-v4/: the dbt extension\'s deferral is off in a window opened on it" \\\n'),
  ("doctor-ligne-h-racine-muette", "D", '      [ -z "$X" ] || ko "flux H: ${F#"$WS"/} sets the dbt extension', '      [ -z "$X" ] || true "flux H: ${F#"$WS"/} sets the dbt extension'),
  ("doctor-ligne-h-autre-depot-muet", "D", '          || ko "$SHOW is the root of another git repository', '          || true "$SHOW is the root of another git repository'),
  ("doctor-ligne-h-espace-de-travail-muet", "D", '      ok "flux H: h.code-workspace (generated): open it', '      true "flux H: h.code-workspace (generated): open it'),
  # le doctor
  ("doctor-flux-muet", "D", '  FPB="$(dbt_v4_flux_problem)"\n', '  FPB=""\n'),
  ("doctor-verdict-sans-flux", "D", '        elif dbt_hooks_v4_verdict "$WS/$(dbt_hooks_v4_proof_path)" "$S" "${DBT_V4_FLUX:-}"; then\n',
                                    '        elif dbt_hooks_v4_verdict "$WS/$(dbt_hooks_v4_proof_path)" "$S"; then\n'),
  ("doctor-orpheline-muette", "D", '    orphan) while IFS= read -r L; do\n', '    orphan-jamais) while IFS= read -r L; do\n'),
  ("doctor-role-flux-muet", "D", '    flux)   ok "this copy is flux', '    flux-jamais)   ok "this copy is flux'),
]
# Gardes redondantes, sans mutant (un mutant seul ne peut pas les tuer, une autre garde fait le même refus) :
#   - [ -r "$F" ] dans _dbt_flux_parse : un fichier illisible ne se lit pas non plus (read échoue, 0 déclaration) ;
#   - la classe explicite _DBT_FLUX_BLANK_RE : sous LC_ALL=C (conf-locale-du-shell), [[:space:]] est la même ;
#   - safe.directory, ajouté (jamais retiré) par une copie de flux pour ses propres worktrees : pas une garde ;
#   - dans _dbt_push_lock_ssh_guest, le retour quand la garde couvre déjà tous les hôtes : sans lui, la commande
#     recomposée est la même (core.sshCommand inchangé), seul le message diffère ;
#   - le doctor d'une copie invitée (verrou 4 vérifié même sous DBT_UPSTREAM_PUSH_LOCK=0, couche https selon l'état du
#     container) : la suite ne simule pas d'upstream ssh dans la flotte (dbt-doctor.sh relit products.conf), pas de témoin ;
#   - dans git-push-garde-h.sh, le refus explicite de supprimer une v4-h : une suppression échoue aussi au contrôle de
#     l'avance rapide (le commit vide n'a pas l'ancien pour ancêtre), seul le message diffère ;
#   - dans _dbt_push_guard_h_problem, [ -f "$D" ] : un lien, un dossier ou rien à sa place échouent aussi à [ ! -L ], -x
#     ou cmp ; dans dbt_v4_line_h_branch_problem, _dbt_has_ref avant merge-base (merge-base échoue sur une réf absente) ;
#   - dans _dbt_flux_git_problem, [ ! -L "$O" ] (un .git qui serait un lien : son chemin réel diffère, le contrôle
#     d'égalité refuse aussi) et « not a git repository » (un flux hors de git est refusé par les contrôles d'ignore) ;
#   - dans git-push-garde-h.sh, le refus quand git rev-list ne peut lister les commits apportés : seul un dépôt corrompu
#     le déclenche — sans témoin (non simulé) ;
#   - dans _dbt_packages_guest_problem, la lecture de package-lock.yml passe par le même lecteur que packages.yml :
#     ses formes ont leurs mutants par packages.yml ;
#   - dans dbt_v4_line_h_branch_problem, la branche et le suivi lus dans la copie (git -C "$W") plutôt que dans son dépôt :
#     après le contrôle du dépôt commun, c'est le même dépôt, la même réponse ;
#   - dans git-push-garde-h.sh, le refus nommé de v1, v2, v4 (et <x>/v…) : la forme d'une autre génération les refuse
#     aussi ; leurs mutants sont tués par le motif du refus (« a branch of the ISO line… »), que les témoins lisent ;
#   - dans git-push-garde-h.sh, le refus explicite de supprimer une autre branche : une suppression échoue aussi au
#     contrôle de l'avance rapide ; son mutant est tué par le motif du refus (« deleting a branch »), que le témoin lit ;
#   - _dbt_line_h_checkout_hint : le conseil (checkout, checkout -b --track, ouverture) ne refuse rien, ses formes sont dites
#     par un témoin (le cycle de vie crée la branche, le conseil marche) ;
#   - dans guest_paths_guard, la résolution relative au dossier où dbt tourne (PWD dans le projet, sinon le projet) :
#     les témoins partent de la racine de la copie (le projet), un appel depuis un sous-dossier n'est pas simulé.
PY
python3 - "$WORK" "$REPO_ROOT" "$@" <<'PY'
import sys
work, root, only = sys.argv[1], sys.argv[2], sys.argv[3:]
exec(open(f"{work}/mutants.py", encoding="utf-8").read())
F = {k: f"{root}/template/.devcontainer/{{% if {c} %}}{n}{{% endif %}}" for k, c, n in
     (("L", "dbt_workspace", "lib-dbt.sh"), ("R", "dbt_workspace", "dbt-run.sh"), ("D", "dbt_workspace", "dbt-doctor.sh"),
      ("G", "project_type == 'dbt-fleet'", "git-push-garde-h.sh"))}
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
F = {k: f"{root}/template/.devcontainer/{{% if {c} %}}{n}{{% endif %}}" for k, c, n in
     (("L", "dbt_workspace", "lib-dbt.sh"), ("R", "dbt_workspace", "dbt-run.sh"), ("D", "dbt_workspace", "dbt-doctor.sh"),
      ("G", "project_type == 'dbt-fleet'", "git-push-garde-h.sh"))}
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
