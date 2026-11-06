#!/bin/bash
# =============================================================================
# tunnel.sh — tunnels SSH de .devcontainer/tunnels.conf (TEMPLATE-OWNED).
# post-start les démarre ; à la main :
#
#   bash .devcontainer/tunnel.sh status | start | stop | restart | epingler
#
# Sous Key Vault, la clé n'est dans l'environnement que sous `secrets run` :
#   secrets run -- bash .devcontainer/tunnel.sh start
# (inutile tant que l'agent du tunnel garde la clé, ex. après post-start).
# Détails : .devcontainer/lib-tunnels.sh et .devcontainer/README.md (« Tunnels »).
# =============================================================================
source "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib-tunnels.sh"
case "${1:-status}" in
  start)    tunnels_start ;;
  stop)     tunnels_stop ;;
  restart)  tunnels_stop; tunnels_start ;;
  status)   tunnels_status ;;
  epingler) tunnels_epingler ;;
  *) echo "usage : $0 status|start|stop|restart|epingler" >&2; exit 2 ;;
esac
