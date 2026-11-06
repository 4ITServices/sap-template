#!/bin/bash
# =============================================================================
# lib-tunnels.sh — tunnels SSH supervisés vers des machines relais
# (TEMPLATE-OWNED : mis à jour par `copier update`, ne pas modifier ici).
#
# Cas type : des SAP joignables seulement depuis une VM qui porte un VPN. La VM
# ne sert que de relais : `ssh -L 127.0.0.1:PORT:HÔTE_SAP:PORT` fait résoudre
# et joindre HÔTE_SAP PAR LA VM ; les serveurs MCP tournent dans le container
# et parlent à 127.0.0.1. Rien n'est installé sur la VM, aucune identité SAP
# n'y est déposée.
#
# Configuration : .devcontainer/tunnels.conf (PROJET, jamais écrasé)
#   NOM  UTILISATEUR@HÔTE[:PORT_SSH]  PORT_LOCAL  CIBLE:PORT  [VARIABLE_CLÉ]
# Les lignes d'un même HÔTE partagent UNE session ssh. VARIABLE_CLÉ nomme la
# variable qui porte la clé privée : son contenu (PEM, ou base64 sur une ligne
# — Key Vault, `.env.refs`) ou un chemin de fichier (`.env`). La clé passe
# dans un ssh-agent propre au tunnel, par l'entrée standard : jamais sur
# disque, jamais en argument. Clés d'hôte : .devcontainer/tunnels.known_hosts
# (PROJET, versionné ; `tunnel.sh epingler`).
#
# /etc/hosts : une CIBLE nommée (pas une IP) dont le PORT_LOCAL vaut le port
# cible y est mise en 127.0.0.1, pour que l'URL garde le vrai nom (certificat
# TLS, en-tête Host) tout en passant par le tunnel.
#
# État : ~/.local/state/devcontainer/tunnels/<hôte>.{pid,log} ; agent :
# /tmp/tunnels-<uid>/<empreinte de l'hôte>.agent (dossier 700)
# Contraintes : ne jamais faire échouer le cycle de vie (rendent 0), ne jamais
# afficher une valeur.
# =============================================================================

[ -n "${_LIB_TUNNELS_LOADED:-}" ] && return 0
_LIB_TUNNELS_LOADED=1

_TUNNELS_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-tunnels.sh"
TUNNELS_CONF="${TUNNELS_CONF:-$(dirname "$_TUNNELS_LIB")/tunnels.conf}"
TUNNELS_KNOWN_HOSTS="${TUNNELS_KNOWN_HOSTS:-$(dirname "$_TUNNELS_LIB")/tunnels.known_hosts}"
TUNNELS_STATE="${TUNNELS_STATE:-$HOME/.local/state/devcontainer/tunnels}"
TUNNELS_HOSTS_FILE="${TUNNELS_HOSTS_FILE:-/etc/hosts}"
TUNNELS_WAIT="${TUNNELS_WAIT:-20}"

# _tunnels_lignes — lignes utiles de la configuration : NOM HÔTE PL CIBLE [CLÉ]
_tunnels_lignes() {
  [ -f "$TUNNELS_CONF" ] || return 0
  local l c
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%%#*}"; l="${l//$'\r'/}"
    read -r -a c <<<"$l"
    [ "${#c[@]}" -ge 4 ] || continue
    printf '%s\n' "${c[*]}"
  done <"$TUNNELS_CONF"
}

# _tunnels_epingle HÔTE — sa clé d'hôte est-elle dans tunnels.known_hosts ?
_tunnels_epingle() {
  local c="${1#*@}"
  [ "${c%:*}" != "$c" ] && c="[${c%:*}]:${c##*:}"
  ssh-keygen -F "$c" -f "$TUNNELS_KNOWN_HOSTS" >/dev/null 2>&1
}

_tunnels_hotes() { _tunnels_lignes | awk '{ print $2 }' | awk '!vu[$0]++'; }
_tunnels_slug()  { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
_tunnels_port_ouvert() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

_tunnels_vivant() {  # HÔTE
  local pid
  pid="$(cat "$TUNNELS_STATE/$(_tunnels_slug "$1").pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# _tunnels_args HÔTE — options -L de cet hôte, une par ligne
_tunnels_args() {
  _tunnels_lignes | awk -v h="$1" '$2 == h { print "-L"; print "127.0.0.1:" $3 ":" $4 }'
}

# _tunnels_cle HÔTE — nom de la variable de clé (la première renseignée)
_tunnels_cle() { _tunnels_lignes | awk -v h="$1" '$2 == h && $5 != "" { print $5; exit }'; }

# _tunnels_sock HÔTE — socket de l'agent : chemin COURT (limite des sockets
# Unix : 108 octets), dans un dossier à nous seuls (refus sinon).
_tunnels_sock() {
  local d="${TUNNELS_SOCK_DIR:-/tmp/tunnels-$(id -u)}"
  mkdir -p -m 700 "$d" 2>/dev/null
  if [ ! -O "$d" ] || [ "$(stat -c %a "$d" 2>/dev/null)" != 700 ]; then
    echo "  tunnel : $d n'est pas à nous seuls (700) — refus" >&2; return 1
  fi
  printf '%s/%s.agent\n' "$d" "$(printf '%s' "$1" | sha256sum | cut -c1-12)"
}

# _tunnels_agent HÔTE — ssh-agent propre à l'hôte, clé chargée. Rend 1 si
# aucune clé n'est disponible (ni dans l'agent, ni dans la variable).
_tunnels_agent() {
  local hote="$1" sock var val rc
  sock="$(_tunnels_sock "$hote")" || return 1
  SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then printf '%s\n' "$sock"; return 0; fi        # clé déjà chargée
  if [ "$rc" = 2 ]; then                                            # pas d'agent : en lancer un
    rm -f "$sock"
    # env -i : l'agent (processus durable) n'hérite pas des secrets du cycle de vie
    env -i PATH="$PATH" ssh-agent -a "$sock" >/dev/null 2>&1 || { echo "  tunnel $hote : ssh-agent impossible" >&2; return 1; }
  fi
  var="$(_tunnels_cle "$hote")"
  val="${var:+${!var:-}}"
  if [ -z "$val" ]; then
    echo "  tunnel $hote : aucune clé${var:+ ($var vide ici)} — sous Key Vault : secrets run -- bash .devcontainer/tunnel.sh start" >&2
    return 1
  fi
  case "$val" in
    -----BEGIN*) printf '%s\n' "$val" | SSH_AUTH_SOCK="$sock" ssh-add - >/dev/null 2>&1 ;;
    /*|"~"/*)    SSH_AUTH_SOCK="$sock" ssh-add "${val/#\~/$HOME}" >/dev/null 2>&1 ;;
    *)           printf '%s' "$val" | base64 -d 2>/dev/null | SSH_AUTH_SOCK="$sock" ssh-add - >/dev/null 2>&1 ;;
  esac || { echo "  tunnel $hote : la clé de $var est illisible (PEM, base64 d'un PEM, ou chemin)" >&2; return 1; }
  echo "  tunnel $hote : clé de $var chargée dans l'agent (en mémoire)" >&2
  printf '%s\n' "$sock"
}

# _tunnels_hosts — met les CIBLES nommées en 127.0.0.1 (port local = port cible)
_tunnels_hosts() {
  local nom hote pl cible h p
  while read -r nom hote pl cible _; do
    h="${cible%:*}"; p="${cible##*:}"
    case "$h" in localhost|127.*) continue ;; esac   # boucle locale (ex. serveur sur le relais)
    case "$h" in *[!0-9.]*) ;; *) continue ;; esac   # adresse IP : rien à nommer
    if [ "$pl" != "$p" ]; then
      echo "  /etc/hosts : $h non mappé ($nom : port local $pl ≠ $p) — l'URL doit viser 127.0.0.1:$pl"
      continue
    fi
    if grep -qE "^127\.0\.0\.1[[:space:]]+([^#]*[[:space:]])?${h//./\\.}([[:space:]]|$)" "$TUNNELS_HOSTS_FILE" 2>/dev/null; then
      continue
    fi
    if [ -w "$TUNNELS_HOSTS_FILE" ]; then
      printf '127.0.0.1 %s  # tunnels.conf\n' "$h" >>"$TUNNELS_HOSTS_FILE"
    else
      printf '127.0.0.1 %s  # tunnels.conf\n' "$h" | sudo -n tee -a "$TUNNELS_HOSTS_FILE" >/dev/null 2>&1 \
        || { echo "  /etc/hosts : impossible d'ajouter $h (sudo ?) — l'URL doit viser 127.0.0.1:$pl"; continue; }
    fi
    echo "  /etc/hosts : $h → 127.0.0.1"
  done < <(_tunnels_lignes)
}

# _tunnels_superviser HÔTE SOCK — boucle détachée (session à part) : ssh -N
# tient les redirections, relancé s'il tombe (5 s, puis jusqu'à 60 s).
_tunnels_superviser() {
  local hote="$1" sock="$2" cible port attente=5 debut args=()
  echo $$ >"$TUNNELS_STATE/$(_tunnels_slug "$hote").pid"
  cible="${hote%:*}"; port=22
  [ "$cible" != "$hote" ] && port="${hote##*:}"
  mapfile -t args < <(_tunnels_args "$hote")
  while true; do
    debut=$(date +%s)
    echo "[$(date -Is)] ssh $cible (port $port) : ${#args[@]} argument(s) de redirection"
    SSH_AUTH_SOCK="$sock" ssh -N -p "$port" \
      -o BatchMode=yes -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$TUNNELS_KNOWN_HOSTS" \
      -o ConnectTimeout=15 "${args[@]}" "$cible"
    echo "[$(date -Is)] tunnel tombé (code $?) — relance dans ${attente} s"
    sleep "$attente"
    if [ $(( $(date +%s) - debut )) -gt 120 ]; then attente=5; elif [ "$attente" -lt 60 ]; then attente=$((attente * 2)); fi
  done
}

tunnels_start() {
  local hote sock slug pl i ok
  mkdir -p "$TUNNELS_STATE" && chmod 700 "$TUNNELS_STATE"
  [ -n "$(_tunnels_lignes)" ] || { echo "  (aucun tunnel dans tunnels.conf)"; return 0; }
  _tunnels_hosts
  while read -r hote; do
    slug="$(_tunnels_slug "$hote")"
    if _tunnels_vivant "$hote"; then echo "  tunnel $hote : déjà actif (PID $(cat "$TUNNELS_STATE/$slug.pid"))"; continue; fi
    if ! _tunnels_epingle "$hote"; then
      echo "  tunnel $hote : clé d'hôte non épinglée — bash .devcontainer/tunnel.sh epingler (vérifier l'empreinte)"
      continue
    fi
    sock="$(_tunnels_agent "$hote")" || continue
    env -i HOME="$HOME" PATH="$PATH" USER="${USER:-}" LANG="${LANG:-C.UTF-8}" \
      TUNNELS_CONF="$TUNNELS_CONF" TUNNELS_KNOWN_HOSTS="$TUNNELS_KNOWN_HOSTS" TUNNELS_STATE="$TUNNELS_STATE" \
      setsid -f bash -c 'source "$1"; _tunnels_superviser "$2" "$3"' _ "$_TUNNELS_LIB" "$hote" "$sock" \
      >>"$TUNNELS_STATE/$slug.log" 2>&1 </dev/null
    ok=1
    for pl in $(_tunnels_lignes | awk -v h="$hote" '$2 == h { print $3 }'); do
      i=0
      until _tunnels_port_ouvert "$pl"; do
        i=$((i + 1)); [ "$i" -ge "$TUNNELS_WAIT" ] && { ok=0; break; }; sleep 1
      done
    done
    if [ "$ok" = 1 ]; then
      echo "  tunnel $hote : actif ($(_tunnels_lignes | awk -v h="$hote" '$2 == h { printf "%s 127.0.0.1:%s → %s  ", $1, $3, $4 }'))"
    else
      echo "  ATTENTION tunnel $hote : port(s) muet(s) après ${TUNNELS_WAIT} s — journal : $TUNNELS_STATE/$slug.log"
      echo "            (relais arrêté ? VPN non monté sur le relais ? IP refusée ? port local déjà pris ?)"
      tail -n 3 "$TUNNELS_STATE/$slug.log" 2>/dev/null | sed 's/^/    | /'
    fi
  done < <(_tunnels_hotes)
  return 0
}

tunnels_stop() {
  local hote slug pid i
  while read -r hote; do
    slug="$(_tunnels_slug "$hote")"
    pid="$(cat "$TUNNELS_STATE/$slug.pid" 2>/dev/null)" || continue
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
      echo "  tunnel $hote : arrêté"
    fi
    rm -f "$TUNNELS_STATE/$slug.pid"
  done < <(_tunnels_hotes)
  # attendre la libération effective des ports (sinon un start immédiat échoue)
  for pl in $(_tunnels_lignes | awk '{ print $3 }'); do
    i=0; while _tunnels_port_ouvert "$pl" && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
  done
  return 0
}

tunnels_status() {
  local nom hote pl cible etat
  [ -n "$(_tunnels_lignes)" ] || { echo "  (aucun tunnel dans tunnels.conf)"; return 0; }
  while read -r hote; do
    _tunnels_vivant "$hote" && etat="ACTIF (PID $(cat "$TUNNELS_STATE/$(_tunnels_slug "$hote").pid"))" || etat="arrêté"
    echo "  $hote : superviseur $etat"
  done < <(_tunnels_hotes)
  while read -r nom hote pl cible _; do
    _tunnels_port_ouvert "$pl" && etat="EN ÉCOUTE" || etat="fermé"
    echo "    $nom  127.0.0.1:$pl → $cible : $etat"
  done < <(_tunnels_lignes)
  return 0
}

# tunnels_epingler — ssh-keyscan de chaque hôte vers tunnels.known_hosts, avec
# les empreintes à comparer à celles du relais AVANT de versionner le fichier.
tunnels_epingler() {
  local hote cible port tmp
  tmp="$(mktemp)"
  while read -r hote; do
    cible="${hote#*@}"; port=22
    [ "${cible%:*}" != "$cible" ] && { port="${cible##*:}"; cible="${cible%:*}"; }
    if ssh-keyscan -p "$port" -T 10 "$cible" 2>/dev/null >"$tmp" && [ -s "$tmp" ]; then
      cat "$tmp" >>"$TUNNELS_KNOWN_HOSTS"
      echo "  $cible : clé(s) d'hôte ajoutée(s) ; empreintes à vérifier sur le relais :"
      ssh-keygen -lf "$tmp" | sed 's/^/    /'
    else
      echo "  $cible : injoignable sur le port $port (relais arrêté ? IP refusée ?)"
    fi
  done < <(_tunnels_hotes)
  rm -f "$tmp"
  [ -f "$TUNNELS_KNOWN_HOSTS" ] && sort -u -o "$TUNNELS_KNOWN_HOSTS" "$TUNNELS_KNOWN_HOSTS"
  return 0
}
