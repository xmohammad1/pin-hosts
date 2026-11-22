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

When run from a pipe, the installer downloads the script to `/usr/local/sbin/pin-hosts.sh` and runs that copy, so the code that does the install is the code that stays installed. Running the one-click command again updates the script and keeps your settings. To install from a mirror, set `PIN_HOSTS_URL` to another raw URL of `pin-hosts.sh`.

## Commands

| Command | What it does |
|---|---|
| `pin-hosts.sh status` | Shows the pinned IPs with a live TLS check, whether each Docker container's hosts file is in sync, cloud-init's hosts handling, and the cron lines. |
| `pin-hosts.sh verify [seconds]` | Counts DNS queries for the pinned domains on all interfaces (default 15 s, needs `tcpdump`). Run it before and after installing to compare. |
| `pin-hosts.sh update` | Refreshes the pins now. Cron runs this every hour. |
| `pin-hosts.sh install [domains]` | Installs or reinstalls the script, asking for domains when none are given. |
| `pin-hosts.sh uninstall` | Removes the pins from the host and the containers, plus the cron job, the settings file and the script. If the block can't be removed, nothing else is removed either. |
| `pin-hosts.sh version` | Prints the version. |

## How it works

- **Resolves from the server itself.** CDN answers depend on location, so the IPs come from the node's own upstream DNS (`/etc/resolv.conf`, or systemd-resolved's upstream list). Loopback stubs are skipped, because systemd-resolved and dnsmasq answer from `/etc/hosts` and would return the old pins. `8.8.8.8` and `1.1.1.1` are the fallback.
- **Checks only what REALITY needs.** An IP is healthy when it completes a TLS handshake with a valid certificate for the domain. A slow or missing HTTP answer after the handshake doesn't matter. The fastest fresh DNS answers win, up to `KEEP` per address family. When the picked set is the same as before, the file is not rewritten.
- **Fails safe.** If DNS is down, the old entries stay. If DNS works but no IP passes the check, that domain's pins are removed, so Xray falls back to normal DNS instead of dialing dead IPs.
- **Patches Docker containers.** A host-network container such as `pg-node` gets a *copy* of `/etc/hosts` only when it starts. The script rewrites each running host-network container's hosts file in place, so no container restart is needed. Go re-reads the hosts file within about 5 seconds.
- **Writes `/etc/hosts` atomically.** The new file is renamed into place, so no program ever reads a half-written file. When a container bind-mounts the host's `/etc/hosts`, the file is written in place instead, so that container sees the update too.
- **Owns one block only.** Everything lives between `# BEGIN pin-hosts` and `# END pin-hosts`, and the rest of `/etc/hosts` is left alone. The first run saves a backup to `/etc/hosts.pin-hosts.bak`.
- **Survives reboots.** Many cloud images, Hetzner Cloud included, run cloud-init with `manage_etc_hosts`, which rebuilds `/etc/hosts` at every boot and deletes the block. An `@reboot` job waits for cloud-init and the network, then puts the block back. The hourly refresh runs at a random minute, so several nodes don't all hit the CDN at once.

## Settings

Settings are in `/etc/pin-hosts.conf`. Run `pin-hosts.sh update` after editing, or `pin-hosts.sh install` after changing `INTERVAL`. Invalid values stop the script with an error instead of being used.

| Setting | Default | Meaning |
|---|---|---|
| `DOMAINS` | `www.apple.com` | Space-separated domains, each with an optional `:port` for the health check |
| `KEEP` | `2` | Number of IPs kept per address family (1–99) |
| `PREFER` | `6` | Family written first (`6` or `4`). Go dials the first family listed first. |
| `IPV6` | `auto` | `auto` pins IPv6 only when the server has an IPv6 route. Also `on` or `off`. |
| `RESOLVER` | `auto` | DNS servers to ask, e.g. `"185.12.64.1 8.8.8.8"` |
| `CONTAINERS` | `auto` | `auto` = every running host-network container, `none`, or a list of container names |
| `INTERVAL` | `60` | Minutes between refreshes: 1–59, or whole hours from 60 to 1440 |

## Requirements

- Linux, root and bash.
- `curl` and `dig` are installed automatically with apt, dnf or yum.
- Docker is optional; a snap install is found too.
- `tcpdump` is needed only for `verify`.

The name resolution order in `/etc/nsswitch.conf` must have `files` before `dns`, which is the default on Debian and Ubuntu. `status` checks this inside each container as well.

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
- **آپدیت ساعتی و بعد از ری‌بوت:** هر ساعت و بعد از هر ری‌بوت، IPها با یک TLS handshake واقعی تست می‌شوند. IPی که از کار افتاده باشد با IP جدید جایگزین می‌شود. اگر DNS کار کند ولی هیچ IPی سالم نباشد، پین آن دامنه برداشته می‌شود تا Xray از DNS معمولی استفاده کند. بعد از ری‌بوت هم اگر cloud-init فایل hosts را از نو ساخته باشد، بلوک دوباره اضافه می‌شود.
- **دستورها:** `pin-hosts.sh status` وضعیت را نشان می‌دهد، `pin-hosts.sh verify 15` تعداد کوئری‌های DNS را می‌شمارد و `pin-hosts.sh uninstall` همه چیز را حذف می‌کند.
