#!/usr/bin/env bash
# =============================================================================
# secrets-sync.sh — recopie le lanceur `secrets` de 4ITServices/4it-azure
# -----------------------------------------------------------------------------
# Le lanceur vit dans 4it-azure (outils/secrets). Le modèle en embarque une
# copie FIGÉE sur un commit, rendue dans les projets en secrets_source=keyvault
# (.devcontainer/secrets/). Ce script remplace cette copie par celle d'un
# commit, d'une branche ou d'une étiquette de 4it-azure, et note le commit
# exact dans SOURCE.
#
# Usage   : scripts/secrets-sync.sh [REF]      (défaut : main)
# Prérequis : gh connecté avec un accès en lecture à 4ITServices/4it-azure
#             (GH_TOKEN=kv://perso/github-pat convient : secrets run -f … -- …)
# =============================================================================
set -euo pipefail

REPO="4ITServices/4it-azure"
REF="${1:-main}"
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
DEST="$ROOT/template/.devcontainer/{% if secrets_source == 'keyvault' %}secrets{% endif %}"

SHA="$(gh api "repos/$REPO/commits/$REF" --jq .sha)"
mkdir -p "$DEST"
for f in secrets personnes.conf README.md; do
  gh api "repos/$REPO/contents/outils/secrets/$f?ref=$SHA" \
    -H 'Accept: application/vnd.github.raw' >"$DEST/$f.tmp"
  mv "$DEST/$f.tmp" "$DEST/$f"
done
chmod +x "$DEST/secrets"
bash -n "$DEST/secrets"
printf '%s\n' \
  "# Copie figée de $REPO/outils/secrets — ne pas modifier ici." \
  "# Mise à jour : scripts/secrets-sync.sh [REF] (dans sap-template)." \
  "repo=$REPO" "ref=$REF" "commit=$SHA" >"$DEST/SOURCE"
echo "lanceur secrets recopié depuis $REPO@$SHA ($REF)"
