# box-bootstrap

Idempotent, opt-in **personalization** for a fresh, Spellguard-managed EC2 dev
box (Ubuntu + systemd). Spellguard provisions the base image and owns the org
tailnet, `~/.tmux.conf`, and the kernel `tailscaled` it bootstraps. This repo
layers *your* personal tooling on top **without touching anything Spellguard
manages**, and it is safe to re-run — every step is a no-op once it is in place.

It installs four core components (all on by default), six opt-in
agent-environment components, plus optional extras:

| Component | What it does |
|-----------|--------------|
| **tailscale** | A *second*, personal `tailscaled` on a **personal tailnet**, in userspace-networking mode, alongside the org-managed daemon. |
| **gogrip** | Installs the [go-grip](https://github.com/nickfujita/go-grip) release binary and runs it as a systemd **user** service (markdown preview on port 6419, nightshade theme). |
| **matrix** | Adds the Claude Code Matrix-bridge plugin, enables `codex-matrix`, and writes `~/.ccmatrix/config.json`. |
| **neovim** | Installs the complete captured Neovim/LazyVim editor, language toolchains, LSPs, and supporting CLI tools. |
| *extras* | `--with-go`, `--with-docker`, `--with-uv` — standalone toolchain installs. |

Agent-environment components — **opt in** with the flag, or take all six with
`--agents`. They are off by default because they write files a managed box may
already have opinions about:

| Component | What it does |
|-----------|--------------|
| **agent-config** | `~/.claude/settings.json` (model pin, effort level, attribution-blocker hook, notification hooks) + the three official Claude plugins. |
| **codex-config** | `~/.codex` portable config keys, the three custom agents, the reconciliation skill, and the Codex plugins. |
| **shell** | One marker-guarded block in `~/.bashrc`: PATH, agent aliases, the alias/function suite, Node heap, nvm auto-use, pnpm and Go PATH. |
| **dark-factory** | `just`, `agent-browser` + its Chromium build, and the [dark-factory](https://github.com/nickfujita/dark-factory) plugin installed on both harnesses (Claude Code and Codex). Removes any sync-mode skill copies an earlier generation left in `~/.claude/skills` or `~/.codex/skills`. |
| **notifications** | `~/.local/bin/notify-*.sh` push hooks for Claude and Codex, with the webhook credential kept in a separate 0600 file. |
| **global-instructions** | `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` rendered from vendored templates. |

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
cp examples/bootstrap.env.example ~/bootstrap.env
chmod 600 ~/bootstrap.env
$EDITOR ~/bootstrap.env

# 2. Load it and run the installer.
set -a; . ~/bootstrap.env; set +a
./install.sh                 # core four, including the complete Neovim setup

# Or select components / add extras:
./install.sh --gogrip                    # just one core component
./install.sh --neovim                    # just the complete editor setup
./install.sh --agents                    # the six agent-environment components
./install.sh --shell --notifications     # just those two
./install.sh --with-go --with-uv         # core four + extras
./install.sh --all                       # core four + agents six + every extra

# Install only the editor, without any core box components:
./scripts/install-neovim.sh

# 3. Verify without changing anything:
./install.sh --check
./install.sh --agents --check
./scripts/install-neovim.sh --check
```

Run `./install.sh --help` for the full flag list.

### Runtime environment

All secrets are read from the environment — nothing sensitive is ever written
into this repo. See
[`examples/bootstrap.env.example`](examples/bootstrap.env.example)
for the complete list. The installer refuses with a clear message if a value it
needs is missing.

| Variable | Used by | Required |
|----------|---------|----------|
| `TS_AUTHKEY` | tailscale | Yes, unless the personal tailnet is already up |
| `BOX_NAME` | tailscale, global-instructions | Yes, unless already up / `GOGRIP_BASE_URL` is set |
| `CCMATRIX_HOMESERVER` | matrix | Yes, unless `~/.ccmatrix/config.json` exists |
| `CCMATRIX_USER_ID` | matrix | Yes, unless config exists |
| `CCMATRIX_ACCESS_TOKEN` | matrix | Yes, unless config exists |
| `CCMATRIX_ADMIN_USER_ID` | matrix | Yes, unless config exists |
| `CCMATRIX_PROXY_URL` | matrix | No — defaults to `http://127.0.0.1:1055` |
| `CCMATRIX_VM_LETTER` | matrix | Yes, unless already exported in `~/.profile` |
| `PLUGINS_REPO_URL` | matrix | No — defaults to `nickfujita/matrix-bridge-plugin` |
| `MOSHI_WEBHOOK_URL` | notifications | Yes, unless `~/.config/moshi/webhook.env` exists |
| `MOSHI_WEBHOOK_TOKEN` | notifications | No — omit for an endpoint that authenticates by URL alone |
| `PERSONAL_TAILNET` | global-instructions | Yes, unless `GOGRIP_BASE_URL` is set |
| `GOGRIP_BASE_URL` | global-instructions | No — assembled from `BOX_NAME` + `PERSONAL_TAILNET` |
| `CLOUDFLARE_API_TOKEN` | shell | No — needed for wrangler / Spellguard dev-stack deploys |
| `NODE_MAX_OLD_SPACE_MB` | shell | No — defaults to `12288` |
| `DARK_FACTORY_REPO_URL` | dark-factory | No — defaults to the public `nickfujita/dark-factory` |
| `CLAUDE_MARKETPLACE` | agent-config | No — defaults to `anthropics/claude-plugins-official` |

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

> Selects the matching Linux asset from the latest
> [`nickfujita/go-grip` release](https://github.com/nickfujita/go-grip/releases).
> The preview is reachable only through the box provider's managed Tailscale.
> The personal daemon runs `--shields-up` and accepts no inbound connections.

### matrix

1. `claude plugin marketplace add "$PLUGINS_REPO_URL"` (idempotent) and
   `codex-matrix enable`.
2. Writes `~/.ccmatrix/config.json` at mode **0600** from the `CCMATRIX_*` env
   vars — only if it does not already exist.
3. Appends `export CCMATRIX_VM_LETTER=…` to
   `~/.config/box-bootstrap/shell.env` (once).
4. Installs [`examples/tmux.conf.local.example`](examples/tmux.conf.local.example)
   to `~/.tmux.conf.local` **only if absent**. The override uses the reference
   VM's gray status bar and shows `[box-name]` before the window list.

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

### agent-config (Claude Code)

1. Installs a templated `~/.claude/settings.json` from
   [`dotfiles/claude/settings.template.json`](dotfiles/claude/settings.template.json):
   the model pin, `effortLevel`, and the inline `PreToolUse` hook that denies any
   Bash command carrying the Claude attribution footer.
2. The `Stop` / `Notification` hooks point at `~/.local/bin/notify-claude.sh` and
   `~/.local/bin/notify-claude-attention.sh`. They are **only written when
   `--notifications` is also selected or those scripts already exist**, so the
   settings file never references a script that is not there.
3. Installs `context7`, `typescript-lsp`, and `pyright-lsp` from
   `claude-plugins-official` **through `claude plugin install`**. A hand-copied
   plugin directory never auto-updates, so the official CLI is the only
   supported path.

> **Never clobbered.** An existing `settings.json` is deep-merged with `jq`: the
> keys above win, and everything else the file holds — `enabledPlugins`,
> `extraKnownMarketplaces`, provider-written keys — survives. A timestamped
> `settings.json.pre-box-bootstrap-<ts>` backup is taken before any change.
> Without `jq` the file is replaced wholesale, after the same backup.

> **`spellguard@spellguard` is never installed here.** The box provider's
> managed provisioning owns that plugin. `--check` reports whether it is
> present, and its absence is never a box-bootstrap failure. `slack` and
> `frontend-design` are deliberately left out too.

### codex-config

1. Installs the three custom agents (`luna-max`, `terra-xhigh`,
   `sol-high`) into `~/.codex/agents/`.
2. Merges [`dotfiles/codex/config.portable.toml`](dotfiles/codex/config.portable.toml)
   into `~/.codex/config.toml` **additively** via
   [`scripts/merge-codex-config.sh`](scripts/merge-codex-config.sh).
3. Installs `github@openai-curated` with `codex plugin add`.

> **The merge only ever adds.** A key that already exists — at the top level or
> inside `[agents]` — keeps its value and its comments. Tables the baseline does
> not name are never read or rewritten, which is what keeps the sections a
> managed provider owns safe: `shell_environment_policy`, `hooks.state`,
> `projects`, and `marketplaces`. The file is written through its existing inode
> so it keeps its mode (`0600`), and a timestamped backup is taken first.
>
> `./scripts/merge-codex-config.sh --check --baseline … --target …` prints the
> missing keys and changes nothing.

> The Codex `spellguard` plugin is never installed here either — same reason as
> on the Claude side.

### shell

Splices [`dotfiles/shell/bashrc-block.sh`](dotfiles/shell/bashrc-block.sh) into
`~/.bashrc` between

```text
# >>> box-bootstrap shell block >>>
# <<< box-bootstrap shell block <<<
```

Re-running compares the region and only rewrites it when the vendored block has
changed (backing `~/.bashrc` up first). Content outside the markers is never
touched. The block carries: `~/.local/bin` on PATH, the `claude`/`codex`
skip-permission aliases, the general/notification/pnpm/npm/git/docker
alias suite, the Node heap ceiling, nvm auto-use on `cd`, the pnpm global bin
PATH, and the Go PATH.

> **Two things are deliberately excluded.** The tmux auto-attach block — a
> managed box appends its own, and a second one double-attaches on every
> login — and the go-grip preview line, which the `--gogrip` component's systemd
> user unit owns. `--check` fails if it finds more than one tmux auto-attach in
> `~/.bashrc`.

> **`CLOUDFLARE_API_TOKEN` never lands in `~/.bashrc`.** When the variable is set
> at install time it is written to `~/.config/box-bootstrap/shell.env` at mode
> **0600**, which the block sources. Rotating it is an edit of that file, not a
> reinstall.

### dark-factory

1. `just` from apt.
2. `agent-browser` via `npm install -g`, then its Chromium build
   (`agent-browser install --with-deps`, falling back to plain `install`).
   Needs Node — the component warns and skips this step when `node` is missing.
3. Clones [dark-factory](https://github.com/nickfujita/dark-factory) to
   `~/dark-factory` anonymously over HTTPS (it is a public repo), or
   `git pull --ff-only`s an existing checkout.
4. Runs the checkout's `scripts/sync-to-global.sh` to populate
   `~/.claude/skills` and `~/.codex/skills`.

### notifications

Installs four scripts into `~/.local/bin` (**no sudo**, unlike the reference
VM's `/usr/local/bin`): `notify-moshi.sh`, `notify-claude.sh`,
`notify-claude-attention.sh`, and `notify-codex.sh`. The Claude wrappers log
every event to `~/.notify-claude.log`, the attention wrapper rate-limits itself
to one push per 60 s, and all of them honour the `~/.notifications-off` toggle
(`notify-on` / `notify-off` / `notify-status` come from the `--shell` block).

> **The webhook credential lives outside the scripts.** `MOSHI_WEBHOOK_URL` and
> `MOSHI_WEBHOOK_TOKEN` are written to `~/.config/moshi/webhook.env` at mode
> **0600**, which `notify-moshi.sh` sources **at runtime** — so rotating the
> token is an edit of that file, never a reinstall. An existing `webhook.env` is
> left untouched. With no webhook configured the scripts exit silently rather
> than failing inside an agent hook.

> **Codex `notify` is left alone.** `notify-codex.sh` is installed, but
> `~/.codex/config.toml`'s `notify` key is not touched: on a bridge-equipped box
> the Matrix bridge owns that key and fans out to this script itself. Pointing
> `notify` straight here would replace the bridge handler and silently break
> phone routing.

### global-instructions

Renders two vendored templates:

- [`dotfiles/claude/CLAUDE.md.template`](dotfiles/claude/CLAUDE.md.template) →
  `~/.claude/CLAUDE.md`: the Claude-Code-specific harness notes plus the
  `@~/.codex/AGENTS.md` import.
- [`dotfiles/codex/AGENTS.md.template`](dotfiles/codex/AGENTS.md.template) →
  `~/.codex/AGENTS.md`: the **portable core only** — Git Workflow, File Links,
  Python, Testing, Live Agent CLI Tests and Phone Bridge, Mobile and TTS Final
  Messages, Safety, and the multi-agent workflow block from
  [`dotfiles/codex/instructions/shared.md`](dotfiles/codex/instructions/shared.md)
  (its sync markers are preserved so the reconciliation skill can still find the
  managed region).

`{{GOGRIP_BASE_URL}}` in the File Links section is rendered from
`$GOGRIP_BASE_URL`, or assembled as
`http://$BOX_NAME.$PERSONAL_TAILNET:6419` when that is not set.

> Machine-specific context — home infrastructure, per-project dogfooding
> runbooks, credential locations — is deliberately **not** in the template. Keep
> it in a file under `~/.codex/references/` instead. Neither file is ever
> overwritten without a timestamped `.pre-box-bootstrap-<ts>` backup.

## Operator-side prerequisites (personal tailnet admin console)

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
service enables are skipped when already active.

Note that `./install.sh --check` with no component named probes the **core
four**; add `--agents` (or the individual flags) to probe the agent-environment
components too.

Files the agent-environment components own — the vendored Codex agents and
skill, the `~/.bashrc` block, the notify scripts, `CLAUDE.md`, and `AGENTS.md` —
deliberately **converge** to the repository copy so every box stays consistent,
and a differing pre-existing file is always preserved as
`<name>.pre-box-bootstrap-<timestamp>` first. Files another system owns are
never converged: `~/.codex/config.toml` is only ever added to,
`~/.claude/settings.json` is deep-merged, and `~/.config/moshi/webhook.env` and
`~/.config/box-bootstrap/shell.env` are written once and then left alone so a
rotated credential survives a re-run. The Neovim config follows the same
converge rule as the vendored agent files.

## Repo layout

```
install.sh                              # the idempotent installer
dotfiles/nvim/                          # captured LazyVim configuration + lock
dotfiles/claude/settings.template.json  # ~/.claude/settings.json template
dotfiles/claude/CLAUDE.md.template      # ~/.claude/CLAUDE.md template
dotfiles/codex/AGENTS.md.template       # ~/.codex/AGENTS.md template (portable core)
dotfiles/codex/config.portable.toml     # additively merged into ~/.codex/config.toml
dotfiles/codex/agents/*.toml            # custom Codex agents
dotfiles/codex/instructions/shared.md   # multi-agent workflow block (sync markers)
dotfiles/shell/bashrc-block.sh          # the marker-guarded ~/.bashrc block
scripts/install-neovim.sh               # standalone full editor installer
scripts/bootstrap-nvim.lua              # headless Mason/Tree-sitter installer
scripts/capture-neovim.sh               # refresh the captured config
scripts/merge-codex-config.sh           # additive-only TOML merge (+ --check)
scripts/notify/notify-*.sh              # push hooks installed to ~/.local/bin
units/tailscaled-personal.service       # personal tailscaled (system unit)
units/gogrip.service                    # go-grip preview (user unit)
examples/bootstrap.env.example          # runtime env template (no real secrets)
examples/tmux.conf.local.example        # personal tmux overrides
```
