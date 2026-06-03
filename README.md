# dashboard-install

Public bootstrap for the self-hosted **dashboard**. Holds only the installer
and the compose/stack files — **no source**. The dashboard itself ships as a
published Docker image (`ghcr.io/douglasprado/dashboard-install`), built in CI
from the private source repo.

- `install.sh` — the installer (Linux; auto-dispatches to the macOS twin on a Mac)
- `install-macos.sh` — the macOS-native installer
- `compose.prod.yml` — the dashboard service
- `stack.compose.yml` + `traefik/traefik.yml` — minimal Traefik + `stack_web` network

## One-liner (zero-arg, fresh host)

```bash
curl -sSL https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main/install.sh | bash
```

Installs Docker (latest stable), brings up Traefik + the `stack_web` network,
fetches the compose files, pulls the image, starts the dashboard. With no flags
it defaults the host to `dash.<primary-ip>.nip.io`. **The license key is the
login credential** — every route is gated behind a license-key session, so the
host is never exposed unauthenticated. On first run the dashboard shows an
activation screen; pass `--license <key>` to install it ahead of time.

### Override defaults

```bash
curl -sSL https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main/install.sh \
  | bash -s -- --host dash.192.168.3.139.nip.io --license <key> \
      --image ghcr.io/douglasprado/dashboard-install:v0.1.0
```

`bash -s --` forwards the flags. `--no-bootstrap` requires Docker + the stack
already present (just installs the dashboard). `--password` / `--trust-proxy`
are optional and only add an operator identity for admin-role authz; they are
not required to boot or to log in.

## macOS

The one-liner works on a Mac too — `install.sh` detects Darwin and hands off to
`install-macos.sh` (the native twin: same steps, macOS commands). It uses
**Homebrew** for Docker Desktop / git / Node, enables **Remote Login** for the
container→host SSH, and installs the agent runtimes.

```bash
# from your admin account (the Docker Desktop user); sudo is required for
# Remote Login + host provisioning, and Homebrew is run as that admin user.
sudo ./install-macos.sh --license <key>
```

Key differences from Linux, by design:

- **Docker runtime: Docker Desktop.** Bootstrap can `brew install --cask docker`
  and `open -a Docker`, but Docker Desktop needs a one-time GUI launch to accept
  its terms before the engine is ready.
- **The executor is your admin user, not a dedicated `claude-bots`.** Docker
  Desktop's socket is owned by the GUI user; a separate user couldn't reach it,
  so host-side `docker compose` (update-live, branch-switch restart) would break.
  Run `install-macos.sh` via `sudo` from that admin account — `SUDO_USER` becomes
  the executor (`compose.prod.yml` reads it via `EXECUTOR_USER` /
  `EXECUTOR_CLAUDE_DIR`).
- **sshd is the built-in one.** If `:22` doesn't come up, enable it in
  **System Settings → General → Sharing → Remote Login** (the `systemsetup`
  fallback may need Full Disk Access for your terminal).
- **The host workspace is created at `/root/workspace`** (the path the image
  hardcodes), owned by the executor, with `/root` set mode `711` for traverse.

`--no-bootstrap` is also supported on macOS (skips Docker/Remote-Login/runtime
setup; expects them already present).

## Reach it from anywhere (Tailscale)

Pass `--tailscale` to install Tailscale, bring the host into your tailnet, and
serve the dashboard at `dash.<tailscale-ip>.nip.io` **through Traefik**. The
node's `100.x` Tailscale IP is routed across the tailnet from any device, `nip.io`
resolves the hostname to it from any network, and Traefik (the shared stack)
routes it by Host on `:80`. So you reach it from any device on your tailnet
(phone, laptop — any network, anywhere) with **no public IP, no port-forward, no
subnet route or admin approval** — and only the dashboard is exposed (not the
whole LAN). **Funnel stays OFF**: nothing is published to the public internet.
With no `--host`, `dash.<tailscale-ip>.nip.io` is used automatically.

Per-session preview subdomains (`dashboard-<sid>.<ip>.nip.io`) inherit the same
IP via `HOST_IP`, so previews are reachable remotely too — Traefik routes them
the same way (this is why Traefik, not Tailscale Serve, fronts the app).

```bash
sudo ./install.sh --tailscale --license <key> \
  --image ghcr.io/douglasprado/dashboard-install@sha256:<digest>
# unattended: provide a Tailscale auth key so `tailscale up` doesn't need a browser
sudo ./install.sh --tailscale --ts-authkey tskey-auth-... --license <key>
```

Access is over HTTP, but tailnet traffic is already encrypted end-to-end by
Tailscale (WireGuard). What stays interactive (OAuth/browser, can't be
automated): `tailscale up` without `--ts-authkey`, and each runtime's one-time
login (`claude /login`, etc.).

**Firewall is not automated**: the executor reaches the host over the Docker
bridge (not `tailscale0`), so a naive `ufw default deny + allow tailscale0` would
break agent runs — see the dashboard's `docs/RUNBOOK.md` for a host firewall that
allows both.

## Don't pipe blind

`curl | bash` runs code you didn't read. Before trusting it:

```bash
curl -sSL .../install.sh -o install.sh
shasum -a 256 install.sh        # compare against the release checksum
less install.sh                 # read it
./install.sh --check --host <host>   # validates, writes nothing
```

The installer also prints the `sha256` of the fetched `compose.prod.yml` so you
can verify it before the stack comes up.

## Prerequisites

- Docker + Docker Compose v2, `curl`.
- The shared `stack` (Traefik on the `stack_web` network).
- A license key to log in (install via `--license` or paste on the first-run
  screen). The license-key session is the access gate — no separate auth flag
  is required to boot.

See the dashboard's `docs/INSTALL.md` and `docs/RUNBOOK.md` for the full flow and
host hardening.

## Security & trust model

Be honest about what the distribution does and does not protect — these are the
threat-model facts to weigh before selling licenses:

- **The container is a privileged host orchestrator.** It mounts the Docker
  socket (to manage containers, read logs, run the security scanners) and holds
  an SSH key into the host executor (`claude-bots`). Anyone who reaches the
  socket or that key has root-equivalent control of the host. The runtime
  hardening (`read_only`, `cap_drop: ALL`, `no-new-privileges`) limits damage
  from a *compromised dependency or agent*, not from this intended access. The
  `:ro` on the socket is cosmetic — it does not restrict the Docker API.
- **The image ships minified, source-free JS.** A CI guard rejects any release
  that leaks `.ts`/sourcemaps/`/src`. This raises the cost of extraction; it is
  friction, not DRM. A root-on-host operator can still read the running bundle.
- **The license is an offline, signed token (no phone-home).** It is verified
  against an embedded public key; production ignores env overrides of the trust
  anchor and always enforces. **Known limitation (v1):** the token is not bound
  to a host, so one key can run on multiple installs — `expiresAt` is the only
  limiter, and a leaked key cannot be revoked before it expires. Per-install
  binding or a phone-home activation server is the lever to close this and is
  deferred until the customer base justifies operating that service.
- **The image is pinned fail-safe, the runtime is not yet.** `compose.prod.yml`
  refuses to start as root when `.env` is missing (the socket-mounted container
  must run as the executor uid), and the installer warns when the image is not
  digest-pinned. **Still open:** the installer pipes several third-party install
  scripts straight into a root or executor shell (Docker, Tailscale, the agent
  runtime CLIs, caveman, RTK), unpinned and unverified — a compromise of any of
  those endpoints is RCE on the host. Pinning each to a release tag/commit plus a
  `sha256` check is deferred (it needs the upstreams' pinned refs); until then,
  treat bootstrap as trusting those vendors. `--no-bootstrap` avoids most of them.
- **The host executor's SSH key is unrestricted.** The dashboard holds a
  passphrase-less key into the `claude-bots` user, whose `authorized_keys` entry
  carries no `from=`/`restrict`/forced-command. A leaked key is an interactive
  shell as the executor (owns `/root/workspace`, traverses `/root`, runs agents).
  Narrowing the entry is deferred until the dashboard's exact SSH usage (pty,
  forwarding) is confirmed, so as not to break agent runs.
- **The executor is in the host `docker` group.** It runs `docker compose` on the
  host over SSH (update-live, branch-switch restart), which needs access to
  `docker.sock` (`root:docker`). Membership in the `docker` group is
  root-equivalent on the host, so a compromise of the `claude-bots` user is a
  host root compromise. This is the same trust boundary as the unrestricted SSH
  key above. On rootless/podman hosts (no `docker` group) host-side compose is
  skipped and the installer warns instead.
