#!/usr/bin/env bash
# =============================================================================
# test-template-render.sh — smoke test du rendu Copier
# -----------------------------------------------------------------------------
# Rend le template deux fois (option tmux OFF puis ON) et vérifie :
#   - OFF : ni .config/tmux/claude-code.tmux.conf ni docs/claude-code-tmux.md ;
#   - ON  : les deux fichiers présents, sans suffixe .jinja résiduel ;
#   - dans les deux cas : le rendu de base (README.md, .copier-answers.yml) est
#     généré et ne contient pas de marqueur Jinja non résolu.
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

render() {  # render <enable_bool> <out_dir>
  copier copy --vcs-ref "$VCS_REF" --defaults --quiet \
    --data project_name=render-test \
    --data project_description="Render smoke test" \
    --data "enable_tmux_claude_code_config=$1" \
    "$REPO_ROOT" "$2"
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

echo "== Vérif marqueurs Jinja non résolus (les deux rendus) =="
if grep -rlE '\{\{|\{%' "$WORK/off" "$WORK/on" --include='*.md' --include='*.conf' --include='*.toml' 2>/dev/null | grep -q .; then
  bad "marqueurs Jinja non résolus trouvés :"; grep -rlE '\{\{|\{%' "$WORK/off" "$WORK/on" --include='*.md' --include='*.conf' --include='*.toml' 2>/dev/null
else
  pass "aucun marqueur Jinja non résolu"
fi

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mTOUS LES CONTRÔLES PASSENT\033[0m"; else echo -e "\033[31mECHECS DETECTES\033[0m"; fi
exit "$fail"
