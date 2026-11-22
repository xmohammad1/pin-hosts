#!/usr/bin/env bash
# pin-hosts.sh - pin a domain's IPs (e.g. the REALITY dest www.apple.com) in /etc/hosts,
# so Xray stops sending a DNS query for it on every inbound connection.
#
#  * resolves through the upstream DNS servers, never through /etc/hosts or a local
#    stub that reads it (systemd-resolved and dnsmasq both answer from /etc/hosts)
#  * keeps only IPs that pass a real TLS handshake with a valid certificate for the domain
#  * refreshes from cron once an hour; if no IP passes, the old entries are kept as they are
#  * also patches the hosts file of running host-network Docker containers (pg-node etc.):
#    Docker copies /etc/hosts into them only when the container starts
#
# usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh) install
#   pin-hosts.sh install [domain,...]        asks for the domains if none are given (Enter = www.apple.com)
#   pin-hosts.sh status                      pinned IPs, TLS check, container sync
#   pin-hosts.sh verify [seconds]            count DNS queries for the domains (tcpdump)
#   pin-hosts.sh update                      refresh now (cron runs this)
#   pin-hosts.sh uninstall                   remove everything
set -uo pipefail

REPO_RAW=https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh
SELF=/usr/local/sbin/pin-hosts.sh
CONF=/etc/pin-hosts.conf
CRON=/etc/cron.d/pin-hosts
HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}
TAG=pin-hosts

# defaults; /etc/pin-hosts.conf overrides them
DOMAINS="www.apple.com"
KEEP=2          # IPs kept per address family
PREFER=6        # family listed first (6 or 4); Go/Xray dials the first listed family first
IPV6=auto       # auto | on | off
RESOLVER=auto   # auto = the system's upstream DNS servers, or a list like "185.12.64.1 8.8.8.8"
CONTAINERS=auto # auto = every running host-network container | none | "name1 name2"
INTERVAL=60     # minutes between refreshes: 1-59, or whole hours (60, 120...); run install again after changing it
[ -r "$CONF" ] && . "$CONF"

log()  { echo "[$TAG] $*" >&2; logger -t "$TAG" -- "$*" 2>/dev/null || true; }
die()  { log "ERROR: $*"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }
has_tty() { (exec </dev/tty) 2>/dev/null; }

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT

# ---------- DNS + health check ----------

resolvers() { # upstream DNS servers to ask (loopback stubs skipped: they may read /etc/hosts)
  if [ "$RESOLVER" != auto ]; then printf '%s\n' $RESOLVER; return; fi
  local f
  for f in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
    [ -r "$f" ] && awk '$1=="nameserver" && $2!~/^(127\.|0\.0\.0\.0$|::1$)/ {print $2}' "$f"
  done
  printf '%s\n' 8.8.8.8 1.1.1.1   # fallback; 8.8.8.8 sends EDNS client-subnet, so the CDN still maps by location
}

resolve() { # $1 domain, $2 A|AAAA -> IPs straight from upstream DNS
  local s out ips re='^[0-9.]+$'
  [ "$2" = AAAA ] && re='^[0-9a-fA-F:]+$'
  for s in $(resolvers | awk '!seen[$0]++'); do
    out=$(dig +short +time=2 +tries=1 "@$s" "$1" "$2" 2>/dev/null) || continue
    ips=$(grep -E "$re" <<<"$out")
    [ -n "$ips" ] && { echo "$ips"; return 0; }
  done
  return 1
}

probe() { # $1 domain, $2 ip -> TLS handshake seconds, only if the IP serves a valid cert for $1
  local a=$2 code t
  [[ $a == *:* ]] && a="[$a]"
  read -r code t < <(curl -sS -o /dev/null -I --connect-timeout 3 -m 8 --resolve "$1:443:$a" \
    -w '%{http_code} %{time_appconnect}\n' "https://$1/" 2>/dev/null)
  [ "${code:-000}" != 000 ] && echo "$t"
}

have_v6() {
  case $IPV6 in on) return 0 ;; off) return 1 ;; esac
  ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1
}

# ---------- domain list ----------

parse_domains() { # "a.com, b.com c.com" (URLs are fine too) -> validated, de-duplicated, space-separated
  local d out="" words
  read -ra words <<<"$(tr ',;' '  ' <<<"$*" | tr '[:upper:]' '[:lower:]')"
  for d in "${words[@]}"; do
    d=${d#*://}; d=${d%%/*}; d=${d%%:*}; d=${d%.}
    [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$ ]] || { log "invalid domain: $d"; return 1; }
    [[ " $out " == *" $d "* ]] || out+="${out:+ }$d"
  done
  [ -n "$out" ] && echo "$out"
}

ask_domains() { # $1 default list -> list typed on the terminal; Enter keeps the default
  local ans list
  while :; do
    printf 'Domains to pin in /etc/hosts, comma-separated [%s]: ' "${1// /, }" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    if [ -z "${ans//[[:space:],]/}" ]; then echo "$1"; return; fi
    list=$(parse_domains "$ans") && { echo "$list"; return; }
    echo "  try again, for example: www.apple.com, tgju.org" >/dev/tty
  done
}

# ---------- managed block ----------

block_of() { # the managed block of hosts file $1
  sed -n "/^# BEGIN $TAG/,/^# END $TAG/p" "$1" 2>/dev/null
}

current_ips() { # IPs pinned now for domain $1
  block_of "$HOSTS_FILE" | awk -v d="$1" '$1!~/^#/ && $2==d {print $1}'
}

pick() { # $1 domain, $2 A|AAAA -> up to $KEEP healthy IPs: fresh DNS answers first, then old pins
  local d=$1 t=$2 ip ms fresh old
  fresh=$(resolve "$d" "$t")
  if [ "$t" = A ]; then old=$(current_ips "$d" | grep -v :); else old=$(current_ips "$d" | grep :); fi
  {
    for ip in $fresh; do ms=$(probe "$d" "$ip") && echo "0 $ms $ip"; done
    for ip in $old; do
      grep -qxF -- "$ip" <<<"$fresh" && continue
      ms=$(probe "$d" "$ip") && echo "1 $ms $ip"
    done
  } | sort -k1,1n -k2,2g | head -n "$KEEP" | awk '{print $3}'
}

build_block() { # prints the new managed block
  local d v4 v6 ip
  echo "# BEGIN $TAG - managed by $SELF (settings: $CONF)"
  for d in $DOMAINS; do
    v4=$(pick "$d" A)
    v6=""
    have_v6 && v6=$(pick "$d" AAAA)
    if [ -z "$v4$v6" ]; then
      if [ -n "$(current_ips "$d")" ]; then
        log "WARN $d: no IP passed the TLS check, keeping the old entries"
        block_of "$HOSTS_FILE" | awk -v d="$d" '$1!~/^#/ && $2==d'
      else
        log "WARN $d: no IP passed the TLS check, $d is left to DNS"
      fi
      continue
    fi
    if [ "$PREFER" = 4 ]; then set -- $v4 $v6; else set -- $v6 $v4; fi
    for ip; do printf '%-40s %s\n' "$ip" "$d"; done
  done
  echo "# END $TAG"
}

render() { # $1 hosts file, $2 block file ("" = just remove the block) -> new content on stdout
  local b e
  b=$(grep -c "^# BEGIN $TAG" "$1"); e=$(grep -c "^# END $TAG" "$1")
  [ "$b" = "$e" ] || { log "ERROR $1: unbalanced $TAG markers, fix it by hand"; return 1; }
  awk -v tag="$TAG" '
    $0 ~ ("^# BEGIN " tag) {skip=1; next}
    skip && $0 ~ ("^# END " tag) {skip=0; next}
    !skip' "$1"
  [ -n "$2" ] && cat "$2"
  return 0
}

put() { # $1 target, $2 new content -> rewrite in place, same inode (Docker bind-mounts these files)
  cmp -s "$1" "$2" && return 1
  cat "$2" > "$1"
}

container_files() { # "name hostsfile" for each target container
  [ "$CONTAINERS" = none ] && return 0
  command -v docker >/dev/null 2>&1 || return 0
  local ids id
  if [ "$CONTAINERS" = auto ]; then ids=$(docker ps -q 2>/dev/null); else ids=$CONTAINERS; fi
  for id in $ids; do
    docker inspect -f '{{.HostConfig.NetworkMode}} {{.Name}} {{.HostsPath}}' "$id" 2>/dev/null |
      awk -v mode="$CONTAINERS" 'mode!="auto" || $1=="host" {sub(/^\//, "", $2); print $2, $3}'
  done
}

apply_block() { # $1 block file ("" = remove) -> write it to the host and the containers
  local name f new=$TMPD/new
  [ -f "$HOSTS_FILE.$TAG.bak" ] || cp -p "$HOSTS_FILE" "$HOSTS_FILE.$TAG.bak"
  render "$HOSTS_FILE" "$1" > "$new" || return 1
  put "$HOSTS_FILE" "$new" && log "$HOSTS_FILE updated"
  while read -r name f; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then log "WARN container $name: hosts file not found (${f:-none})"; continue; fi
    render "$f" "$1" > "$new" && put "$f" "$new" && log "container $name: hosts updated"
  done < <(container_files)
}

# ---------- commands ----------

cmd_update() {
  need_root
  exec 9>"/run/$TAG.lock"
  flock -n 9 || { log "another run is active"; return 0; }
  build_block > "$TMPD/block"
  apply_block "$TMPD/block" || die "$HOSTS_FILE not updated"
  log "pinned -> $(grep -v '^#' "$TMPD/block" | awk '{print $1}' | tr '\n' ' ')"
}

cmd_status() {
  local ip d rest ms name f ns sync
  echo "settings : DOMAINS='$DOMAINS' KEEP=$KEEP PREFER=$PREFER IPV6=$IPV6 RESOLVER=$RESOLVER CONTAINERS=$CONTAINERS"
  echo "DNS used : $(resolvers | awk '!seen[$0]++' | tr '\n' ' ')"
  echo "$HOSTS_FILE:"
  while read -r ip d rest; do
    case $ip in ''|'#'*) continue ;; esac
    if ms=$(probe "$d" "$ip"); then echo "  OK    $ip  $d  (TLS ${ms}s)"; else echo "  FAIL  $ip  $d"; fi
  done < <(block_of "$HOSTS_FILE")
  [ -n "$(block_of "$HOSTS_FILE")" ] || echo "  (no $TAG block)"
  while read -r name f; do
    if [ "$(block_of "$f")" = "$(block_of "$HOSTS_FILE")" ]; then sync=in-sync; else sync=OUT-OF-SYNC; fi
    ns=$(docker cp "$name:/etc/nsswitch.conf" - 2>/dev/null | tar -xO 2>/dev/null | grep -E '^hosts:' | tr -s ' \t' ' ')
    echo "container $name: $sync, nsswitch: ${ns:-no /etc/nsswitch.conf (Go reads /etc/hosts first)}"
    case $ns in *dns*files*) echo "  WARN: dns is before files in $name, the pins may be ignored" ;; esac
  done < <(container_files)
  if [ -f "$CRON" ]; then echo "cron     : $(grep -v -e '^#' -e '=' "$CRON")"; else echo "cron     : not installed"; fi
}

cmd_verify() {
  local secs=${1:-15} out d
  need_root
  command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed (apt install tcpdump)"
  echo "counting DNS queries for: $DOMAINS ($secs s, all interfaces)..."
  out=$(timeout "$secs" tcpdump -nn -l -i any 'port 53' 2>/dev/null)
  for d in $DOMAINS; do
    echo "  $d: $(grep -cF "? $d." <<<"$out") queries"
  done
}

ensure_tools() {
  local pk=""
  command -v curl >/dev/null 2>&1 || pk+=" curl"
  command -v dig  >/dev/null 2>&1 || pk+=" dig"
  [ -z "$pk" ] && return 0
  log "installing:$pk"
  if command -v apt-get >/dev/null 2>&1; then
    pk=${pk/dig/dnsutils}
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq $pk >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq $pk; }
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q ${pk/dig/bind-utils}
  elif command -v yum >/dev/null 2>&1; then yum install -y -q ${pk/dig/bind-utils}
  fi
  command -v curl >/dev/null 2>&1 && command -v dig >/dev/null 2>&1 || die "need curl and dig"
}

install_self() { # copy this script to $SELF; download it when run from a pipe (bash <(curl ...))
  [ "$(readlink -f "$0")" = "$SELF" ] && return 0
  if [ -f "$0" ]; then
    install -m 0755 "$0" "$SELF"
  else
    curl -fsSL "$REPO_RAW" -o "$TMPD/self" && bash -n "$TMPD/self" || die "could not download $REPO_RAW"
    install -m 0755 "$TMPD/self" "$SELF"
  fi
}

cmd_install() {
  need_root
  if [ $# -gt 0 ]; then
    DOMAINS=$(parse_domains "$*") || die "no valid domain given"
  elif has_tty; then
    DOMAINS=$(ask_domains "$DOMAINS")
  else
    log "no terminal to ask on, using: $DOMAINS"
  fi
  log "domains: $DOMAINS"
  ensure_tools
  install_self
  cat > "$CONF" <<EOF
# $TAG settings - after editing run: $SELF update   (after changing INTERVAL: $SELF install)
DOMAINS="$DOMAINS"
KEEP=$KEEP
PREFER=$PREFER
IPV6=$IPV6
RESOLVER="$RESOLVER"
CONTAINERS="$CONTAINERS"
INTERVAL=$INTERVAL
EOF
  local when
  if [ "$INTERVAL" -lt 60 ]; then when="*/$INTERVAL * * * *"
  else when="$((RANDOM % 60)) */$((INTERVAL / 60)) * * *"   # random minute so nodes don't all run together
  fi
  cat > "$CRON" <<EOF
# refresh the $TAG block in /etc/hosts
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$when root $SELF update >/dev/null 2>&1
EOF
  chmod 0644 "$CRON"
  cmd_update
  echo
  cmd_status
}

cmd_uninstall() {
  need_root
  rm -f "$CRON"
  apply_block ""
  rm -f "$CONF" "$SELF" "/run/$TAG.lock"
  log "removed (backup of the original hosts file: $HOSTS_FILE.$TAG.bak)"
}

case ${1:-} in
  install)          shift; cmd_install "$@" ;;
  update)           cmd_update ;;
  status)           cmd_status ;;
  verify)           cmd_verify "${2:-15}" ;;
  uninstall|remove) cmd_uninstall ;;
  *) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0" 2>/dev/null ||
       echo "usage: pin-hosts.sh install [domain,...] | status | verify [seconds] | update | uninstall"
     exit 1 ;;
esac
