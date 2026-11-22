#!/usr/bin/env bash
# pin-hosts.sh - pin a domain's IPs (e.g. the REALITY dest www.apple.com) in /etc/hosts,
# so Xray stops sending a DNS query for it on every inbound connection.
#
#  * resolves through the upstream DNS servers, never through /etc/hosts or a local
#    stub that reads it (systemd-resolved and dnsmasq both answer from /etc/hosts)
#  * keeps only IPs that complete a verified TLS 1.3 handshake for the domain (no proxy, no ~/.curlrc)
#  * refreshes from a systemd timer (cron where there is no systemd) and after every boot;
#    DNS down or nothing reachable -> the old entries stay; reachable but failing -> the pins are removed
#  * checks every new file before it replaces the old one: a full disk or broken markers never damage /etc/hosts
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
umask 022

VERSION=1.2.0
REPO_RAW=${PIN_HOSTS_URL:-https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh}
SELF=/usr/local/sbin/pin-hosts.sh
CONF=/etc/pin-hosts.conf
CRON=/etc/cron.d/pin-hosts
UNIT_DIR=/etc/systemd/system
LOCK=/run/pin-hosts.lock
HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}
TAG=pin-hosts
BEGIN_RE="^# BEGIN $TAG( |\$)"   # exact markers: "# BEGIN pin-hosts-other" belongs to someone else
END_RE="^# END $TAG[[:space:]]*\$"

# defaults; /etc/pin-hosts.conf overrides them
DOMAINS="www.apple.com" # space-separated; add :port when the TLS service is not on 443
KEEP=2          # IPs kept per address family (1-99)
PREFER=6        # family listed first (6 or 4); Go/Xray dials the first listed family first
IPV6=auto       # auto | on | off
RESOLVER=auto   # auto = the system's upstream DNS servers, or a list like "185.12.64.1 8.8.8.8"
CONTAINERS=auto # auto = every running host-network container | none | "name1 name2"
INTERVAL=60     # minutes between refreshes: 1-30 dividing 60, or 60, 120, 180, 240, 360, 480, 720, 1440
TLS_MIN=1.3     # lowest TLS version an IP must speak (REALITY needs 1.3)
RETRY_DELAY=10  # seconds before checking again when every pinned IP fails (0 = no second check)
CONF_LOADED=0
TMPD=""

log()  { echo "[$TAG] $*" >&2; [ -n "${INVOCATION_ID:-}" ] || logger -t "$TAG" -- "$*" 2>/dev/null || true; }
die()  { log "ERROR: $*"; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }
has_tty() { (exec </dev/tty) 2>/dev/null; }

need_tmp() {
  [ -n "$TMPD" ] && return 0
  TMPD=$(mktemp -d 2>/dev/null) || die "cannot create a temp directory (is /tmp full?)"
  trap 'rm -rf "$TMPD"' EXIT
}

lock() { # $@ = -n, or -w seconds: one run at a time
  command -v flock >/dev/null 2>&1 || die "flock is missing (it is part of util-linux)"
  exec 9>"$LOCK" || die "cannot open $LOCK"
  flock "$@" 9
}
unlock() { exec 9>&-; }

load_conf() { # the settings file runs as root, so it must not be writable by anyone else
  local owner mode
  [ -e "$CONF" ] || return 0
  owner=$(stat -c %u "$CONF" 2>/dev/null) || owner=x
  mode=$(stat -c %a "$CONF" 2>/dev/null) || mode=777
  if [ "$owner" != 0 ] || (( 8#$mode & 8#022 )); then
    echo "[$TAG] ERROR: not reading $CONF: it must be owned by root and writable only by root" \
         "(chown root:root $CONF && chmod 644 $CONF)" >&2
    exit 1
  fi
  . "$CONF"
  CONF_LOADED=1
}

# ---------- settings ----------

parse_domains() { # "a.com, b.com:8443 c.com" (URLs are fine too) -> validated, de-duplicated, space-separated
  local w d p out="" seen=" " words
  read -ra words <<<"$(tr ',;\n\t' '    ' <<<"$*" | tr '[:upper:]' '[:lower:]')"
  for w in "${words[@]}"; do
    d=${w#*://}; d=${d%%/*}; p=443
    if [[ $d == *:* ]]; then p=${d##*:}; d=${d%:*}; fi
    d=${d%.}
    if ! [[ $d =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]] || [ ${#d} -gt 253 ]; then
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
  local list x
  list=$(parse_domains "$DOMAINS") || { log "ERROR DOMAINS='$DOMAINS' is not a valid domain list"; return 1; }
  DOMAINS=$list
  [[ $KEEP =~ ^[1-9][0-9]?$ ]] || { log "ERROR KEEP must be 1-99, got '$KEEP'"; return 1; }
  [[ $PREFER == 4 || $PREFER == 6 ]] || { log "ERROR PREFER must be 4 or 6, got '$PREFER'"; return 1; }
  [[ $IPV6 == auto || $IPV6 == on || $IPV6 == off ]] || { log "ERROR IPV6 must be auto, on or off, got '$IPV6'"; return 1; }
  [[ $TLS_MIN == 1.2 || $TLS_MIN == 1.3 ]] || { log "ERROR TLS_MIN must be 1.2 or 1.3, got '$TLS_MIN'"; return 1; }
  [[ $RETRY_DELAY =~ ^[0-9]{1,3}$ ]] || { log "ERROR RETRY_DELAY must be 0-999 seconds, got '$RETRY_DELAY'"; return 1; }
  if ! [[ $INTERVAL =~ ^[1-9][0-9]{0,3}$ ]] ||
     ! { (( INTERVAL < 60 && 60 % INTERVAL == 0 )) || (( INTERVAL % 60 == 0 && 1440 % INTERVAL == 0 )); }; then
    log "ERROR INTERVAL must divide the hour (1-30 min) or the day (60, 120, 180, 240, 360, 480, 720, 1440), got '$INTERVAL'"
    return 1
  fi
  if [ "$RESOLVER" != auto ]; then
    [ -n "${RESOLVER//[[:space:]]/}" ] || { log "ERROR RESOLVER is empty"; return 1; }
    for x in $RESOLVER; do
      [[ $x =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $x =~ ^[0-9a-fA-F]*:[0-9a-fA-F:.]*(%[A-Za-z0-9_.-]+)?$ ]] ||
        { log "ERROR RESOLVER must be auto or IP addresses, got '$x'"; return 1; }
    done
  fi
  if [ "$CONTAINERS" != auto ] && [ "$CONTAINERS" != none ]; then
    [ -n "${CONTAINERS//[[:space:]]/}" ] || { log "ERROR CONTAINERS is empty"; return 1; }
    for x in $CONTAINERS; do
      [[ $x =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { log "ERROR CONTAINERS must be auto, none or container names, got '$x'"; return 1; }
    done
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

write_conf() {
  local tmp
  tmp=$(mktemp "$CONF.XXXXXX" 2>/dev/null) || die "cannot write $CONF"
  cat > "$tmp" <<EOF
# $TAG settings. After editing run: $SELF update   (after changing INTERVAL: $SELF install)
DOMAINS="$DOMAINS"   # space-separated, add :port when the TLS service is not on 443
KEEP=$KEEP           # IPs kept per address family (1-99)
PREFER=$PREFER         # address family listed first: 6 or 4
IPV6=$IPV6        # auto | on | off
RESOLVER="$RESOLVER"   # auto, or DNS servers like "185.12.64.1 8.8.8.8"
CONTAINERS="$CONTAINERS" # auto (running host-network containers) | none | "name1 name2"
INTERVAL=$INTERVAL      # minutes: 1-30 dividing 60, or 60, 120, 180, 240, 360, 480, 720, 1440
TLS_MIN=$TLS_MIN       # lowest TLS version an IP must speak: 1.3 (REALITY) or 1.2
RETRY_DELAY=$RETRY_DELAY    # seconds before checking again when every pinned IP fails (0 = no second check)
EOF
  if grep -q '^RETRY_DELAY=' "$tmp" && chmod 0644 "$tmp" && chown 0:0 "$tmp" && mv -f "$tmp" "$CONF"; then return 0; fi
  rm -f "$tmp"
  die "cannot write $CONF (disk full?)"
}

# ---------- DNS + health check ----------

v6_route() { # the server has an IPv6 default route
  if command -v ip >/dev/null 2>&1; then
    ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1
  else
    awk '$1 == "00000000000000000000000000000000" && $2 == "00" { f = 1 } END { exit !f }' /proc/net/ipv6_route 2>/dev/null
  fi
}

have_v6() { case $IPV6 in on) return 0 ;; off) return 1 ;; esac; v6_route; }

resolvers() { # upstream DNS servers to ask, in order (loopback stubs skipped: they may answer from /etc/hosts)
  local f
  if [ "$RESOLVER" != auto ]; then printf '%s\n' $RESOLVER; return; fi
  {
    for f in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
      [ -r "$f" ] && awk '$1 == "nameserver" && $2 !~ /^(127\.|0\.0\.0\.0$|::1$)/ {print $2}' "$f"
    done
    printf '%s\n' 8.8.8.8 1.1.1.1   # fallback; 8.8.8.8 sends EDNS client-subnet, so the CDN still maps by location
    v6_route && printf '%s\n' 2001:4860:4860::8888 2606:4700:4700::1111
  } | awk '!seen[$0]++'
}

resolve() { # $1 domain, $2 A|AAAA -> up to 8 IPs from the first server that answers; status 1 if none answered
  local s out
  for s in $(resolvers); do
    out=$(dig +noall +comments +answer +time=2 +tries=1 "@$s" "$1" "$2" 2>/dev/null) || continue
    case $(sed -n 's/.*status: \([A-Z]*\).*/\1/p' <<<"$out" | head -n 1) in
      NOERROR|NXDOMAIN)   # a real answer, even an empty one (no AAAA): no need to ask the next server
        awk -v t="$2" '$1 !~ /^;/ && $4 == t {print $5}' <<<"$out" | awk '!seen[$0]++' | head -n 8
        return 0 ;;
    esac
  done
  return 1
}

probe() { # $1 domain, $2 ip, $3 port -> "tls <seconds>" (verified handshake), "tcp 0" (TCP works, TLS fails) or "down 0"
  # -q skips ~/.curlrc and --noproxy '*' ignores proxy settings: the IP itself has to be tested
  local a=$2 tc="" ta=""
  [[ $a == *:* ]] && a="[$a]"
  read -r tc ta < <(curl -q -s -o /dev/null -I --noproxy '*' --tlsv"$TLS_MIN" --connect-timeout 3 -m 6 \
    --resolve "$1:$3:$a" -w '%{time_connect} %{time_appconnect}\n' "https://$1:$3/" 2>/dev/null)
  awk -v c="${tc:-0}" -v t="${ta:-0}" \
    'BEGIN { if (t + 0 > 0) print "tls", t; else if (c + 0 > 0) print "tcp", 0; else print "down", 0 }'
}

check_ips() { # $1 domain, $2 port, then IPs -> "<tls|tcp|down> <seconds> <ip>" per IP, all probed at the same time
  local d=$1 p=$2 ip n=0 dir
  shift 2
  [ $# -gt 0 ] || return 0
  dir=$(mktemp -d "$TMPD/check.XXXXXX" 2>/dev/null) || return 0
  for ip; do
    n=$((n + 1))
    (echo "$(probe "$d" "$ip" "$p") $ip" > "$dir/$n") &
  done
  wait
  cat "$dir"/* 2>/dev/null
  rm -rf "$dir"
}

pick_from() { # $1 check results, $2 fresh DNS IPs, $3 pinned IPs (one family) -> up to $KEEP verified IPs
  # fresh DNS answers first, then old pins, each by handshake time; the same set as now keeps its order (no rewrite)
  local picked
  picked=$(FRESH="$2" OLD="$3" awk '
      BEGIN { n = split(ENVIRON["FRESH"], f, "\n"); for (i = 1; i <= n; i++) if (f[i] != "") isf[f[i]] = 1
              n = split(ENVIRON["OLD"], o, "\n");   for (i = 1; i <= n; i++) if (o[i] != "") iso[o[i]] = 1 }
      $1 == "tls" && (($3 in isf) || ($3 in iso)) { rank = ($3 in isf) ? 0 : 1; print rank, $2, $3 }' <<<"$1" |
    sort -k1,1n -k2,2g | head -n "$KEEP" | awk '{print $3}')
  [ -n "$picked" ] || return 0
  [ "$(sort <<<"$picked")" = "$(sort <<<"$3")" ] && picked=$3
  echo "$picked"
}

# ---------- managed block ----------

block_of() { # the first complete managed block of hosts file $1, markers included
  awk -v b="$BEGIN_RE" -v e="$END_RE" '
    !inb && $0 ~ b { inb = 1; buf = $0; next }
    inb && $0 ~ e  { print buf; print; exit }
    inb            { if ($0 ~ b) buf = $0; else buf = buf "\n" $0 }' "$1" 2>/dev/null
}

block_ok() { # $1 block file -> 0 when it is exactly one complete block
  awk -v b="$BEGIN_RE" -v e="$END_RE" '
    NR == 1 && $0 !~ b { bad = 1; exit }
    NR > 1 && $0 ~ b   { bad = 1; exit }
    $0 ~ e             { ends++; last = NR }
    END { if (bad || NR < 2 || ends != 1 || last != NR) exit 1 }' "$1" 2>/dev/null
}

current_ips() { # IPs pinned now for domain $1
  block_of "$HOSTS_FILE" | awk -v d="$1" '$1 !~ /^#/ && $2 == d {print $1}'
}

build_block() { # prints the new managed block
  local e d p f4 f6 r4 r6 o4 o6 all res v4 v6 ip
  echo "# BEGIN $TAG - managed by $SELF (settings: $CONF)"
  for e in $DOMAINS; do
    d=${e%%:*}; p=$(port_of "$e")
    o4=$(current_ips "$d" | grep -v : | awk '!seen[$0]++')
    o6=$(current_ips "$d" | grep : | awk '!seen[$0]++')
    f4=$(resolve "$d" A); r4=$?
    f6=""; r6=1
    if have_v6; then f6=$(resolve "$d" AAAA); r6=$?; else o6=""; fi
    all=$(printf '%s\n' $f4 $o4 $f6 $o6 | awk 'NF && !seen[$0]++')
    res=$(check_ips "$d" "$p" $all)
    v4=$(pick_from "$res" "$f4" "$o4"); v6=$(pick_from "$res" "$f6" "$o6")
    if [ -z "$v4$v6" ] && [ -n "$o4$o6" ] && [ "$RETRY_DELAY" -gt 0 ]; then
      log "WARN $d: no IP passed the TLS check, checking again in ${RETRY_DELAY}s"
      sleep "$RETRY_DELAY"
      res=$(check_ips "$d" "$p" $all)
      v4=$(pick_from "$res" "$f4" "$o4"); v6=$(pick_from "$res" "$f6" "$o6")
    fi
    if [ -z "$v4$v6" ]; then
      if [ -z "$o4$o6" ]; then
        log "WARN $d: no IP passed the TLS check on port $p; $d is left to DNS"
        continue
      elif [ "$r4" != 0 ] && [ "$r6" != 0 ]; then
        log "WARN $d: DNS failed and no pinned IP passed the TLS check; keeping the old entries"
      elif ! grep -qE '^(tls|tcp) ' <<<"$res"; then
        log "WARN $d: no IP is reachable at all (network problem?); keeping the old entries"
      else
        log "WARN $d: IPs are reachable but none passed the TLS $TLS_MIN check on port $p; not pinned, Xray uses DNS for it"
        continue
      fi
      v4=$o4; v6=$o6
    fi
    if [ "$PREFER" = 4 ]; then set -- $v4 $v6; else set -- $v6 $v4; fi
    for ip; do printf '%-40s %s\n' "$ip" "$d"; done
  done
  echo "# END $TAG"
}

render() { # $1 hosts file, $2 block file ("" = just remove the block) -> new content on stdout; 1 on any error
  [ -f "$1" ] || { log "ERROR $1 does not exist"; return 1; }
  awk -v b="$BEGIN_RE" -v e="$END_RE" '
    $0 ~ b { if (inb) { bad = "a second BEGIN before END, line " NR; exit } inb = 1; next }
    $0 ~ e { if (!inb) { bad = "END without BEGIN, line " NR; exit } inb = 0; next }
    !inb   { print }
    END    { if (bad == "" && inb) bad = "BEGIN without END"
             if (bad != "") { print FILENAME ": broken markers: " bad > "/dev/stderr"; exit 3 } }' "$1" ||
    { log "ERROR $1: broken $TAG markers (fix them by hand) or a write error"; return 1; }
  if [ -n "$2" ]; then cat "$2" || return 1; fi
}

new_ok() { # $1 current file, $2 new file, $3 block file ("" = removal) -> 0 when $2 is $1 with exactly the new block
  # catches cut-off files from a full disk: the lines outside the block must be identical
  cmp -s <(render "$1" "" 2>/dev/null) <(render "$2" "" 2>/dev/null) || return 1
  if [ -n "$3" ]; then cmp -s <(block_of "$2") "$3"; else ! grep -qE "$BEGIN_RE|$END_RE" "$2"; fi
}

put() { # $1 target, $2 new content -> rewrite in place, same inode (Docker bind-mounts these files)
  # 0 written, 2 unchanged, 1 error (the old content is put back)
  local old
  cmp -s "$1" "$2" && return 2
  old=$(cat "$1" && echo .) || return 1
  old=${old%.}
  if cat "$2" > "$1" && cmp -s "$1" "$2"; then return 0; fi
  printf '%s' "$old" > "$1" 2>/dev/null
  return 1
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

put_host() { # $1 new content -> replace $HOSTS_FILE by rename, so no reader sees a half-written file; 0/2/1 as put
  local t tmp
  t=$(readlink -f "$HOSTS_FILE")
  cmp -s "$t" "$1" && return 2
  if hosts_bind_mounted; then put "$t" "$1"; return; fi
  tmp=$(mktemp "$t.XXXXXX" 2>/dev/null) || { log "ERROR cannot create a file next to $t (read-only?)"; return 1; }
  if ! { cat "$1" > "$tmp" && cmp -s "$1" "$tmp"; }; then
    rm -f "$tmp"; log "ERROR cannot write next to $t (disk full?)"; return 1
  fi
  chmod --reference="$t" "$tmp" 2>/dev/null; chown --reference="$t" "$tmp" 2>/dev/null
  if mv -f "$tmp" "$t" 2>/dev/null; then
    command -v restorecon >/dev/null 2>&1 && restorecon "$t" 2>/dev/null
    return 0
  fi
  rm -f "$tmp"
  put "$t" "$1"   # the rename is refused (immutable file, or a mount point): try in place
}

container_files() { # "name hostsfile" for each target container
  [ "$CONTAINERS" = none ] && return 0
  if [ "$HOSTS_FILE" != /etc/hosts ]; then log "HOSTS_FILE is not /etc/hosts: containers are left alone"; return 0; fi
  if ! command -v docker >/dev/null 2>&1; then
    [ -S /var/run/docker.sock ] && log "WARN docker is running but the docker command is not in PATH; containers skipped"
    return 0
  fi
  local ids
  if [ "$CONTAINERS" = auto ]; then
    ids=$(docker ps -q 2>/dev/null) || { log "WARN docker ps failed; containers skipped"; return 0; }
  else
    ids=$CONTAINERS
  fi
  [ -n "$ids" ] || return 0
  docker inspect -f '{{.HostConfig.NetworkMode}} {{.Name}} {{.HostsPath}}' $ids 2>/dev/null |
    awk -v mode="$CONTAINERS" 'mode != "auto" || $1 == "host" {sub(/^\//, "", $2); print $2, $3}'
}

apply_block() { # $1 block file ("" = remove) -> write it to the host and the containers; 1 when the host was not written
  local name f rc new=$TMPD/new bak=$HOSTS_FILE.$TAG.bak
  if [ -n "$1" ]; then
    block_ok "$1" || { log "ERROR the new block is incomplete (disk full?); nothing was written"; return 1; }
    if [ ! -f "$bak" ]; then
      { cp -p "$HOSTS_FILE" "$bak.tmp" && cmp -s "$HOSTS_FILE" "$bak.tmp" && mv -f "$bak.tmp" "$bak"; } 2>/dev/null ||
        rm -f "$bak.tmp" 2>/dev/null
    fi
  fi
  if ! { render "$HOSTS_FILE" "$1" > "$new" && new_ok "$HOSTS_FILE" "$new" "$1"; }; then
    log "ERROR could not prepare the new $HOSTS_FILE (broken markers or disk full); nothing was written"
    return 1
  fi
  put_host "$new"; rc=$?
  case $rc in
    0) log "$HOSTS_FILE updated" ;;
    1) log "ERROR could not write $HOSTS_FILE (read-only, immutable or full?)"; return 1 ;;
  esac
  while read -r name f; do
    if [ -z "$f" ] || [ ! -f "$f" ]; then log "WARN container $name: hosts file not found (${f:-none})"; continue; fi
    if ! { render "$f" "$1" > "$new" && new_ok "$f" "$new" "$1"; }; then
      log "ERROR container $name: could not prepare its hosts file; left as it is"; continue
    fi
    put "$f" "$new"; rc=$?
    case $rc in
      0) log "container $name: hosts updated" ;;
      1) log "ERROR container $name: could not write $f" ;;
    esac
  done < <(container_files)
  return 0
}

do_update() { # build the block and write it everywhere (the caller holds the lock); 1 on failure
  local list
  if [ "$CONF_LOADED" = 1 ] && [ ! -f "$CONF" ]; then log "uninstalled meanwhile, nothing to do"; return 0; fi
  build_block > "$TMPD/block"
  apply_block "$TMPD/block" || return 1
  list=$(awk '$1 !~ /^#/ {print $1}' "$TMPD/block" | tr '\n' ' ')
  log "pinned -> ${list:-nothing}"
}

cloudinit_manages_hosts() { # cloud-init rebuilds /etc/hosts at every boot (manage_etc_hosts: true or template)
  grep -qs 'manage_etc_hosts' "$HOSTS_FILE" ||
    grep -rqsiE "^[[:space:]]*manage_etc_hosts:[[:space:]]*[\"']?(true|yes|on|1|template)[\"']?[[:space:]]*(#.*)?\$" \
      /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d
}

nsswitch_warn() { # $1 = a "hosts: ..." line -> a warning when /etc/hosts would not be read first
  awk '{ for (i = 2; i <= NF; i++) { if ($i == "files" && !f) f = i; if ($i == "dns" && !d) d = i }
         if (!f) print "no \"files\" source: /etc/hosts is not read at all"
         else if (d && d < f) print "\"dns\" comes before \"files\": the pins may be ignored" }' <<<"$1"
}

# ---------- schedule: systemd timer, or cron without systemd ----------

use_systemd() { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }

oncalendar() { # OnCalendar for $INTERVAL, at a random offset so nodes don't all refresh together
  local m=$((RANDOM % 60)) h
  if (( INTERVAL < 60 )); then echo "*-*-* *:$((RANDOM % INTERVAL))/$INTERVAL:00"
  elif (( INTERVAL == 1440 )); then printf '*-*-* %02d:%02d:00\n' $((RANDOM % 24)) "$m"
  else h=$((INTERVAL / 60)); printf '*-*-* %d/%d:%02d:00\n' $((RANDOM % h)) "$h" "$m"
  fi
}

cron_when() { # the same for cron
  local m=$((RANDOM % 60)) h
  if (( INTERVAL < 60 )); then echo "$((RANDOM % INTERVAL))-59/$INTERVAL * * * *"
  elif (( INTERVAL == 1440 )); then echo "$m $((RANDOM % 24)) * * *"
  else h=$((INTERVAL / 60)); echo "$m $((RANDOM % h))-23/$h * * *"
  fi
}

ensure_cron() { # a cron daemon and /etc/cron.d, installing cron when it is missing
  if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
    log "no systemd and no cron: installing cron"
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y -qq cron >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq cron; }
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q cronie
    elif command -v yum >/dev/null 2>&1; then yum install -y -q cronie
    fi
  fi
  { command -v cron || command -v crond; } >/dev/null 2>&1 && [ -d /etc/cron.d ] ||
    die "there is no systemd and no cron here, so nothing could refresh the pins"
}

install_schedule() {
  if use_systemd; then
    rm -f "$CRON"   # versions before 1.2 used cron
    cat > "$UNIT_DIR/$TAG.service" <<EOF || die "cannot write $UNIT_DIR/$TAG.service"
[Unit]
Description=pin-hosts: refresh the pinned IPs in /etc/hosts

[Service]
Type=oneshot
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
ExecStart=$SELF update
EOF
    cat > "$UNIT_DIR/$TAG.timer" <<EOF || die "cannot write $UNIT_DIR/$TAG.timer"
[Unit]
Description=pin-hosts: refresh every $INTERVAL min

[Timer]
OnCalendar=$(oncalendar)
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
    cat > "$UNIT_DIR/$TAG-boot.service" <<EOF || die "cannot write $UNIT_DIR/$TAG-boot.service"
[Unit]
Description=pin-hosts: put the block back after boot (cloud-init may rebuild /etc/hosts)
Wants=network-online.target
After=network-online.target cloud-final.service docker.service

[Service]
Type=simple
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
ExecStart=$SELF boot

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$UNIT_DIR/$TAG.service" "$UNIT_DIR/$TAG.timer" "$UNIT_DIR/$TAG-boot.service"
    { systemctl daemon-reload && systemctl enable "$TAG.timer" "$TAG-boot.service" && systemctl restart "$TAG.timer"; } \
      >/dev/null 2>&1 || die "could not enable the systemd timer"
  else
    ensure_cron
    cat > "$CRON" <<EOF || die "cannot write $CRON"
# $TAG: refresh the block in /etc/hosts every $INTERVAL min, and after boot
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
$(cron_when) root $SELF update >/dev/null 2>&1
@reboot root $SELF boot >/dev/null 2>&1
EOF
    chmod 0644 "$CRON"
  fi
}

remove_schedule() {
  local u
  rm -f "$CRON"
  for u in "$TAG.timer" "$TAG.service" "$TAG-boot.service"; do
    [ -f "$UNIT_DIR/$u" ] || continue
    if command -v systemctl >/dev/null 2>&1; then systemctl disable --now "$u" >/dev/null 2>&1; fi
    rm -f "$UNIT_DIR/$u"
  done
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && systemctl daemon-reload >/dev/null 2>&1
  return 0
}

schedule_status() {
  local en ac nx
  if [ -f "$UNIT_DIR/$TAG.timer" ]; then
    en=$(systemctl is-enabled "$TAG.timer" 2>/dev/null); ac=$(systemctl is-active "$TAG.timer" 2>/dev/null)
    nx=$(systemctl show -p NextElapseUSecRealtime --value "$TAG.timer" 2>/dev/null)
    echo "timer    : $(grep -m1 '^OnCalendar=' "$UNIT_DIR/$TAG.timer"), ${en:-unknown}, ${ac:-unknown}, next run: ${nx:-unknown}"
    en=$(systemctl is-enabled "$TAG-boot.service" 2>/dev/null)
    echo "boot job : $TAG-boot.service ${en:-unknown}"
  elif [ -f "$CRON" ]; then
    grep -v -e '^#' -e '=' "$CRON" | sed 's| >/dev/null 2>&1$||; s|^|cron     : |'
  else
    echo "schedule : not installed"
  fi
}

# ---------- commands ----------

cmd_update() {
  need_root
  validate_conf || die "fix $CONF"
  need_tmp
  lock -n || { log "another run is active"; return 0; }
  do_update || exit 1
}

cmd_boot() { # after boot: cloud-init can rebuild /etc/hosts, so wait for it and the network, then refresh
  local i
  need_root
  validate_conf || die "fix $CONF"
  need_tmp
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
  log "WARN boot refresh found nothing to pin; the regular refresh will try again"
}

cmd_status() {
  local blk d ips ip res cls t name f ns sync w
  need_tmp
  echo "version  : $VERSION"
  validate_conf || echo "settings : INVALID - fix $CONF (see the error above)"
  echo "settings : DOMAINS='$DOMAINS' KEEP=$KEEP PREFER=$PREFER IPV6=$IPV6 RESOLVER=$RESOLVER" \
       "CONTAINERS=$CONTAINERS INTERVAL=$INTERVAL TLS_MIN=$TLS_MIN RETRY_DELAY=$RETRY_DELAY"
  echo "DNS used : $(resolvers | tr '\n' ' ')"
  echo "$HOSTS_FILE:"
  blk=$(block_of "$HOSTS_FILE")
  if [ -z "$blk" ]; then
    echo "  (no $TAG block)"
  else
    for d in $(awk '$1 !~ /^#/ {print $2}' <<<"$blk" | awk '!seen[$0]++'); do
      ips=$(awk -v d="$d" '$1 !~ /^#/ && $2 == d {print $1}' <<<"$blk")
      res=$(check_ips "$d" "$(port_for "$d")" $ips)
      for ip in $ips; do
        cls=""; t=""
        read -r cls t _ < <(awk -v ip="$ip" '$3 == ip {print; exit}' <<<"$res")
        case $cls in
          tls) echo "  OK    $ip  $d  (TLS ${t}s)" ;;
          tcp) echo "  FAIL  $ip  $d  (TCP works, TLS $TLS_MIN check failed)" ;;
          *)   echo "  FAIL  $ip  $d  (unreachable)" ;;
        esac
      done
    done
  fi
  ns=$(grep -E '^hosts:' /etc/nsswitch.conf 2>/dev/null | tr -s ' \t' ' ')
  echo "host nsswitch: ${ns:-no /etc/nsswitch.conf (Go reads /etc/hosts first)}"
  if [ -n "$ns" ]; then w=$(nsswitch_warn "$ns"); [ -n "$w" ] && echo "  WARN: $w"; fi
  while read -r name f; do
    if [ -z "$f" ] || [ ! -e "$f" ]; then echo "container $name: hosts file not found"; continue; fi
    if [ ! -r "$f" ]; then echo "container $name: hosts file not readable (run as root)"; continue; fi
    if [ "$(block_of "$f")" = "$blk" ]; then sync=in-sync; else sync=OUT-OF-SYNC; fi
    ns=$(docker cp -L "$name:/etc/nsswitch.conf" - 2>/dev/null | tar -xO 2>/dev/null | grep -E '^hosts:' | tr -s ' \t' ' ')
    echo "container $name: $sync, nsswitch: ${ns:-no /etc/nsswitch.conf (Go reads /etc/hosts first)}"
    if [ -n "$ns" ]; then w=$(nsswitch_warn "$ns"); [ -n "$w" ] && echo "  WARN: $w"; fi
  done < <(container_files)
  cloudinit_manages_hosts && echo "cloud-init: rebuilds $HOSTS_FILE at boot (manage_etc_hosts); the boot job puts the block back"
  schedule_status
}

dns_query_keys() { # tcpdump lines on stdin -> "source id type name" per DNS query, lower case, each query once
  # (-i any shows a query on lo twice, In and Out: the same source port, id and name is still one query)
  sed -nE 's/.* IP6? ([^ ]+) > [^ ]+: ([0-9]+)[^ ]*( \[[^]]*\])* ([A-Za-z0-9]+)\? ([^ ]+) .*/\1 \2 \4 \5/p' |
    tr '[:upper:]' '[:lower:]' | sort -u
}

cmd_verify() {
  local secs=${1:-15} keys e d
  need_root
  validate_conf || die "fix $CONF"
  [[ $secs =~ ^[1-9][0-9]{0,3}$ ]] || die "seconds must be 1-9999"
  command -v tcpdump >/dev/null 2>&1 || die "tcpdump is not installed (apt install tcpdump)"
  echo "counting DNS queries (port 53, all interfaces) for ${secs}s..."
  keys=$(timeout "$secs" tcpdump -nn -l -i any 'port 53' 2>/dev/null | dns_query_keys)
  for e in $DOMAINS; do
    d=${e%%:*}
    echo "  $d: $(awk -v q="$d." '$4 == q' <<<"$keys" | grep -c .) queries"
  done
  echo "(Go and Xray use plain DNS on port 53; a local caching resolver's own upstream queries count as well)"
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
  local src=${BASH_SOURCE[0]:-} def v
  need_root
  need_tmp
  if [ -z "$src" ] || [ ! -f "$src" ]; then
    # Started from a pipe (bash <(curl ...) or curl ... | bash): install the published script and hand over to it,
    # so the code that does the install is exactly the code that stays installed.
    ensure_tools
    curl -fsSL "$REPO_RAW" -o "$TMPD/self" || die "could not download $REPO_RAW"
    head -n 1 "$TMPD/self" | grep -q '^#!.*bash' && grep -q '^TAG=pin-hosts$' "$TMPD/self" && bash -n "$TMPD/self" ||
      die "$REPO_RAW did not return a valid pin-hosts.sh"
    v=$(sed -n 's/^VERSION=//p' "$TMPD/self" | head -n 1)
    [ "$v" = "$VERSION" ] ||
      die "you ran pin-hosts $VERSION but $REPO_RAW is ${v:-unversioned}; to install the copy you ran, run it again with PIN_HOSTS_URL=<the URL you used>"
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
  write_conf
  CONF_LOADED=1
  install_schedule
  lock -w 120 || die "another run still holds $LOCK"
  do_update || log "WARN the first update did not complete; see the errors above"
  unlock
  echo
  cmd_status
}

cmd_uninstall() {
  need_root
  need_tmp
  lock -w 300 || die "an update is still running, try again in a minute"
  apply_block "" || die "the $TAG block could not be removed from $HOSTS_FILE (see above); nothing else was removed"
  remove_schedule
  rm -f "$CONF" "$SELF"
  unlock
  rm -f "$LOCK"
  log "removed (backup of the original hosts file: $HOSTS_FILE.$TAG.bak)"
}

usage() {
  cat <<EOF
pin-hosts $VERSION - pin domain IPs in /etc/hosts (e.g. the REALITY dest), health-checked and refreshed

  pin-hosts.sh install [domain[:port],...]   install; asks for the domains if none are given (Enter = www.apple.com)
  pin-hosts.sh status                        pinned IPs, TLS check, container sync, schedule
  pin-hosts.sh verify [seconds]              count DNS queries for the domains (needs tcpdump)
  pin-hosts.sh update                        refresh now (also runs every $INTERVAL min and after boot)
  pin-hosts.sh uninstall                     remove the pins, the timer, the settings and the script
  pin-hosts.sh version

one-click install: bash <(curl -fsSL $REPO_RAW) install
EOF
}

case ${1:-} in
  version|-v|--version) echo "pin-hosts $VERSION"; exit 0 ;;
esac
load_conf
case ${1:-} in
  install)          shift; cmd_install "$@" ;;
  update)           cmd_update ;;
  boot)             cmd_boot ;;
  status)           cmd_status ;;
  verify)           cmd_verify "${2:-15}" ;;
  uninstall|remove) cmd_uninstall ;;
  *)                usage; exit 1 ;;
esac
