#!/usr/bin/env bash
# =============================================================================
# Local feature — Google Cloud CLI (gcloud + bq + gsutil)
# -----------------------------------------------------------------------------
# Replaces ghcr.io/dhoeric/features/google-cloud-cli (v1.0.1, May 2023,
# abandoned). That feature imports the repository key with `apt-key`, which
# recent Debian base images no longer ship -> "apt-key: command not found"
# (exit 127) and a failed container build.
#
# Here: the documented modern method (cloud.google.com/sdk/docs/install#deb).
# The key is imported with `gpg --dearmor` into a keyring referenced by
# `signed-by=` in the sources list. No dependency on apt-key.
#
# Run by the devcontainer framework AT BUILD TIME, as root. No sudo needed.
# =============================================================================
set -euo pipefail

echo "(*) Installing Google Cloud CLI (gcloud + bq + gsutil)..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
# ca-certificates + curl: TLS download of the key; gnupg: `gpg --dearmor`.
apt-get install -y --no-install-recommends ca-certificates curl gnupg

# Google's repository key -> binary keyring (replaces `apt-key add`).
install -m 0755 -d /usr/share/keyrings
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
chmod 0644 /usr/share/keyrings/cloud.google.gpg

echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
  > /etc/apt/sources.list.d/google-cloud-sdk.list

apt-get update -y
# CLOUDSDK_SKIP_PY_COMPILATION=1 skips the (long) precompilation of gcloud's
# .py files. Base package only: no GKE plugin for a BigQuery workspace.
CLOUDSDK_SKIP_PY_COMPILATION=1 \
  apt-get install -y --no-install-recommends google-cloud-cli

# Keep the image layer small: drop the apt index cache.
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "(*) Done. $(gcloud --version | head -n1)"
