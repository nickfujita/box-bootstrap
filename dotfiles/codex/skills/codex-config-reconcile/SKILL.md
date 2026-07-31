---
name: codex-config-reconcile
description: Interactively compare and reconcile a machine's personal Codex instructions, portable config, custom agents, and personal skills with a versioned baseline checkout. Use when setting up a new machine, synchronizing dev environments, checking Codex configuration drift, promoting useful machine-local setup back to the baseline, or propagating approved changes to your other machines.
---

# Reconcile Codex Configuration

Keep judgment and approval in the conversation. The inventory command is
read-only; never turn it into an automatic synchronization command.

## Locate the baseline

Prefer a clean checkout of the baseline repository on its default branch, at
`${CODEX_BASELINE_ROOT}` when that is set. If no checkout is available, use the
installed snapshot at `${CODEX_HOME:-$HOME/.codex}/reconcile-baseline`, but
disable the machine-to-repo pass because a snapshot is not a Git source of
truth.

Use `scripts/codex-config-inventory` from the baseline repository when present.
Otherwise use `codex-config-inventory` from `PATH`.

## Hard boundaries

- Never replace the complete global `AGENTS.md` or `config.toml`.
- Never read, diff, copy, or commit authentication, credentials, session
  state, memories, histories, caches, plugin caches, hook hashes, or trusted
  project entries.
- Never delete unknown agents or skills.
- Treat ambiguous content as local-only.
- Back up every live file before an approved edit.
- Ask before every conflict or deletion.
- Ask once for an explicitly listed, low-risk group of additive changes.
- Show the final repository diff and ask separately before committing and
  before pushing the default branch.
- If remote Git operations fail, stop after the local commit and give the user
  the exact command to run.

## Pass 1: baseline to machine

1. Confirm the hostname, target Codex home, baseline path, and repository Git
   state.
2. Create a fresh report path with `mktemp -d`.
3. Run:

   ```bash
   codex-config-inventory \
     --baseline-root <baseline-checkout-or-installed-snapshot> \
     --codex-home "${CODEX_HOME:-$HOME/.codex}" \
     --host "$(hostname -s)" \
     --output <fresh-report-path>
   ```

4. Read every report file. Inspect source files directly only when a report is
   ambiguous.
5. Classify each difference as:
   - apply shared baseline to machine;
   - apply host overlay to machine;
   - retain local-only;
   - promote machine state to shared baseline;
   - promote machine state to host overlay;
   - obsolete; or
   - sensitive/unrelated.
6. Present recommendations with exact source, target, risk, and proposed
   action. Wait for approval.
7. Back up approved targets under
   `${CODEX_HOME:-$HOME/.codex}/backups/reconcile-<UTC timestamp>/`.
8. Apply only approved targeted patches. Managed instruction markers delimit
   the portable section; preserve all surrounding content.
9. Rerun the inventory into a new report directory and show the remaining
   differences.

For `config.toml`, modify only keys listed in the baseline `manifest.yaml`.
Translate legacy `agents.max_threads` to
`agents.max_concurrent_threads_per_session` only after approval. Validate
`agents.max_depth` against the installed Codex version; do not silently remove
the single-generation constraint if the key is unsupported.

Never touch config sections a managed provisioning system owns —
`shell_environment_policy`, `hooks.state`, `projects`, and `marketplaces` are
written by the box provider and must survive reconciliation untouched.

## Pass 2: machine to baseline

Run this pass only with a real baseline repository checkout.

1. Review live-only instructions, differences in managed agents, portable
   config candidates, unmanaged key names, and skill provenance.
2. Exclude `.system`, plugin, marketplace, cached, generated, ambiguous, and
   credential-bearing skills.
3. Read the complete source of a candidate personal skill before recommending
   promotion.
4. Recommend shared, host-specific, or local-only placement and explain the
   propagation impact.
5. Wait for approval, then patch only approved repository files.
6. Run the repository tests and the inventory again.
7. Show `git diff`, confirm only intended files changed, and ask before a local
   commit to the default branch.
8. Ask separately before pushing. Never force-push, reset, clean, rebase, or
   delete branches.

## Finish

Report:

- approved changes applied to the machine;
- approved changes applied to the baseline repository;
- rejected or deferred recommendations;
- backup paths;
- validation results;
- local commit status and any manual remote command; and
- which machine should run the skill next.
