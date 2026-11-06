#!/bin/bash
# =============================================================================
# mcp-instance.sh — instances SUPPLÉMENTAIRES d'un serveur MCP déjà installé
# dans /opt (mcp-servers.conf), chacune vers un autre système (TEMPLATE-OWNED).
#
# Configuration : .devcontainer/mcp-instances.conf (PROJET, jamais écrasé)
#   NOM  SERVEUR  PORT  PRÉFIXE
#   ex.  sap-adt-bca  sap-adt-mcp  8020  BCA
# L'instance NOM lance /opt/SERVEUR/scripts/mcp-server.sh avec :
#   - les variables PRÉFIXE_X du projet reprises en X (BCA_SAP_URL → SAP_URL) ;
#   - SANS les autres variables du projet (.env.refs / .env) ni réglages
#     d'écoute hérités (MCP_AUTH_TOKEN…), et les clés du .env du serveur
#     qu'elle ne pose pas remises à vide (repli de pydantic-settings) ;
#   - MCP_PORT=PORT sur 127.0.0.1, PID et journal propres
#     (/opt/SERVEUR/.mcp-server-NOM.pid, logs/server-NOM.log).
# Le même mécanisme que mcp-server-ecc.sh de sap-adt-mcp, sans fichier .env.
#
#   bash .devcontainer/mcp-instance.sh start|stop|restart|status [NOM]
# Sous Key Vault, les variables ne sont là que sous `secrets run` (post-start
# les a) : secrets run -- bash .devcontainer/mcp-instance.sh restart sap-adt-bca
# Aucune valeur n'est affichée ni passée en argument.
# =============================================================================
set -u
ICI="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
WORKSPACE_DIR="${WORKSPACE_DIR:-$(dirname "$ICI")}"
CONF="${MCP_INSTANCES_CONF:-$ICI/mcp-instances.conf}"
OPT="${MCP_OPT_DIR:-/opt}"
ECOUTE=(MCP_AUTH_TOKEN MCP_TLS_CERT MCP_TLS_KEY MCP_ALLOWED_HOSTS MCP_ALLOWED_ORIGINS)

noms_de() {  # FICHIER — noms des variables qu'il déclare
  [ -f "$1" ] && sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=.*/\2/p' "$1"
}

instance() {  # VERBE NOM SERVEUR PORT PRÉFIXE
  local verbe="$1" nom="$2" serveur="$3" port="$4" pre="$5" lanceur v n
  lanceur="$OPT/$serveur/scripts/mcp-server.sh"
  case "$port" in ''|*[!0-9]*) echo "[mcp] $nom : port « $port » invalide" >&2; return 0 ;; esac
  case "$pre" in ''|*[!A-Za-z0-9_]*) echo "[mcp] $nom : préfixe « $pre » invalide" >&2; return 0 ;; esac
  [ -x "$lanceur" ] || { echo "[mcp] $nom : $lanceur absent ($serveur doit figurer dans mcp-servers.conf)"; return 0; }
  (
    declare -A val=()
    for v in $(compgen -v "${pre}_"); do val["${v#"${pre}"_}"]="${!v}"; done
    if [ "$verbe" = start ] || [ "$verbe" = restart ]; then
      [ "${#val[@]}" -gt 0 ] || { echo "[mcp] $nom : aucune variable ${pre}_* (Key Vault : secrets run -- …)"; exit 0; }
    fi
    # rien du projet ni d'une autre instance : seulement PRÉFIXE_*
    for n in $(noms_de "$WORKSPACE_DIR/.env.refs") $(noms_de "$WORKSPACE_DIR/.env") \
             $(compgen -v SAP_) "${ECOUTE[@]}" $(compgen -v "${pre}_"); do
      unset "$n" 2>/dev/null
    done
    for n in "${!val[@]}"; do export "$n=${val[$n]}"; done
    for n in $(noms_de "$OPT/$serveur/.env") "${ECOUTE[@]}"; do
      [ -n "${!n+x}" ] || export "$n="
    done
    export MCP_HOST=127.0.0.1 MCP_PORT="$port"
    export MCP_PID_FILE="$OPT/$serveur/.mcp-server-$nom.pid"
    export MCP_LOG_FILE="$OPT/$serveur/logs/server-$nom.log"
    export MCP_HEALTH_URL="http://127.0.0.1:$port/.well-known/oauth-protected-resource"
    export MCP_BASE_URL="http://127.0.0.1:$port/mcp"
    [ "$verbe" = start ] && echo "[mcp] $nom : $serveur sur 127.0.0.1:$port, variables ${pre}_* (${#val[@]})"
    "$lanceur" "$verbe"
  )
}

verbe="${1:-status}"; cible="${2:-}"
case "$verbe" in start|stop|restart|status) ;; *) echo "usage : $0 start|stop|restart|status [NOM]" >&2; exit 2 ;; esac
[ -f "$CONF" ] || exit 0
while IFS= read -r l <&9 || [ -n "$l" ]; do
  l="${l%%#*}"; l="${l//$'\r'/}"
  read -r nom serveur port pre _ <<<"$l"
  [ -n "${nom:-}" ] || continue
  [ -z "$cible" ] || [ "$cible" = "$nom" ] || continue
  instance "$verbe" "$nom" "${serveur:-}" "${port:-}" "${pre:-}"
done 9<"$CONF"
exit 0
