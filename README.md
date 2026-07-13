# box-bootstrap

Idempotent, opt-in **personalization** for a fresh, Spellguard-managed EC2 dev
box (Ubuntu + systemd). Spellguard provisions the base image and owns the org
tailnet, `~/.tmux.conf`, and the kernel `tailscaled` it bootstraps. This repo
layers *your* personal tooling on top **without touching anything Spellguard
manages**, and it is safe to re-run — every step is a no-op once it is in place.

It installs three core components (all on by default) plus optional extras:

| Component | What it does |
|-----------|--------------|
| **tailscale** | A *second*, personal `tailscaled` on a **personal tailnet**, in userspace-networking mode, alongside the org-managed daemon. |
| **gogrip** | Installs the [go-grip](https://github.com/nickfujita/go-grip) release binary and runs it as a systemd **user** service (markdown preview on port 6419, nightshade theme). |
| **matrix** | Adds the Claude Code Matrix-bridge plugin, enables `codex-matrix`, and writes `~/.ccmatrix/config.json`. |
| *extras* | `--with-go`, `--with-docker`, `--with-uv` — standard toolchain installs. |

## The two-daemon model

The box already runs an **org-managed kernel `tailscaled`** (Spellguard's — do
not touch it). This repo adds a **second, personal `tailscaled`** so you can be
on your own tailnet at the same time. The two daemons must not fight over the
network stack, so the personal one runs in **userspace-networking mode**:

- `--tun=userspace-networking` → it creates **no TUN device** and installs
  **no routes**, so it cannot collide with the managed daemon's CGNAT
  (`100.64.0.0/10`) routes or its TUN device.
- Traffic *into* the personal tailnet goes through the SOCKS5 / HTTP proxy the
  personal daemon exposes on **`localhost:1055`** (that is why the Matrix bridge
  defaults its `proxy_url` to `http://127.0.0.1:1055`).
- A distinct UDP `--port=41642` (vs the managed daemon's default `41641`) and a
  private `--socket` / `--statedir` keep the two daemons fully separate.

See [`units/tailscaled-personal.service`](units/tailscaled-personal.service) for
the exact invocation.

## Quick start

```bash
# 1. Fill in your runtime env (secrets stay OUT of this repo).
cp examples/ccmatrix-config.env.example ~/bootstrap.env
chmod 600 ~/bootstrap.env
$EDITOR ~/bootstrap.env

# 2. Load it and run the installer.
set -a; . ~/bootstrap.env; set +a
./install.sh                 # core three: tailscale + gogrip + matrix

# Or select components / add extras:
./install.sh --gogrip                    # just one core component
./install.sh --with-go --with-uv         # core three + extras
./install.sh --all                       # core three + every extra

# 3. Verify without changing anything:
./install.sh --check
```

Run `./install.sh --help` for the full flag list.

### Runtime environment

All secrets are read from the environment — nothing sensitive is ever written
into this repo. See
[`examples/ccmatrix-config.env.example`](examples/ccmatrix-config.env.example)
for the complete list. The installer refuses with a clear message if a value it
needs is missing.

| Variable | Used by | Required |
|----------|---------|----------|
| `TS_AUTHKEY` | tailscale | Yes, unless the personal tailnet is already up |
| `BOX_NAME` | tailscale | Yes, unless already up |
| `CCMATRIX_HOMESERVER` | matrix | Yes, unless `~/.ccmatrix/config.json` exists |
| `CCMATRIX_USER_ID` | matrix | Yes, unless config exists |
| `CCMATRIX_ACCESS_TOKEN` | matrix | Yes, unless config exists |
| `CCMATRIX_ADMIN_USER_ID` | matrix | Yes, unless config exists |
| `CCMATRIX_PROXY_URL` | matrix | No — defaults to `http://127.0.0.1:1055` |
| `CCMATRIX_VM_LETTER` | matrix | Yes, unless already exported in `~/.profile` |
| `PLUGINS_REPO_URL` | matrix | No — defaults to `nickfujita/matrix-bridge-plugin` |

## What each component does

### tailscale (personal, userspace)

1. Installs the `tailscaled` binary from Tailscale's **static package download**
   only if it is missing (managed boxes already ship it).
2. Installs [`units/tailscaled-personal.service`](units/tailscaled-personal.service)
   as a **system** unit and enables it.
3. Brings the node up on the personal tailnet:
   `tailscale --socket=… up --authkey=$TS_AUTHKEY --advertise-tags=tag:cloud-dev
   --hostname=$BOX_NAME`. Skipped if the tailnet is already up.

### gogrip

Downloads the go-grip **release binary** to `~/.local/bin/go-grip`, installs
[`units/gogrip.service`](units/gogrip.service) as a systemd **user** unit, runs
`loginctl enable-linger $USER`, and enables the service (markdown preview on
port 6419 with the built-in `nightshade` theme).

> Pulls `go-grip-linux-amd64` from the fork's **GitHub Releases** (latest). The
> preview is reachable only through the box provider's managed Tailscale — the
> personal daemon runs `--shields-up` and accepts no inbound connections.

### matrix

1. `claude plugin marketplace add "$PLUGINS_REPO_URL"` (idempotent) and
   `codex-matrix enable`.
2. Writes `~/.ccmatrix/config.json` at mode **0600** from the `CCMATRIX_*` env
   vars — only if it does not already exist.
3. Appends `export CCMATRIX_VM_LETTER=…` to `~/.profile` (once).
4. Installs [`examples/tmux.conf.local.example`](examples/tmux.conf.local.example)
   to `~/.tmux.conf.local` **only if absent**.

> `PLUGINS_REPO_URL` defaults to
> [`nickfujita/matrix-bridge-plugin`](https://github.com/nickfujita/matrix-bridge-plugin).
> Override it to install from a fork or a local marketplace.

> **Why `~/.tmux.conf.local`?** Spellguard **overwrites `~/.tmux.conf` on every
> bootstrap**, so edits there are lost. The managed `~/.tmux.conf` sources
> `~/.tmux.conf.local`, which Spellguard never touches — so personal tmux
> settings must live there.

## Nick-side prerequisites (personal tailnet admin console)

These are one-time setup steps in the **personal** tailnet before a box can join.

### 1. Declare the tag owner

In the tailnet policy file (`tagOwners`), define `tag:cloud-dev` so nodes may
advertise it:

```jsonc
"tagOwners": {
  "tag:cloud-dev": ["autogroup:admin"]  // or your personal login
}
```

### 2. ACL grants

`tag:cloud-dev` is deliberately **outbound-only, single-purpose**: the box may
exchange Matrix messages with your homeserver (authenticated by its own scoped
access token) and NOTHING else. Do not add grants with `tag:cloud-dev` as a
destination — no SSH, no preview ports, nothing. Inbound access to a managed
box (SSH, go-grip preview, etc.) should come exclusively through the box
provider's own Tailscale setup (e.g. the provisioning option that shares the
box to your account) — punching inbound holes through this second daemon would
circumvent the security posture of the managed box.

```jsonc
"acls": [
  // The ONLY grant for cloud dev boxes: reach the Matrix homeserver.
  // Replace with your homeserver's tailnet IP (or a tag, e.g. "tag:matrix:6167").
  { "action": "accept", "src": ["tag:cloud-dev"], "dst": ["<homeserver-ip>:6167"] }
]
```

### 3. Mint a tagged auth key

Create a reusable (and ideally ephemeral) auth key **authorized for
`tag:cloud-dev`** in the admin console (Settings → Keys). That key becomes
`TS_AUTHKEY` in the box's runtime env. Because it is pre-authorized for the tag,
the node comes up already tagged and the ACLs above apply immediately.

### 4. Remember the two-daemon model

The personal daemon is userspace-only and brought up with `--shields-up`, so it
initiates outbound connections through its local `:1055` proxy and refuses all
inbound connections from the personal tailnet. To browse go-grip or SSH into
the box, use the address the box provider's managed Tailscale setup gives you
(e.g. the org-tailnet hostname or a device share) — not the personal-tailnet
IP.

## Idempotency & checks

Every component ships a `--check` probe. `./install.sh --check` reports each
selected component as satisfied or not and changes nothing (exit non-zero if any
selected component is incomplete). Re-running `./install.sh` is a no-op when
everything is already in place: binaries/units are only (re)written when missing
or changed, config files are never clobbered, and `tailscale up` / service
enables are skipped when already active.

## Repo layout

```
install.sh                              # the idempotent installer
units/tailscaled-personal.service       # personal tailscaled (system unit)
units/gogrip.service                    # go-grip preview (user unit)
examples/ccmatrix-config.env.example    # runtime env template (no real secrets)
examples/tmux.conf.local.example        # personal tmux overrides
```
