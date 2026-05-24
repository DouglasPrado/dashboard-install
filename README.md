# dashboard-install

Public bootstrap for the self-hosted **dashboard**. Holds only the installer
(`install.sh`) and the distribution compose (`compose.prod.yml`) — **no source**.
The dashboard itself ships as a published Docker image
(`ghcr.io/douglasprado/dashboard`).

## One-liner

```bash
curl -sSL https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main/install.sh \
  | bash -s -- --host dash.example.ts.net --trust-proxy \
      --image ghcr.io/douglasprado/dashboard:v0.1.0
```

`bash -s --` forwards the flags to the piped script. The installer fetches
`compose.prod.yml` from this repo, generates per-host secrets locally, writes
`.env` (mode 600), pulls the image, and brings the stack up.

### Basic auth instead of Tailscale identity

```bash
curl -sSL https://raw.githubusercontent.com/DouglasPrado/dashboard-install/main/install.sh \
  | bash -s -- --host dash.192.168.3.139.nip.io --password 's3cret' \
      --image ghcr.io/douglasprado/dashboard:v0.1.0
```

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
