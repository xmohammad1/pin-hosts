# pin-hosts

Pin a domain's IPs in `/etc/hosts`, for example the REALITY `dest` `www.apple.com`, so Xray stops sending a DNS query for it on every inbound connection. The pinned IPs are health-checked and refreshed every hour and after every boot.

REALITY dials its `dest` for every incoming connection, and Xray (Go) does not cache DNS. Without a local cache, a busy node sends one or two DNS queries per connection to its resolver. Each lost DNS packet then adds `timeout` seconds to that connection's handshake. On one busy node, pinning took this from **1284 to 0 DNS queries in 15 seconds**.

## One-click install

As root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh) install
```

As a normal user with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh | sudo bash -s -- install
```

`sudo bash <(curl ...)` does not work, because sudo closes the `/dev/fd/63` pipe before bash can read it. Use the second form.

The installer asks which domains to pin:

```
Domains to pin in /etc/hosts, comma-separated [www.apple.com]:
```

- Press **Enter** to keep the default `www.apple.com`. On a reinstall, Enter keeps the domains you already have.
- Separate several domains with commas: `www.apple.com, tgju.org`.
- Add `:port` when the domain's TLS service is not on 443: `example.com:8443`. The port is used only for the health check, since `/etc/hosts` has no ports.

To install without the prompt, pass the domains as an argument:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh) install www.apple.com,tgju.org
```

When run from a pipe, the installer downloads the published script to `/usr/local/sbin/pin-hosts.sh` and runs that copy, so the code that does the install is the code that stays installed. If the published version differs from the one you ran (for example a fork, or a link to an older commit), it stops instead of installing something else. In that case set `PIN_HOSTS_URL` to the raw URL you want installed. Running the one-click command again updates the script and keeps your settings.

## Commands

| Command | What it does |
|---|---|
| `pin-hosts.sh status` | Shows the pinned IPs with a live TLS check, whether each Docker container's hosts file is in sync, the `nsswitch.conf` order, cloud-init's hosts handling, and the timer. |
| `pin-hosts.sh verify [seconds]` | Counts DNS queries for the pinned domains on all interfaces (default 15 s, needs `tcpdump`). Run it before and after installing to compare. |
| `pin-hosts.sh update` | Refreshes the pins now. The timer runs this every hour. |
| `pin-hosts.sh install [domains]` | Installs or reinstalls the script, asking for domains when none are given. |
| `pin-hosts.sh uninstall` | Removes the pins from the host and the containers, plus the timer, the settings file and the script. If the block can't be removed, nothing else is removed either. |
| `pin-hosts.sh version` | Prints the version. |

## How it works

- **Resolves from the server itself.** CDN answers depend on location, so the IPs come from the node's own upstream DNS (`/etc/resolv.conf`, or systemd-resolved's upstream list). Loopback stubs are skipped, because systemd-resolved and dnsmasq answer from `/etc/hosts` and would return the old pins. `8.8.8.8` and `1.1.1.1` are the fallback, plus their IPv6 addresses on IPv6 servers. A server that answers "no such record" ends the lookup; only a failing server moves on to the next one.
- **Checks only what REALITY needs.** An IP is healthy when it completes a TLS 1.3 handshake with a valid certificate for the domain. A slow or missing HTTP answer after the handshake doesn't matter. The check ignores proxy settings and `~/.curlrc`, so the IP itself is tested, and all IPs are tested at the same time. The fastest fresh DNS answers win, up to `KEEP` per address family. When the picked set is the same as before, the file is not rewritten.
- **Fails safe.** If no pinned IP passes, the check runs once more after `RETRY_DELAY` seconds. If DNS is down, or no IP is reachable at all (an outage on the server's side), the old entries stay. Only when IPs are reachable but none passes the check are that domain's pins removed, so Xray falls back to normal DNS instead of dialing dead IPs.
- **Never damages `/etc/hosts`.** The new file is checked before it is used: everything outside the block must be byte-for-byte the same, and the block must be complete. A full disk, a read-only or immutable file, or broken markers stop the update with an error, and the old file stays as it is. The file is replaced by rename, so no program ever reads a half-written file. When a container bind-mounts the host's `/etc/hosts`, it is written in place instead, so that container sees the update too.
- **Owns one block only.** Everything lives between `# BEGIN pin-hosts` and `# END pin-hosts`, and the rest of `/etc/hosts` is left alone. Markers of other tools, like `# BEGIN pin-hosts-custom`, are not touched. The first run saves a backup to `/etc/hosts.pin-hosts.bak`.
- **Patches Docker containers.** A host-network container such as `pg-node` gets a *copy* of `/etc/hosts` only when it starts. The script rewrites each running host-network container's hosts file in place, so no container restart is needed. Go re-reads the hosts file within about 5 seconds.
- **Runs on a systemd timer.** The refresh runs at a random minute, so several nodes don't all hit the CDN at once. A boot job waits for the network and for cloud-init to finish, then refreshes: many cloud images, Hetzner Cloud included, run cloud-init with `manage_etc_hosts`, which rebuilds `/etc/hosts` at every boot and deletes the block. Without systemd, cron is used, and installed if it is missing. Installing this version on a server with an older cron-based install moves it to the timer.

## Settings

Settings are in `/etc/pin-hosts.conf`. Run `pin-hosts.sh update` after editing, or `pin-hosts.sh install` after changing `INTERVAL`. Invalid values stop the script with an error instead of being used. The file is run as root, so the script refuses to read it unless it is owned by root and writable only by root.

| Setting | Default | Meaning |
|---|---|---|
| `DOMAINS` | `www.apple.com` | Space-separated domains, each with an optional `:port` for the health check |
| `KEEP` | `2` | Number of IPs kept per address family (1–99) |
| `PREFER` | `6` | Family written first (`6` or `4`). Go dials the first family listed first. |
| `IPV6` | `auto` | `auto` pins IPv6 only when the server has an IPv6 route. Also `on` or `off`. |
| `RESOLVER` | `auto` | DNS servers to ask, as IP addresses, e.g. `"185.12.64.1 8.8.8.8"` |
| `CONTAINERS` | `auto` | `auto` = every running host-network container, `none`, or a list of container names |
| `INTERVAL` | `60` | Minutes between refreshes: a divisor of 60 (1–30), or 60, 120, 180, 240, 360, 480, 720, 1440 |
| `TLS_MIN` | `1.3` | Lowest TLS version a pinned IP must speak. REALITY needs 1.3; use `1.2` only for other uses. |
| `RETRY_DELAY` | `10` | Seconds before checking again when every pinned IP fails (`0` = no second check) |

## Requirements

- Linux, root and bash.
- `curl` and `dig` are installed automatically with apt, dnf or yum.
- systemd, or cron, which is installed automatically when there is no systemd.
- Docker is optional; a snap install is found too.
- `tcpdump` is needed only for `verify`.

The name resolution order in `/etc/nsswitch.conf` must have `files` before `dns`, which is the default on Debian and Ubuntu. `status` checks this on the host and inside each container.

`verify` counts each query once, even though `tcpdump -i any` sees a query on `lo` twice. If the server uses a local caching resolver, that resolver's own upstream queries are counted too. Go, and so Xray, always looks up the REALITY dest with plain DNS on port 53, so `verify` sees those lookups.

---

## راهنمای فارسی

این اسکریپت IPهای یک دامنه، مثلاً dest ریالیتی `www.apple.com`، را داخل `/etc/hosts` می‌گذارد تا Xray برای هر کانکشن از DNS نپرسد.

نصب با یک دستور (با کاربر root):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh) install
```

با کاربر معمولی و sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/xmohammad1/pin-hosts/main/pin-hosts.sh | sudo bash -s -- install
```

- **پرسیدن دامنه‌ها:** موقع نصب می‌پرسد برای چه دامنه‌هایی انجام شود. اگر چند دامنه دارید، آن‌ها را با `,` جدا کنید. اگر چیزی وارد نکنید و Enter بزنید، همان `www.apple.com` در نظر گرفته می‌شود. اگر سرویس TLS دامنه روی پورت 443 نیست، پورت را بعد از دامنه بنویسید، مثل `example.com:8443`.
- **فایل hosts داخل کانتینر:** فایل hosts کانتینرهای host network (مثل pg-node) هم بدون ری‌استارت آپدیت می‌شود.
- **آپدیت ساعتی و بعد از ری‌بوت:** هر ساعت (با systemd timer) و بعد از هر ری‌بوت، IPها با یک TLS 1.3 handshake واقعی تست می‌شوند. IPی که از کار افتاده باشد با IP جدید جایگزین می‌شود.
- **رفتار موقع مشکل:** اگر DNS قطع باشد یا اینترنت سرور قطع باشد، پین‌های قبلی می‌مانند. فقط وقتی IPها در دسترس‌اند ولی هیچ‌کدام تست را رد نمی‌کنند، پین آن دامنه برداشته می‌شود تا Xray از DNS معمولی استفاده کند.
- **امنیت فایل hosts:** قبل از جایگزینی، فایل جدید چک می‌شود. اگر دیسک پر باشد یا فایل قابل نوشتن نباشد، فایل قبلی دست نمی‌خورد.
- **دستورها:** `pin-hosts.sh status` وضعیت را نشان می‌دهد، `pin-hosts.sh verify 15` تعداد کوئری‌های DNS را می‌شمارد و `pin-hosts.sh uninstall` همه چیز را حذف می‌کند.
