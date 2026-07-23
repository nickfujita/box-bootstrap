# box-bootstrap

Idempotent, opt-in **personalization** for a fresh, Spellguard-managed EC2 dev
box (Ubuntu + systemd). Spellguard provisions the base image and owns the org
tailnet, `~/.tmux.conf`, and the kernel `tailscaled` it bootstraps. This repo
layers *your* personal tooling on top **without touching anything Spellguard
manages**, and it is safe to re-run — every step is a no-op once it is in place.

It installs four core components (all on by default) plus optional extras:

| Component | What it does |
|-----------|--------------|
| **tailscale** | A *second*, personal `tailscaled` on a **personal tailnet**, in userspace-networking mode, alongside the org-managed daemon. |
| **gogrip** | Installs the [go-grip](https://github.com/nickfujita/go-grip) release binary and runs it as a systemd **user** service (markdown preview on port 6419, nightshade theme). |
| **matrix** | Adds the Claude Code Matrix-bridge plugin, enables `codex-matrix`, and writes `~/.ccmatrix/config.json`. |
| **neovim** | Installs the complete captured Neovim/LazyVim editor, language toolchains, LSPs, and supporting CLI tools. |
| *extras* | `--with-go`, `--with-docker`, `--with-uv` — standalone toolchain installs. |

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
./install.sh                 # core four, including the complete Neovim setup

# Or select components / add extras:
./install.sh --gogrip                    # just one core component
./install.sh --neovim                    # just the complete editor setup
./install.sh --with-go --with-uv         # core four + extras
./install.sh --all                       # core four + every extra

# Install only the editor, without any core box components:
./scripts/install-neovim.sh

# 3. Verify without changing anything:
./install.sh --check
./scripts/install-neovim.sh --check
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

### Neovim / LazyVim

The complete editor setup from the reference VM is captured in
[`dotfiles/nvim`](dotfiles/nvim). Run either:

```bash
# Editor only:
./scripts/install-neovim.sh

# The editor is a default core component:
./install.sh

# Everything box-bootstrap offers:
./install.sh --all
```

The standalone installer starts from a plain Ubuntu 24.04 VM and installs or
converges all of the following:

- Neovim 0.12.4 from the official prebuilt release (with LuaJIT)
- Git, curl, a C compiler, ripgrep, fd, fzf, and lazygit
- Node/npm and `tree-sitter-cli`
- Python 3, Go, Java 21, Swift, and `sourcekit-lsp`
- the captured LazyVim plugin lockfile
- Blink completion plus LSPs, formatters, and linters for JavaScript,
  TypeScript, Python, Go, Swift, Kotlin, Markdown, TOML, JSON, YAML, Docker,
  HTML, CSS, shell, and SQL
- the captured Tree-sitter parsers
- the `n=nvim` Bash alias

The setup uses the **VS Code dark theme only**. AI completion is installed but
starts disabled; `<leader>uA` toggles Copilot/Sidekick suggestions for the
current Neovim session. Ordinary LSP/Blink completion remains enabled.

Toolchain and plugin versions are deliberately pinned to the versions tested
together on the reference VM. The version constants at the top of
[`scripts/install-neovim.sh`](scripts/install-neovim.sh) and
[`dotfiles/nvim/lazy-lock.json`](dotfiles/nvim/lazy-lock.json) are the upgrade
points.

A first install with every language toolchain needs roughly 7 GB of persistent
space and can temporarily use more while Swift and Go tools are unpacked or
built. Start with **at least 10 GB free**; the installer performs a disk-space
preflight and installs Mason packages sequentially to limit peak usage.

#### Existing config and ongoing changes

`dotfiles/nvim` is the source of truth. On the first run:

- if `~/.config/nvim` is absent, it is created;
- if it already matches, it is adopted without a backup;
- if it is an unmanaged, different config, it is preserved as
  `~/.config/nvim.pre-box-bootstrap-<timestamp>`.

Once managed, rerunning the installer intentionally converges
`~/.config/nvim` back to the repository copy, removing local config drift. Make
lasting changes in `dotfiles/nvim`, or make them on the reference VM and
recapture them:

```bash
./scripts/capture-neovim.sh
git diff -- dotfiles/nvim
```

Only configuration is captured. Neovim data, caches, session state, and
credentials are not copied.

#### Per-machine steps

Two things are intentionally not portable:

1. **Copilot authentication.** Tokens are never stored in this repository. On a
   new VM, open Neovim and run `:LspCopilotSignIn` once. Suggestions still
   remain off until `<leader>uA`.
2. **The Nerd Font.** Terminal glyphs are rendered by the SSH client, so keep
   the Nerd Font selected in the iTerm2 profile on the Mac. Installing a font
   on the remote VM does not change iTerm2's rendering.

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
or changed, core service config files are never clobbered, and `tailscale up` /
service enables are skipped when already active. The Neovim config is the one
exception: once marked as managed, it deliberately converges to the checked-in
copy so all VMs stay consistent.

## Repo layout

```
install.sh                              # the idempotent installer
dotfiles/nvim/                          # captured LazyVim configuration + lock
scripts/install-neovim.sh               # standalone full editor installer
scripts/bootstrap-nvim.lua              # headless Mason/Tree-sitter installer
scripts/capture-neovim.sh               # refresh the captured config
units/tailscaled-personal.service       # personal tailscaled (system unit)
units/gogrip.service                    # go-grip preview (user unit)
examples/ccmatrix-config.env.example    # runtime env template (no real secrets)
examples/tmux.conf.local.example        # personal tmux overrides
```
