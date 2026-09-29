#!/usr/bin/env bash
# =============================================================================
# test-claude-profile-migrate.sh — tests de scripts/claude-profile-migrate.sh
# -----------------------------------------------------------------------------
# Sur un faux ~/.claude jetable (jamais le vrai), vérifie que la migration :
#   - copie la config utilisateur, les projects/<slug> du dépôt (y compris
#     sous-dossiers et .worktrees/), sa memory/, ses lignes history.jsonl
#     (triées par timestamp) et ses file-history/ ;
#   - ne copie JAMAIS .credentials.json*, backups/, .device-keys.json ni l'état
#     runtime, ni les projets d'un dépôt voisin au slug trompeur (demo-other) ;
#   - ne modifie JAMAIS la source (empreinte avant/après) ;
#   - est idempotente, fusionne un 2e dépôt dans le même profil, garde la copie
#     plus récente du profil, refuse d'écrire si une session semble active.
#
# Usage :  scripts/test-claude-profile-migrate.sh            (sous /bin/sh)
#          SH=bash scripts/test-claude-profile-migrate.sh     (autre shell)
# =============================================================================
set -uo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
MIGRATE="$REPO_ROOT/scripts/claude-profile-migrate.sh"
SH="${SH:-sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
check() { if eval "$2"; then pass "$1"; else bad "$1"; fi; }

SRC="$WORK/home/.claude"
PROFILES="$WORK/home/.claude-profiles"
DEST="$PROFILES/demo-prof"
run() { "$SH" "$MIGRATE" --src "$SRC" --profiles "$PROFILES" "$@"; }
hline() { printf '{"display":"%s","pastedContents":{},"timestamp":%s,"project":"%s","sessionId":"x"}\n' "$1" "$2" "$3"; }
tline() { printf '{"type":"user","cwd":"%s","sessionId":"%s","message":{"role":"user","content":"hi"}}\n' "$1" "$2"; }
old()   { find "$1" -exec touch -t 202601010000 {} +; }   # hors fenêtre « session active »
manifest() { (cd "$SRC" && find . -type f -exec cksum {} + | sort); }

# --- faux ~/.claude ----------------------------------------------------------
P="$SRC/projects"
mkdir -p "$SRC/backups" "$SRC/sessions" "$SRC/ide" "$SRC/skills/demo-skill" "$SRC/plugins" \
         "$P/-workspaces-demo/memory" "$P/-workspaces-demo/s2/subagents" \
         "$P/-workspaces-demo-other" "$P/-workspaces-demo--worktrees-wt" "$P/-workspaces-demo-sub" \
         "$P/-workspaces-demo2" "$SRC/file-history/s1" "$SRC/file-history/s2" "$SRC/file-history/o1"
echo '{"fake":"account-A"}' > "$SRC/.credentials.json"
echo '{"fake":"old"}'       > "$SRC/.credentials.json.bak-2026-09-11"
echo '{"fake":"device"}'    > "$SRC/.device-keys.json"
echo '{"oauthAccount":"A"}' > "$SRC/backups/.claude.json.backup.1700000000000"
echo '{}' > "$SRC/sessions/123.json"; echo '{}' > "$SRC/ide/1.lock"
echo '{"effortLevel":"high"}' > "$SRC/settings.json"
echo '{"permissions":{}}'     > "$SRC/settings.local.json"
echo 'skill' > "$SRC/skills/demo-skill/SKILL.md"
echo '{}'    > "$SRC/plugins/installed_plugins.json"
tline /workspaces/demo s1 > "$P/-workspaces-demo/s1.jsonl"
tline /workspaces/demo s2 > "$P/-workspaces-demo/s2.jsonl"
tline /workspaces/demo s2 > "$P/-workspaces-demo/s2/subagents/agent-a.jsonl"
echo '- [fait](fact.md)' > "$P/-workspaces-demo/memory/MEMORY.md"
echo 'fait mémorisé'     > "$P/-workspaces-demo/memory/fact.md"
tline /workspaces/demo-other o1          > "$P/-workspaces-demo-other/o1.jsonl"
tline /workspaces/demo/.worktrees/wt w1  > "$P/-workspaces-demo--worktrees-wt/w1.jsonl"
tline /workspaces/demo/sub d1            > "$P/-workspaces-demo-sub/d1.jsonl"
tline /workspaces/demo2 e1               > "$P/-workspaces-demo2/e1.jsonl"
# Dossiers sans transcript, seulement <session-id>/workflows/ : ils suivent le
# propriétaire du transcript de la session (s1 = demo, o1 = demo-other).
mkdir -p "$P/-workspaces-demo--worktrees-art/s1/workflows" "$P/-workspaces-demo-other-sub/o1/workflows" \
         "$P/-workspaces-demo-orphan/zzz/workflows"
echo 'wf' > "$P/-workspaces-demo--worktrees-art/s1/workflows/w.js"
echo 'wf' > "$P/-workspaces-demo-other-sub/o1/workflows/x.js"
echo 'wf' > "$P/-workspaces-demo-orphan/zzz/workflows/y.js"
echo v1 > "$SRC/file-history/s1/a@v1"; echo v1 > "$SRC/file-history/s2/b@v1"; echo v1 > "$SRC/file-history/o1/c@v1"
{
  hline demo-3000   3000 /workspaces/demo
  hline other-1500  1500 /workspaces/demo-other
  hline host-2500   2500 /Users/me/repo
  hline demo-1000   1000 /workspaces/demo
  hline sub-2000    2000 /workspaces/demo/sub
  hline 'leurre \"project\":\"/workspaces/demo\"' 2600 /workspaces/else
  hline demo2-1500  1500 /workspaces/demo2
} > "$SRC/history.jsonl"
old "$SRC"
BEFORE="$(manifest)"
hist_order() { sed -n 's/.*"display":"\([a-z0-9-]*\)".*/\1/p' "$DEST/history.jsonl" | tr '\n' ' '; }

echo "== 1. dry-run : aucun écrit"
out="$(run --profile demo-prof --repo demo)"; rc=$?
check "exit 0" '[ "$rc" -eq 0 ]'
check "rien créé côté profil" '[ ! -e "$PROFILES" ]'
check "plan : COPY projects/-workspaces-demo" 'grep -q "COPY  projects/-workspaces-demo  " <<<"$out"'
check "plan : skip demo-other (autre dépôt, slug trompeur)" 'grep -q "skip  projects/-workspaces-demo-other" <<<"$out"'
check "plan : 3 lignes d historique" 'grep -q "MERGE 3 line" <<<"$out"'

echo "== 2. --apply"
out="$(run --profile demo-prof --repo demo --apply)"; rc=$?
check "exit 0" '[ "$rc" -eq 0 ]'
for f in settings.json settings.local.json skills/demo-skill/SKILL.md plugins/installed_plugins.json; do
  check "config copiée : $f" 'cmp -s "$SRC/$f" "$DEST/$f"'
done
for f in .credentials.json .credentials.json.bak-2026-09-11 .device-keys.json backups sessions ide; do
  check "JAMAIS copié : $f" '[ ! -e "$DEST/$f" ]'
done
for s in -workspaces-demo -workspaces-demo--worktrees-wt -workspaces-demo-sub; do
  check "projet copié : $s" 'diff -r "$P/$s" "$DEST/projects/$s" >/dev/null'
done
check "memory/ copiée à l identique" 'diff -r "$P/-workspaces-demo/memory" "$DEST/projects/-workspaces-demo/memory" >/dev/null'
check "subagents copiés" '[ -f "$DEST/projects/-workspaces-demo/s2/subagents/agent-a.jsonl" ]'
check "pas copié : demo-other" '[ ! -e "$DEST/projects/-workspaces-demo-other" ]'
check "artefacts de worktree d une session du dépôt : copiés" '[ -f "$DEST/projects/-workspaces-demo--worktrees-art/s1/workflows/w.js" ]'
check "artefacts d une session d un autre dépôt : pas copiés" '[ ! -e "$DEST/projects/-workspaces-demo-other-sub" ]'
check "artefacts orphelins : pas copiés, signalés" '[ ! -e "$DEST/projects/-workspaces-demo-orphan" ] && grep -q "demo-orphan.*check it by hand" <<<"$out"'
check "pas copié : demo2" '[ ! -e "$DEST/projects/-workspaces-demo2" ]'
check "file-history s1, s2 copiés ; o1 non" '[ -f "$DEST/file-history/s1/a@v1" ] && [ -f "$DEST/file-history/s2/b@v1" ] && [ ! -e "$DEST/file-history/o1" ]'
check "historique = demo + sous-dossier, triés, sans leurre" '[ "$(hist_order)" = "demo-1000 sub-2000 demo-3000 " ]'
check "history.jsonl en 600" '[ "$(ls -l "$DEST/history.jsonl" | cut -c1-10)" = "-rw-------" ]'
check "SOURCE INTACTE (empreinte identique)" '[ "$(manifest)" = "$BEFORE" ]'

echo "== 3. relance : idempotente"
old "$DEST"
out="$(run --profile demo-prof --repo demo --apply)"; rc=$?
check "exit 0" '[ "$rc" -eq 0 ]'
check "historique inchangé (pas de doublon)" '[ "$(hist_order)" = "demo-1000 sub-2000 demo-3000 " ]'

echo "== 4. le profil a vécu : sa copie plus récente est gardée"
tline /workspaces/demo s1 >> "$DEST/projects/-workspaces-demo/s1.jsonl"
hline new-4000 4000 /workspaces/demo >> "$DEST/history.jsonl"
old "$DEST"; grown="$(cksum < "$DEST/projects/-workspaces-demo/s1.jsonl")"
out="$(run --profile demo-prof --repo demo --apply)"; rc=$?
check "exit 0" '[ "$rc" -eq 0 ]'
check "transcript du profil non écrasé" '[ "$(cksum < "$DEST/projects/-workspaces-demo/s1.jsonl")" = "$grown" ]'
check "historique : ligne récente gardée" '[ "$(hist_order)" = "demo-1000 sub-2000 demo-3000 new-4000 " ]'

echo "== 5. 2e dépôt dans le même profil : fusion triée"
old "$DEST"
out="$(run --profile demo-prof --repo demo2 --apply)"; rc=$?
check "exit 0" '[ "$rc" -eq 0 ]'
check "projet demo2 ajouté" '[ -f "$DEST/projects/-workspaces-demo2/e1.jsonl" ]'
check "historique fusionné et trié" '[ "$(hist_order)" = "demo-1000 demo2-1500 sub-2000 demo-3000 new-4000 " ]'
check "SOURCE TOUJOURS INTACTE" '[ "$(manifest)" = "$BEFORE" ]'

echo "== 6. session active : refus sans --force"
touch "$P/-workspaces-demo/s1.jsonl"; BEFORE="$(manifest)"
out="$(run --profile demo-prof --repo demo --apply 2>&1)"; rc=$?
check "refus (exit 2)" '[ "$rc" -eq 2 ] && grep -q "stop the container" <<<"$out"'
old "$SRC"

echo "== 7. arguments invalides"
for args in "--profile Foo --repo demo" "--profile ../x --repo demo" "--profile ok --repo a/b" "--profile ok"; do
  run $args >/dev/null 2>&1; rc=$?
  check "refusé : $args" '[ "$rc" -eq 2 ]'
done
"$SH" "$MIGRATE" --src "$SRC" --profiles "$SRC/profiles" --profile ok --repo demo >/dev/null 2>&1; rc=$?
check "refusé : profil à l intérieur de la source" '[ "$rc" -eq 2 ]'

echo
if [ "$fail" -eq 0 ]; then echo -e "\033[32mTOUS LES CONTRÔLES PASSENT\033[0m ($SH)"; else echo -e "\033[31mECHECS DETECTES\033[0m ($SH)"; fi
exit "$fail"
