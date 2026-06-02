# dashboard-install

Public bootstrap for the self-hosted **dashboard**. Holds only the installer
and the compose/stack files — **no source**. The dashboard itself ships as a
published Docker image (`ghcr.io/douglasprado/dashboard-install`), built in CI
from the private source repo.

- `install.sh` — the installer
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

## Reach it from anywhere (Tailscale)

Pass `--tailscale` to install Tailscale, bring the host into your tailnet, and
front the dashboard with **Tailscale Serve** — HTTPS terminated on the tailnet,
the `Tailscale-User-Login` identity header injected, and **Funnel kept OFF** so
nothing is exposed to the public internet. You then reach it from any device on
your tailnet (phone, laptop — any network, anywhere) with no public IP and no
port-forward. With no `--host`, the node's MagicDNS name is used automatically.

```bash
sudo ./install.sh --tailscale --license <key> \
  --image ghcr.io/douglasprado/dashboard-install@sha256:<digest>
# unattended: provide a Tailscale auth key so `tailscale up` doesn't need a browser
sudo ./install.sh --tailscale --ts-authkey tskey-auth-... --license <key>
```

What stays interactive (OAuth/browser, can't be automated): `tailscale up`
without `--ts-authkey`, and each runtime's one-time login (`claude /login`, etc.).

The compose file publishes the app on `127.0.0.1:3001` (loopback only) for Serve
to proxy. **Firewall is not automated**: the executor reaches the host over the
Docker bridge (not `tailscale0`), so a naive `ufw default deny + allow tailscale0`
would break agent runs — see the dashboard's `docs/RUNBOOK.md` for a host firewall
that allows both.

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
