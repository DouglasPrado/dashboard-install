# dashboard-install

Public bootstrap for the self-hosted **dashboard**. Holds only the installer
and the compose/stack files — **no source**. The dashboard itself ships as a
published Docker image (`ghcr.io/douglasprado/dashboard`).

- `install.sh` — the installer
- `compose.prod.yml` — the dashboard service
- `stack.compose.yml` + `traefik/traefik.yml` — minimal Traefik + `stack_web` network

## One-liner (zero-arg, fresh host)

```bash
curl -sSL https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main/install.sh | bash
```

Installs Docker (pinned 28.x), brings up Traefik + the `stack_web` network,
fetches the compose files, pulls the image, starts the dashboard. With no flags
it defaults the host to `dash.<primary-ip>.nip.io` and **generates a random
basic-auth password**, printed at the end. The host is never exposed without
auth.

### Override defaults

```bash
curl -sSL https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main/install.sh \
  | bash -s -- --host dash.192.168.3.139.nip.io --password 's3cret' \
      --image ghcr.io/douglasprado/dashboard:v0.1.0
```

`bash -s --` forwards the flags. `--no-bootstrap` requires Docker + the stack
already present (just installs the dashboard). `--trust-proxy` trusts a proxy
identity header instead of a password.

## Don't pipe blind

`curl | bash` runs code you didn't read. Before trusting it:

```bash
curl -sSL .../install.sh -o install.sh
shasum -a 256 install.sh        # compare against the release checksum
less install.sh                 # read it
./install.sh --check --host <host> --trust-proxy   # validates, writes nothing
```

The installer also prints the `sha256` of the fetched `compose.prod.yml` so you
can verify it before the stack comes up.

## Prerequisites

- Docker + Docker Compose v2, `curl`.
- The shared `stack` (Traefik on the `stack_web` network).
- Auth is mandatory: `--trust-proxy` (behind Tailscale Serve) **or** `--password`.
  The dashboard refuses to boot exposed without auth.

See the dashboard's `docs/INSTALL.md` and `docs/RUNBOOK.md` for the full flow and
host hardening.
