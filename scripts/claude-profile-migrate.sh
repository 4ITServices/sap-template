#!/bin/sh
# =============================================================================
# claude-profile-migrate.sh — seed a Claude Code profile for ONE repo from the
# host-wide ~/.claude, WITHOUT modifying ~/.claude (it is only ever read).
# -----------------------------------------------------------------------------
# Run it on the HOST (macOS or Linux; POSIX sh, no bash-4 or GNU-only flags)
# with the repo's dev container STOPPED. Dry-run by default: prints the plan
# and writes nothing. Add --apply to copy.
#
# Copied into <profiles>/<profile>/ (copied, never moved):
#   - user config, once: only entries the profile does not have yet
#     (settings*.json, CLAUDE.md, keybindings.json, agents/, commands/,
#     skills/, output-styles/, hooks/, plugins/, rules/, workflows/, bin/)
#   - projects/<slug>/ (transcripts, subagents, memory/) for every slug whose
#     sessions ran in the workspace or below it (subdirs, .worktrees/...): the
#     "cwd" recorded in the transcripts decides, not the lossy slug name
#   - history.jsonl lines whose "project" is the workspace or below, merged
#     into the profile's history (de-duplicated, sorted by timestamp)
#   - file-history/<session-id>/ (/rewind checkpoints) of those sessions
# Never copied: .credentials.json* (log in again with /login), backups/
#   (~/.claude.json snapshots of whichever container saved last — the very
#   cross-account channel profiles close), .device-keys.json and runtime
#   state (sessions/, ide/, daemon*, shell-snapshots/, caches, ...).
#
# Usage:
#   scripts/claude-profile-migrate.sh --profile sap-testing --repo sap_testing
#   scripts/claude-profile-migrate.sh --profile sap-testing --repo sap_testing --apply
# Options:
#   --profile NAME    the copier answer claude_profile
#   --repo NAME       container workspace /workspaces/NAME (default layout)
#   --workspace PATH  container workspace path, when not /workspaces/NAME
#   --src DIR         host-wide dir, only read (default: $HOME/.claude)
#   --profiles DIR    profiles root           (default: $HOME/.claude-profiles)
#   --apply           copy for real (default: dry-run)
#   --force           apply even if files changed in the last 2 minutes
#
# Rollback: nothing here writes to --src. Set claude_profile back to empty
# (copier update) and rebuild: the container mounts ~/.claude again, history
# as it was before the migration. To also keep what was done in the profile
# meanwhile (transcripts only grow, so the profile's copy is a superset):
#   cp -R -p <profiles>/<profile>/projects/<slug>/. ~/.claude/projects/<slug>/
# =============================================================================
set -eu
LC_ALL=C; export LC_ALL   # byte-wise [a-z], sort and grep, whatever the locale

die()   { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
say()   { printf '%s\n' "$*"; }
usage() { sed -n '/^# Usage:/,/^# Rollback:/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^Rollback:/d'; exit "$1"; }

PROFILE='' WS='' APPLY=0 FORCE=0
SRC="$HOME/.claude"
ROOT="$HOME/.claude-profiles"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile|--repo|--workspace|--src|--profiles)
      [ $# -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --profile)   PROFILE=$2 ;;
        --repo)      case "$2" in ''|*/*) die "--repo takes a folder name, not a path" ;; esac
                     WS="/workspaces/$2" ;;
        --workspace) WS=$2 ;;
        --src)       SRC=$2 ;;
        --profiles)  ROOT=$2 ;;
      esac
      shift 2 ;;
    --apply) APPLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

# Same rule as the copier validator: ^[a-z0-9][a-z0-9_-]{0,62}$
case "$PROFILE" in
  ''|[!a-z0-9]*|*[!a-z0-9_-]*) die "invalid --profile '$PROFILE' (lowercase, digits, - and _; e.g. sap-testing)" ;;
esac
[ "${#PROFILE}" -le 63 ] || die "--profile is longer than 63 characters"
[ -n "$WS" ] || die "--repo NAME or --workspace PATH is required"
case "$WS" in /*) ;; *) die "--workspace must be an absolute path inside the container" ;; esac
WS=${WS%/}
[ -d "$SRC" ] || die "source not found: $SRC"
SRC=$(cd "$SRC" && pwd -P)
case "$ROOT" in /*) ;; *) ROOT="$PWD/$ROOT" ;; esac
DEST="$ROOT/$PROFILE"
if [ -d "$ROOT" ]; then DEST="$(cd "$ROOT" && pwd -P)/$PROFILE"; fi
case "$DEST/" in "$SRC"/*) die "the profile dir $DEST is inside the source $SRC" ;; esac

# Claude Code's project slug: every non-alphanumeric char becomes '-'.
slug() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
BASE=$(slug "$WS")
[ "${#BASE}" -le 200 ] || die "workspace path too long (Claude Code hashes such slugs; not supported)"

belongs()   { case "$1" in "$WS"|"$WS"/*) return 0 ;; esac; return 1; }
first_cwd() { grep -o -m 1 '"cwd":"[^"]*"' "$1" 2>/dev/null | head -n 1 | sed -e 's/^"cwd":"//' -e 's/"$//'; }
count_files() { find "$1" -type f | wc -l | tr -d ' '; }
size_kb()   { du -sk "$1" | cut -f1; }

HP1="\"project\":\"$WS\""
HP2="\"project\":\"$WS/"
CONFIG="settings.json settings.local.json CLAUDE.md keybindings.json agents commands skills output-styles hooks plugins rules workflows bin"

say "== Claude profile migration (run on the HOST, repo container stopped)"
say "   workspace : $WS   (slug $BASE)"
say "   source    : $SRC   (read only)"
say "   profile   : $DEST"
if [ "$APPLY" = 1 ]; then say "   mode      : APPLY"; else say "   mode      : DRY-RUN — nothing is written (add --apply)"; fi

say ""
say "-- user config (only what the profile does not have yet)"
for e in $CONFIG; do
  [ -e "$SRC/$e" ] || continue
  if [ -e "$DEST/$e" ]; then say "   keep  $e (already in the profile)"; else say "   COPY  $e"; fi
done

say ""
say "-- projects/ (transcripts, subagents, memory)"
SELECTED='' SESSIONS='' LIVE='' UNKNOWN=''
pick() {  # name why — select projects/<name> for the copy
  d="$SRC/projects/$1"
  SELECTED="$SELECTED $1"
  for f in "$d"/*.jsonl; do
    [ -f "$f" ] || continue
    sid=${f##*/}; SESSIONS="$SESSIONS ${sid%.jsonl}"
  done
  if [ -e "$DEST/projects/$1" ]; then verb="MERGE"; else verb="COPY "; fi
  mem=''; [ ! -d "$d/memory" ] || mem=", with memory/"
  say "   $verb projects/$1  ($(count_files "$d") files, $(size_kb "$d") KB, $2$mem)"
  if [ -n "$(find "$d" -type f -mmin -2 2>/dev/null | head -n 1)" ]; then LIVE="$LIVE projects/$1"; fi
}
# Pass 1 — slug dirs with transcripts: the recorded "cwd" decides.
for d in "$SRC/projects/$BASE" "$SRC/projects/$BASE"-*; do
  [ -d "$d" ] || continue
  name=${d##*/}
  n_in=0 n_out=0 other=''
  for f in "$d"/*.jsonl; do
    [ -f "$f" ] || continue
    c=$(first_cwd "$f")
    [ -n "$c" ] || continue
    if belongs "$c"; then n_in=$((n_in + 1)); else n_out=$((n_out + 1)); other=$c; fi
  done
  if [ "$n_in" -gt 0 ]; then
    warn=''; [ "$n_out" -eq 0 ] || warn=" — WARNING: $n_out ran in $other (same slug)"
    pick "$name" "$n_in session(s) in $WS$warn"
  elif [ "$n_out" -gt 0 ]; then
    say "   skip  projects/$name  (its sessions ran in $other, another workspace)"
  elif [ "$name" = "$BASE" ]; then
    pick "$name" "no transcript"
  else
    UNKNOWN="$UNKNOWN $name"
  fi
done
# Pass 2 — dirs holding only <session-id>/ artefacts (workflows of an agent
# run in a subdir or worktree): they follow the session's transcript owner.
for name in $UNKNOWN; do
  d="$SRC/projects/$name"
  l_in=0 l_out=0 owner=''
  for sub in "$d"/*/; do
    [ -d "$sub" ] || continue
    sid=${sub%/}; sid=${sid##*/}
    case " $SESSIONS " in *" $sid "*) l_in=$((l_in + 1)); continue ;; esac
    for t in "$SRC/projects"/*/"$sid.jsonl"; do
      [ -f "$t" ] || continue
      l_out=$((l_out + 1)); owner=${t%/*}; owner=${owner##*/}; break
    done
  done
  if [ "$l_in" -gt 0 ]; then
    warn=''; [ "$l_out" -eq 0 ] || warn=" — WARNING: $l_out belong to projects/$owner"
    pick "$name" "artefacts of $l_in session(s) of this repo$warn"
  elif [ -n "$owner" ]; then
    say "   skip  projects/$name  (artefacts of a session of projects/$owner)"
  else
    say "   skip  projects/$name  (no transcript links it to $WS — check it by hand)"
  fi
done
[ -n "$SELECTED" ] || say "   (no project dir for $WS — nothing to copy)"

say ""
say "-- history.jsonl (prompt history, up-arrow)"
if [ -f "$SRC/history.jsonl" ]; then
  n_hist=$(grep -c -F -e "$HP1" -e "$HP2" "$SRC/history.jsonl" || true)
  say "   MERGE ${n_hist:-0} line(s) whose project is $WS or below (of $(wc -l < "$SRC/history.jsonl" | tr -d ' ') in total)"
else
  say "   (no history.jsonl in the source)"
fi
if [ -f "$DEST/history.jsonl" ] && [ -n "$(find "$DEST/history.jsonl" -mmin -2 2>/dev/null)" ]; then
  LIVE="$LIVE $DEST/history.jsonl"
fi

say ""
say "-- file-history/ (/rewind checkpoints of those sessions)"
n_fh=0
for sid in $SESSIONS; do
  if [ -d "$SRC/file-history/$sid" ]; then n_fh=$((n_fh + 1)); fi
done
say "   COPY  $n_fh session checkpoint dir(s)"

say ""
say "-- never copied: .credentials.json* (/login again), backups/ (other accounts'"
say "   ~/.claude.json), .device-keys.json, runtime state (sessions/, ide/, daemon*, ...)"

if [ -n "$LIVE" ]; then
  say ""
  say "!! modified less than 2 minutes ago:$LIVE"
  say "!! a session is probably running: stop the container(s) before --apply"
fi
if [ "$APPLY" != 1 ]; then
  say ""
  say "Dry-run only. Re-run with --apply to copy."
  exit 0
fi
if [ -n "$LIVE" ] && [ "$FORCE" != 1 ]; then
  die "modified less than 2 minutes ago:$LIVE — stop the container(s) first (or --force)"
fi

# --- apply -------------------------------------------------------------------
# Copies what the destination does not have yet; never overwrites, never
# deletes, never writes to $SRC.
copy_absent() {  # src dest
  if [ ! -e "$2" ]; then
    mkdir -p "${2%/*}"
    cp -R -p "$1" "$2"
    return 0
  fi
  (cd "$1" && find . -type d) | while IFS= read -r sub; do mkdir -p "$2/$sub"; done
  (cd "$1" && find . -type f) | while IFS= read -r f; do
    if [ ! -e "$2/$f" ]; then cp -p "$1/$f" "$2/$f"; fi
  done
}
verify_tree() {  # src dest -> "identical differ missing"
  (cd "$1" && find . -type f) | {
    same=0 differ=0 miss=0
    while IFS= read -r f; do
      if [ ! -f "$2/$f" ]; then miss=$((miss + 1))
      elif cmp -s "$1/$f" "$2/$f"; then same=$((same + 1))
      else differ=$((differ + 1)); fi
    done
    printf '%s %s %s\n' "$same" "$differ" "$miss"
  }
}

mkdir -p "$DEST"
fail=0
say ""
say "== Applying"
for e in $CONFIG; do
  if [ -e "$SRC/$e" ] && [ ! -e "$DEST/$e" ]; then cp -R -p "$SRC/$e" "$DEST/$e"; say "   copied $e"; fi
done

for name in $SELECTED; do
  existed=0
  if [ -e "$DEST/projects/$name" ]; then existed=1; fi
  copy_absent "$SRC/projects/$name" "$DEST/projects/$name"
  set -- $(verify_tree "$SRC/projects/$name" "$DEST/projects/$name")
  if [ "$existed" = 0 ] && { [ "$2" -ne 0 ] || [ "$3" -ne 0 ]; }; then
    fail=1; status="FAIL: source changed during the copy (live session?) — stop the container, delete $DEST/projects/$name, re-run"
  elif [ "$existed" = 1 ]; then
    status="merged (a differing file = the profile's newer copy, kept)"
  else
    status="OK"
  fi
  say "   projects/$name: $1 identical, $2 differ, $3 missing — $status"
done

for sid in $SESSIONS; do
  if [ -d "$SRC/file-history/$sid" ]; then copy_absent "$SRC/file-history/$sid" "$DEST/file-history/$sid"; fi
done
say "   file-history: $n_fh session dir(s)"

if [ -f "$SRC/history.jsonl" ]; then
  TAB=$(printf '\t')
  tmp="$DEST/.history.jsonl.migrate.$$"
  {
    if [ -f "$DEST/history.jsonl" ]; then cat "$DEST/history.jsonl"; fi
    grep -F -e "$HP1" -e "$HP2" "$SRC/history.jsonl" || true
  } | awk '!seen[$0]++' \
    | awk -v t="$TAB" '{ ts = 0; if (match($0, /"timestamp":[0-9]+/)) ts = substr($0, RSTART + 12, RLENGTH - 12); print ts t $0 }' \
    | sort -s -t "$TAB" -k1,1n | cut -f2- > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$DEST/history.jsonl"
  lost=$( (grep -F -e "$HP1" -e "$HP2" "$SRC/history.jsonl" || true) | grep -c -F -x -v -f "$DEST/history.jsonl" || true)
  if [ "${lost:-0}" -ne 0 ]; then fail=1; hs="FAIL: $lost line(s) missing"; else hs="OK"; fi
  say "   history.jsonl: ${n_hist:-0} line(s) for $WS, all present in the profile — $hs"
fi

say ""
if [ "$fail" -ne 0 ]; then say "== FAILED — see above. $SRC was not modified."; exit 1; fi
say "== Done. $SRC was not modified."
say "   Next: copier update --data claude_profile=$PROFILE, rebuild the container,"
say "   /login with this profile's account, then check: claude --resume"
