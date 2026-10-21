#!/usr/bin/env bash
# =============================================================================
# test-flux-mutants.sh — les témoins du flux savent-ils refuser ? (mutants)
# -----------------------------------------------------------------------------
# Pour chaque garde du flux (lib-dbt.sh, dbt-run.sh, dbt-doctor.sh : le
# sous-espace v4 d'une copie de travail, .devcontainer/flux.conf) : une copie
# jetable du dépôt où CETTE garde est retirée ou affaiblie — un « mutant » —,
# puis scripts/test-lib-dbt.sh sur cette copie. Un mutant doit faire échouer au
# moins un contrôle ; un mutant qui passe est une garde que rien ne teste.
#   - d'abord la copie non mutée : la suite doit y passer, sinon rien ne vaut ;
#   - chaque mutant remplace un texte EXACT du code, présent une seule fois :
#     un texte introuvable arrête tout (le code a changé, la liste doit suivre).
# Ce qu'il voit : les gardes listées ci-dessous, une par mutant. Ce qu'il ne voit
# pas : une garde absente de la liste, ni ce que test-lib-dbt.sh ne simule pas
# (BigQuery, le vrai moteur dbt, l'extension dbt).
#
# Usage :  scripts/test-flux-mutants.sh [-j N] [NOM…]   (défaut : tous, 4 à la fois)
# Sortie : une ligne par mutant (TUÉ, avec le premier contrôle tombé, ou SURVIT),
#          puis « TÉMOINS test-flux-mutants : OK » — code 0 —, ou ÉCHEC — code 1.
# Hors ligne (les bouchons de test-lib-dbt.sh), ~30 s par mutant ; n'écrit que
# dans un dossier temporaire, effacé à la fin.
# Prérequis : ceux de test-lib-dbt.sh (git, bash, python3).
# =============================================================================
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
J=4
if [ "${1:-}" = "-j" ]; then J="${2:?-j N}"; shift 2; fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- les mutants : NOM, fichier (L lib-dbt.sh, R dbt-run.sh, D dbt-doctor.sh), texte exact, remplacement ----------
cat > "$WORK/mutants.py" <<'PY'
M = [
  # la déclaration
  ("conf-dbt-conf-accepte", "L", '  if [ -n "${DBT_V4_FLUX:-}" ]; then\n    DBT_V4_FLUX=""\n', '  if false; then\n    DBT_V4_FLUX=""\n'),
  ("conf-env-exporte-lu", "L", '  DBT_V4_FLUX=""\n  # shellcheck disable=SC1090\n', '  # shellcheck disable=SC1090\n'),
  ("conf-syntaxe-libre", "L", "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([ABCDEFGHIJKLMNOPQRSTUVWXYZ][0123456789][0123456789][0123456789])$'",
                              "_DBT_FLUX_LINE_RE='^DBT_V4_FLUX=([^ ]+)$'"),
  ("conf-plusieurs-lignes", "L", '  [ "$N" = 1 ] || return 1\n', '  [ "$N" -ge 1 ] || return 1\n'),
  ("conf-lien-accepte", "L", '  { [ -f "$F" ] && [ ! -L "$F" ] && [ -r "$F" ]; } || return 1\n', '  { [ -f "$F" ] && [ -r "$F" ]; } || return 1\n'),
  ("conf-commentaires-refuses", "L", '    [[ "$L" =~ ^[[:space:]]*(#.*)?$ ]] && continue\n', ''),
  ("conf-hors-flotte", "L", '  if [ -n "$F" ] && ! dbt_is_fleet; then\n', '  if false; then\n'),
  # ce qui rend une déclaration indigne de confiance
  ("git-suivi-accepte", "L", '    if git -C "$DBT_WS" ls-files --error-unmatch -- "$X" >/dev/null 2>&1; then\n', '    if false; then\n'),
  ("git-non-ignore-accepte", "L", '    elif ! git -C "$DBT_WS" check-ignore -q -- "$X" 2>/dev/null; then\n', '    elif false; then\n'),
  ("paquet-homonyme-accepte", "L", '  C="$(_dbt_flux_clash)"\n', '  C=""\n'),
  ("paquet-homonyme-sans-borne", "L", 'if (u == f || index(u, f "_") == 1) print $0', 'if (index(u, f) == 1) print $0'),
  ("garde-flux-muette", "R", '  [ -z "$PB" ] && return 0\n', '  return 0\n'),
  # les espaces
  ("env-du-flux-ignore", "L", 'dbt_v4_env_file() { printf \'%s\' "$DBT_WS/profiles/v4${DBT_V4_FLUX:+-$DBT_V4_FLUX}.env"; }',
                              'dbt_v4_env_file() { printf \'%s\' "$DBT_WS/profiles/v4.env"; }'),
  ("ecrit-espace-principal-depuis-flux", "R", 'function here(s) { if (fx != "") return under(s, q "_" fx);', 'function here(s) { if (fx != "") return under(s, q);'),
  ("principal-ecrit-un-flux", "R", 'return under(s, q) && !fluxlike(s) }', 'return under(s, q) }'),
  ("forme-de-flux-sans-borne", "R", 'return r ~ /^[A-Z][0-9][0-9][0-9]$/ || r ~ /^[A-Z][0-9][0-9][0-9]_/ }', 'return r ~ /^[A-Z][0-9][0-9][0-9]/ }'),
  ("v2-ecrit-depuis-flux", "R", '  if [ -n "${DBT_V4_FLUX:-}" ] && ! dbt_is_v4 "$V" && [ -n "$CMD_WRITE$CMD_RUNOP$CMD_HOOKS_HARD" ]; then\n', '  if false; then\n'),
  ("v2-teste-depuis-flux", "R", '[ -n "$CMD_WRITE$CMD_RUNOP$CMD_HOOKS_HARD" ]; then\n', '[ -n "$CMD_WRITE" ]; then\n'),
  ("prefixe-principal-dans-flux", "R", '    [ "${DATASET_PREFIX:-}" = "$X" ] \\\n', '    [ "${DATASET_PREFIX:-}" = "$X" ] || [ "${DATASET_PREFIX:-}" = "$DBT_BQ_DATASET_PREFIX_V4" ] \\\n'),
  ("env-v4-principal-dans-flux", "R", '    [ -z "$P" ] || [ "$L" = "$(readlink -f "$E4")" ] \\\n', '    [ -z "$P" ] || [ "$L" = "$(readlink -f "$E4")" ] || _dbt_is_v4_env "$L" \\\n'),
  ("env-flux-lu-par-v2", "R", '    [ -z "$P" ] || [ -z "$L" ] || ! _dbt_is_v4_env "$L" \\\n', '    [ -z "$P" ] || [ -z "$L" ] || [ "$L" != "$(readlink -f "$WS/profiles/v4.env")" ] \\\n'),
  ("export-env-principal", "R", '    BASE="$(dbt_v4_env_file)"\n', '    BASE="$WS/profiles/v4.env"\n'),
  ("destinations-prefixe-principal", "R", '    "$(dbt_v4_prefix)" <<\'PY\'\n', '    "${DBT_BQ_DATASET_PREFIX_V4:-}" <<\'PY\'\n'),
  ("hooks-approve-dans-flux", "R", '  [ -z "${DBT_V4_FLUX:-}" ] \\\n    || die "flux $DBT_V4_FLUX: the approved hooks', '  true \\\n    || die "flux $DBT_V4_FLUX: the approved hooks'),
  ("dbt-brut-dans-une-copie", "R", '    if [ -n "$L" ] && [ -f "$UP/.devcontainer/dbt-run.sh" ] && [ -f "$UP/.devcontainer/lib-dbt.sh" ]; then\n', '    if false; then\n'),
  # le cycle de vie
  ("setup-env-du-flux-principal", "L", '    _dbt_v4_env_render "$DBT_V4_FLUX" > "$TMP"\n', '    _dbt_v4_env_render > "$TMP"\n'),
  ("setup-global-v4-principal", "L", '  [ -f "$DBT_WS/global-v4/dbt_project.yml" ] && _dbt_link_env "$DBT_WS/global-v4" "$E" fix\n',
                                     '  [ -f "$DBT_WS/global-v4/dbt_project.yml" ] && _dbt_link_env "$DBT_WS/global-v4" "$DST" fix\n'),
  ("setup-env-v4-principal", "L", '      ENVF="$P_ENV"; [ "$V" = v4 ] && ENVF="$(dbt_v4_env_file)"\n', '      ENVF="$P_ENV"; [ "$V" = v4 ] && ENVF="$DBT_WS/profiles/v4.env"\n'),
  ("setup-lien-garde-sous-refus", "L", '        elif [ -f "$ENVF" ] && [ -z "${DBT_V4_FLUX_ERR:-}" ]; then\n', '        elif [ -f "$ENVF" ]; then\n'),
  ("setup-global-v4-garde-sous-refus", "L", '    [ -L "$DBT_WS/global-v4/.env" ] && rm -f "$DBT_WS/global-v4/.env"\n', '    :\n'),
  # la preuve des hooks de global-v4
  ("sceau-sans-flux", "L", '  [ -z "$F" ] || E4="profiles/v4-$F.env"\n', '  :\n'),
  ("verdict-sans-flux", "L", '  if [ -n "${3:-}" ]; then [[ "$3" =~ $DBT_V4_FLUX_RE ]] || return 1; X="GLOBAL-V4 FLUX $3"; fi\n', '  :\n'),
  ("verdict-motif-libre", "L", '[[ "$3" =~ $DBT_V4_FLUX_RE ]] || return 1; X=', 'X='),
  ("garde-fou-verdict-sans-flux", "R", '  dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S" "${DBT_V4_FLUX:-}" \\\n', '  dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S" \\\n'),
  # le doctor
  ("doctor-flux-muet", "D", '  FPB="$(dbt_v4_flux_problem)"\n', '  FPB=""\n'),
  ("doctor-verdict-sans-flux", "D", '        elif dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S" "${DBT_V4_FLUX:-}"; then\n',
                                    '        elif dbt_hooks_v4_verdict "$WS/$DBT_HOOKS_V4_PROOF" "$S"; then\n'),
]
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
    TUES=$((TUES + 1)); printf '  TUÉ    %-36s %s (%s contrôle(s) tombé(s))\n' "$N" "$FIRST" "$(grep -c FAIL "$WORK/$N.log")"
  else
    SURV=$((SURV + 1)); printf '  SURVIT %-36s aucun contrôle ne tombe : cette garde n\x27est pas testée\n' "$N"
  fi
done < "$WORK/noms"
echo
if [ "$SURV" = 0 ] && [ "$TUES" -gt 0 ]; then
  echo "TÉMOINS test-flux-mutants : OK ($TUES mutant(s) tué(s) sur $TUES)"
else
  echo "TÉMOINS test-flux-mutants : ÉCHEC ($SURV mutant(s) survivant(s) sur $((TUES + SURV)))"; exit 1
fi
