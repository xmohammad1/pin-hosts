#!/usr/bin/env bash
# pin-hosts.sh - pin a domain's IPs (e.g. the REALITY dest www.apple.com) in /etc/hosts,
# so Xray stops sending a DNS query for it on every inbound connection.
#
#  * resolves through the upstream DNS servers, never through /etc/hosts or a local
#    stub that reads it (systemd-resolved and dnsmasq both answer from /etc/hosts)
#  * keeps only IPs that complete a TLS handshake with a valid certificate for the domain
#  * refreshes hourly and after every boot (cloud-init may rebuild /etc/hosts at boot);
#    DNS down -> the old entries stay; DNS up but no IP passes -> the pins are removed
#  * also patches the hosts file of running host-network Docker containers (pg-node etc.):
#    Docker copies /etc/hosts into them only when the container starts
#
# usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh) install
#   curl -fsSL https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh | sudo bash -s -- install
#   pin-hosts.sh install [domain[:port],...] asks for the domains if none are given (Enter = www.apple.com)
#   pin-hosts.sh status | verify [seconds] | update | uninstall | version
set -uo pipefail
export LC_ALL=C

VERSION=1.1.0
REPO_RAW=${PIN_HOSTS_URL:-https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh}
SELF=/usr/local/sbin/pin-hosts.sh
CONF=/etc/pin-hosts.conf
CRON=/etc/cron.d/pin-hosts
LOCK=/run/pin-hosts.lock
HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}
TAG=pin-hosts

# defaults; /etc/pin-hosts.conf overrides them
DOMAINS="www.apple.com" # space-separated; add :port when the TLS service is not on 443
KEEP=2          # IPs kept per address family (1-99)
PREFER=6        # family listed first (6 or 4); Go/Xray dials the first listed family first
IPV6=auto       # auto | on | off
RESOLVER=auto   # auto = the system's upstream DNS servers, or a list like "185.12.64.1 8.8.8.8"
CONTAINERS=auto # auto = every running host-network container | none | "name1 name2"
INTERVAL=60     # minutes between refreshes: 1-59, or whole hours 60-1440; run install again after changing it
CONF_LOADED=0
if [ -r "$CONF" ]; then . "$CONF"; CONF_LOADED=1; fi

log()  { echo "[$TAG] $*" >&2; logger -t "$TAG" -- "$*" 2>/dev/null || true; }
die()  { log "ERROR: $*"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }
has_tty() { (exec </dev/tty) 2>/dev/null; }
lock()   { exec 9>"$LOCK" && flock "$@" 9; }   # $@ = -n, or -w seconds: one run at a time
unlock() { exec 9>&-; }

TMPD=$(mktemp -d) || exit 1
trap 'rm -rf "$TMPD"' EXIT

# ---------- settings ----------

parse_domains() { # "a.com, b.com:8443 c.com" (URLs are fine too) -> validated, de-duplicated, space-separated
  local w d p out="" seen=" " words
  read -ra words <<<"$(tr ',;' '  ' <<<"$*" | tr '[:upper:]' '[:lower:]')"
  for w in "${words[@]}"; do
    d=${w#*://}; d=${d%%/*}; p=443
    if [[ $d == *:* ]]; then p=${d##*:}; d=${d%:*}; fi
    d=${d%.}
    if ! [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$ ]] || [ ${#d} -gt 253 ]; then
      log "invalid domain: $w"; return 1
    fi
    if ! [[ $p =~ ^[1-9][0-9]{0,4}$ ]] || (( p > 65535 )); then log "invalid port in: $w"; return 1; fi
    [[ $seen == *" $d "* ]] && continue
    seen+="$d "
    if [ "$p" = 443 ]; then out+="${out:+ }$d"; else out+="${out:+ }$d:$p"; fi
  done
  [ -n "$out" ] && echo "$out"
}

port_of()  { if [[ $1 == *:* ]]; then echo "${1##*:}"; else echo 443; fi; }   # entry "host[:port]" -> port
port_for() { local e; for e in $DOMAINS; do [ "${e%%:*}" = "$1" ] && { port_of "$e"; return; }; done; echo 443; }

validate_conf() { # normalizes DOMAINS; logs the problem and returns 1 when a setting is wrong
  local list
  list=$(parse_domains "$DOMAINS") || { log "ERROR DOMAINS='$DOMAINS' is not a valid domain list"; return 1; }
  DOMAINS=$list
  [[ $KEEP =~ ^[1-9][0-9]?$ ]] || { log "ERROR KEEP must be 1-99, got '$KEEP'"; return 1; }
  [[ $PREFER == 4 || $PREFER == 6 ]] || { log "ERROR PREFER must be 4 or 6, got '$PREFER'"; return 1; }
  [[ $IPV6 == auto || $IPV6 == on || $IPV6 == off ]] || { log "ERROR IPV6 must be auto, on or off, got '$IPV6'"; return 1; }
  if ! [[ $INTERVAL =~ ^[1-9][0-9]*$ ]] ||
     ! { (( INTERVAL <= 59 )) || (( INTERVAL % 60 == 0 && INTERVAL <= 1440 )); }; then
    log "ERROR INTERVAL must be 1-59 minutes or whole hours 60-1440, got '$INTERVAL'"; return 1
  fi
}

cron_when() { # cron time fields for $INTERVAL; a random minute so nodes don't all refresh together
  local m=$((RANDOM % 60))
  if (( INTERVAL < 60 )); then echo "*/$INTERVAL * * * *"
  elif (( INTERVAL == 1440 )); then echo "$m $((RANDOM % 24)) * * *"
  else echo "$m */$((INTERVAL / 60)) * * *"
  fi
}

ask_domains() { # $1 default list -> list typed on the terminal; Enter keeps the default
  local ans list
  while :; do
    printf 'Domains to pin in /etc/hosts, comma-separated [%s]: ' "${1// /, }" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    if [ -z "${ans//[[:space:],]/}" ]; then echo "$1"; return; fi
    list=$(parse_domains "$ans") && { echo "$list"; return; }
    echo "  try again, for example: www.apple.com, tgju.org (add :port if it is not 443)" >/dev/tty
  done
}

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

probe() { # $1 domain, $2 ip, $3 port -> TLS handshake seconds, if the IP completes a verified TLS handshake for $1
  # Only the handshake counts (REALITY needs nothing more): a slow or missing HTTP answer afterwards is fine.
  local a=$2 t
  [[ $a == *:* ]] && a="[$a]"
  t=$(curl -s -o /dev/null -I --connect-timeout 3 -m 6 --resolve "$1:$3:$a" \
      -w '%{time_appconnect}' "https://$1:$3/" 2>/dev/null)
  awk -v t="${t:-0}" 'BEGIN { exit !(t + 0 > 0) }' && echo "$t"
}

have_v6() {
  case $IPV6 in on) return 0 ;; off) return 1 ;; esac
  ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1
}

# ---------- managed block ----------

block_of() { # the managed block of hosts file $1
  sed -n "/^# BEGIN $TAG/,/^# END $TAG/p" "$1" 2>/dev/null
}

current_ips() { # IPs pinned now for domain $1
  block_of "$HOSTS_FILE" | awk -v d="$1" '$1!~/^#/ && $2==d {print $1}'
}

pick() { # $1 domain, $2 port, $3 fresh DNS IPs, $4 pinned IPs (one family) -> up to $KEEP healthy IPs
  # fresh DNS answers first, then old pins, each by handshake time; the same set as now keeps its order (no rewrite)
  local d=$1 p=$2 fresh=$3 old=$4 ip ms picked
  picked=$({
    for ip in $fresh; do ms=$(probe "$d" "$ip" "$p") && echo "0 $ms $ip"; done
    for ip in $old; do
      grep -qxF -- "$ip" <<<"$fresh" && continue
      ms=$(probe "$d" "$ip" "$p") && echo "1 $ms $ip"
    done
  } | sort -k1,1n -k2,2g | head -n "$KEEP" | awk '{print $3}')
  [ -n "$picked" ] || return 0
  [ "$(sort <<<"$picked")" = "$(sort <<<"$old")" ] && picked=$old
  echo "$picked"
}

build_block() { # prints the new managed block
  local e d p f4 f6 o4 o6 v4 v6 ip
  echo "# BEGIN $TAG - managed by $SELF (settings: $CONF)"
  for e in $DOMAINS; do
    d=${e%%:*}; p=$(port_of "$e")
    o4=$(current_ips "$d" | grep -v :); o6=$(current_ips "$d" | grep :)
    f4=$(resolve "$d" A); f6=""; v6=""
    v4=$(pick "$d" "$p" "$f4" "$o4")
    if have_v6; then f6=$(resolve "$d" AAAA); v6=$(pick "$d" "$p" "$f6" "$o6"); fi
    if [ -z "$v4$v6" ]; then
      if [ -n "$f4$f6" ]; then
        log "WARN $d: DNS answered but no IP passed the TLS check on port $p; not pinned, Xray uses DNS for it"
      elif [ -n "$o4$o6" ]; then
        log "WARN $d: DNS failed and no IP passed the TLS check; keeping the old entries"
        block_of "$HOSTS_FILE" | awk -v d="$d" '$1!~/^#/ && $2==d'
      else
        log "WARN $d: DNS failed and nothing is pinned yet; $d is left to DNS"
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
  [ -f "$1" ] || { log "ERROR $1 does not exist"; return 1; }
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

hosts_bind_mounted() { # a running container bind-mounts the host's hosts file: a rename would hide updates from it
  command -v docker >/dev/null 2>&1 || return 1
  local real ids srcs
  real=$(readlink -f "$HOSTS_FILE")
  ids=$(docker ps -q 2>/dev/null)
  [ -n "$ids" ] || return 1
  srcs=$(docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' $ids 2>/dev/null)
  grep -qxF -e "$HOSTS_FILE" -e "$real" <<<"$srcs"
}

put_host() { # $1 new content -> replace $HOSTS_FILE by rename, so no reader ever sees a half-written file
  local t tmp
  t=$(readlink -f "$HOSTS_FILE")
  cmp -s "$t" "$1" && return 1
  if ! hosts_bind_mounted && tmp=$(mktemp "$t.XXXXXX" 2>/dev/null); then
    if cat "$1" > "$tmp" && chmod --reference="$t" "$tmp" && { chown --reference="$t" "$tmp" 2>/dev/null; true; } &&
       mv -f "$tmp" "$t" 2>/dev/null; then
      command -v restorecon >/dev/null 2>&1 && restorecon "$t" 2>/dev/null
      return 0
    fi
    rm -f "$tmp"
  fi
  cat "$1" > "$t"   # bind-mounted, or the rename failed: write in place
}

container_files() { # "name hostsfile" for each target container
  [ "$CONTAINERS" = none ] && return 0
  if ! command -v docker >/dev/null 2>&1; then
    [ -S /var/run/docker.sock ] && log "WARN docker is running but the docker command is not in PATH; containers skipped"
    return 0
  fi
  local ids id
  if [ "$CONTAINERS" = auto ]; then
    ids=$(docker ps -q 2>/dev/null) || { log "WARN docker ps failed; containers skipped"; return 0; }
  else
    ids=$CONTAINERS
  fi
  for id in $ids; do
    docker inspect -f '{{.HostConfig.NetworkMode}} {{.Name}} {{.HostsPath}}' "$id" 2>/dev/null |
      awk -v mode="$CONTAINERS" 'mode!="auto" || $1=="host" {sub(/^\//, "", $2); print $2, $3}'
  done
}

apply_block() { # $1 block file ("" = remove) -> write it to the host and the containers
  local name f new=$TMPD/new
  [ -n "$1" ] && [ ! -f "$HOSTS_FILE.$TAG.bak" ] && cp -p "$HOSTS_FILE" "$HOSTS_FILE.$TAG.bak"
  render "$HOSTS_FILE" "$1" > "$new" || return 1
  put_host "$new" && log "$HOSTS_FILE updated"
  while read -r name f; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then log "WARN container $name: hosts file not found (${f:-none})"; continue; fi
    render "$f" "$1" > "$new" && put "$f" "$new" && log "container $name: hosts updated"
  done < <(container_files)
  return 0
}

do_update() { # build the block and write it everywhere (the caller holds the lock)
  local list
  if [ "$CONF_LOADED" = 1 ] && [ ! -f "$CONF" ]; then log "uninstalled meanwhile, nothing to do"; return 0; fi
  build_block > "$TMPD/block"
  apply_block "$TMPD/block" || { log "ERROR $HOSTS_FILE not updated"; return 1; }
  list=$(awk '$1!~/^#/ {print $1}' "$TMPD/block" | tr '\n' ' ')
  log "pinned -> ${list:-nothing}"
}

cloudinit_manages_hosts() {
  grep -qs 'manage_etc_hosts' "$HOSTS_FILE" ||
    grep -rqsE '^[[:space:]]*manage_etc_hosts:[[:space:]]*(true|True|yes)' /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d
}

# ---------- commands ----------

cmd_update() {
  need_root
  validate_conf || die "fix $CONF"
  lock -n || { log "another run is active"; return 0; }
  do_update || exit 1
}

cmd_boot() { # @reboot: cloud-init can rebuild /etc/hosts at boot, so wait for it and the network, then refresh
  local i
  need_root
  validate_conf || die "fix $CONF"
  if cloudinit_manages_hosts && command -v cloud-init >/dev/null 2>&1; then
    timeout 600 cloud-init status --wait >/dev/null 2>&1
  fi
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 15
    [ -f "$CONF" ] || return 0
    lock -w 300 || continue
    do_update && [ -n "$(block_of "$HOSTS_FILE" | grep -v '^#')" ] && return 0
    unlock
  done
  log "WARN boot refresh found nothing to pin; the regular cron run will try again"
}

cmd_status() {
  local ip d rest ms name f ns sync
  echo "version  : $VERSION"
  validate_conf || echo "settings : INVALID - fix $CONF (see the error above)"
  echo "settings : DOMAINS='$DOMAINS' KEEP=$KEEP PREFER=$PREFER IPV6=$IPV6 RESOLVER=$RESOLVER CONTAINERS=$CONTAINERS INTERVAL=$INTERVAL"
  echo "DNS used : $(resolvers | awk '!seen[$0]++' | tr '\n' ' ')"
  echo "$HOSTS_FILE:"
  while read -r ip d rest; do
    case $ip in ''|'#'*) continue ;; esac
    if ms=$(probe "$d" "$ip" "$(port_for "$d")"); then echo "  OK    $ip  $d  (TLS ${ms}s)"; else echo "  FAIL  $ip  $d"; fi
  done < <(block_of "$HOSTS_FILE")
  [ -n "$(block_of "$HOSTS_FILE")" ] || echo "  (no $TAG block)"
  while read -r name f; do
    if [ "$(block_of "$f")" = "$(block_of "$HOSTS_FILE")" ]; then sync=in-sync; else sync=OUT-OF-SYNC; fi
    ns=$(docker cp -L "$name:/etc/nsswitch.conf" - 2>/dev/null | tar -xO 2>/dev/null | grep -E '^hosts:' | tr -s ' \t' ' ')
    echo "container $name: $sync, nsswitch: ${ns:-no /etc/nsswitch.conf (Go reads /etc/hosts first)}"
    case $ns in *dns*files*) echo "  WARN: dns is before files in $name, the pins may be ignored" ;; esac
  done < <(container_files)
  cloudinit_manages_hosts && echo "cloud-init: rebuilds $HOSTS_FILE at boot (manage_etc_hosts); the @reboot job puts the block back"
  if [ -f "$CRON" ]; then
    grep -v -e '^#' -e '=' "$CRON" | sed 's| >/dev/null 2>&1$||; s|^|cron     : |'
  else
    echo "cron     : not installed"
  fi
}

cmd_verify() {
  local secs=${1:-15} out e d
  need_root
  [[ $secs =~ ^[1-9][0-9]{0,3}$ ]] || die "seconds must be 1-9999"
  command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed (apt install tcpdump)"
  echo "counting DNS queries for: $DOMAINS ($secs s, all interfaces)..."
  out=$(timeout "$secs" tcpdump -nn -l -i any 'port 53' 2>/dev/null)
  for e in $DOMAINS; do
    d=${e%%:*}
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

cmd_install() {
  local src=${BASH_SOURCE[0]:-} def
  need_root
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    # Started from a pipe (bash <(curl ...) or curl ... | bash): install the published script and hand over to it,
    # so the code that does the install is exactly the code that stays installed.
    ensure_tools
    curl -fsSL "$REPO_RAW" -o "$TMPD/self" || die "could not download $REPO_RAW"
    head -n 1 "$TMPD/self" | grep -q '^#!.*bash' && grep -q '^TAG=pin-hosts$' "$TMPD/self" && bash -n "$TMPD/self" ||
      die "$REPO_RAW did not return a valid pin-hosts.sh"
    install -D -m 0755 "$TMPD/self" "$SELF"
    rm -rf "$TMPD"
    exec bash "$SELF" install "$@"
  fi
  def=$(parse_domains "$DOMAINS" 2>/dev/null) || def=www.apple.com
  if [ $# -gt 0 ]; then
    DOMAINS=$(parse_domains "$*") || die "no valid domain given"
  elif has_tty; then
    DOMAINS=$(ask_domains "$def")
  else
    DOMAINS=$def
    log "no terminal to ask on, using: $DOMAINS"
  fi
  validate_conf || die "fix the settings in $CONF"
  log "domains: $DOMAINS"
  ensure_tools
  [ "$(readlink -f "$src")" = "$SELF" ] || install -D -m 0755 "$src" "$SELF"
  cat > "$CONF" <<EOF
# $TAG settings. After editing run: $SELF update   (after changing INTERVAL: $SELF install)
DOMAINS="$DOMAINS"   # space-separated, add :port when the TLS service is not on 443
KEEP=$KEEP           # IPs kept per address family (1-99)
PREFER=$PREFER         # address family listed first: 6 or 4
IPV6=$IPV6        # auto | on | off
RESOLVER="$RESOLVER"   # auto, or DNS servers like "185.12.64.1 8.8.8.8"
CONTAINERS="$CONTAINERS" # auto (running host-network containers) | none | "name1 name2"
INTERVAL=$INTERVAL      # minutes: 1-59, or whole hours 60-1440
EOF
  CONF_LOADED=1
  cat > "$CRON" <<EOF
# $TAG: refresh the block in /etc/hosts every $INTERVAL min, and after boot
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
$(cron_when) root $SELF update >/dev/null 2>&1
@reboot root $SELF boot >/dev/null 2>&1
EOF
  chmod 0644 "$CRON"
  lock -w 120 || die "another run still holds $LOCK"
  do_update
  unlock
  echo
  cmd_status
}

cmd_uninstall() {
  need_root
  lock -w 300 || die "an update is still running, try again in a minute"
  apply_block "" || die "the $TAG block is still in $HOSTS_FILE (fix the markers by hand); nothing was removed"
  rm -f "$CRON" "$CONF" "$SELF"
  unlock
  rm -f "$LOCK"
  log "removed (backup of the original hosts file: $HOSTS_FILE.$TAG.bak)"
}

usage() {
  cat <<EOF
pin-hosts $VERSION - pin domain IPs in /etc/hosts (e.g. the REALITY dest), health-checked and refreshed

  pin-hosts.sh install [domain[:port],...]   install; asks for the domains if none are given (Enter = www.apple.com)
  pin-hosts.sh status                        pinned IPs, TLS check, container sync, cron
  pin-hosts.sh verify [seconds]              count DNS queries for the domains (needs tcpdump)
  pin-hosts.sh update                        refresh now (cron runs this every $INTERVAL min and after boot)
  pin-hosts.sh uninstall                     remove the pins, the cron job, the settings and the script
  pin-hosts.sh version

one-click install: bash <(curl -fsSL $REPO_RAW) install
EOF
}

case ${1:-} in
  install)          shift; cmd_install "$@" ;;
  update)           cmd_update ;;
  boot)             cmd_boot ;;
  status)           cmd_status ;;
  verify)           cmd_verify "${2:-15}" ;;
  uninstall|remove) cmd_uninstall ;;
  version|-v|--version) echo "pin-hosts $VERSION" ;;
  *)                usage; exit 1 ;;
esac
