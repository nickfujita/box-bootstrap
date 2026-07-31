<!-- home-server:codex-orchestration:start -->
## Multi-agent development workflow

### Role distinction

These rules distinguish between the root agent and implementation workers.

- The root/default thread is the Sol xhigh orchestrator.
- An agent whose custom developer instructions identify it as an
  implementation worker is allowed and expected to edit code.
- The root should not perform implementation edits itself unless the user
  explicitly asks it to do so or delegation is unavailable.

### Root orchestrator responsibilities

The root agent must:

1. Understand the request and inspect only enough code to create a sound plan.
2. Produce a task plan with bounded assignments and acceptance criteria.
3. Delegate implementation work to named custom agents.
4. Prefer non-overlapping assignments when workers operate concurrently.
5. Wait for all relevant workers before making final conclusions.
6. Review worker results against the original plan.
7. Send corrections back to a worker rather than silently implementing them
   in the root thread.
8. Produce the final integrated summary.

### Agent selection

Delegate to the named agents in `~/.codex/agents/`. The static agent files
are the source of truth for model and reasoning effort, because per-spawn
routing fields are hidden from the model by default when the parent is Sol.

- Use `luna_worker` (Luna, xhigh) as the default for bounded implementation
  where the brief is complete and the target files are named. It matches
  Sol-low quality on such work at roughly a quarter of the cost.
- Use `sol_low` (Sol, low) for implementation that must discover its own
  context: repo-wide refactors, large diffs, or work spanning many files.
  Luna's long-context recall drops sharply, so route these to Sol regardless
  of task size.
- Use `sol_medium` (Sol medium) for debugging, architectural judgment, or
  changes spanning several interacting code paths.
- Use `sol_high` (Sol high) for unusually difficult or high-consequence work:
  credential, auth, or security boundaries; concurrency; migrations; protocol
  compatibility; cross-layer invariants; or escalation after a plausible
  medium-effort failure.
- Refer to the exact custom-agent name when delegating.
- Do not use a generic unnamed child when a configured agent matches the task.
- Do not use Terra unless the user explicitly requests an experiment.
- Reserve dynamic per-spawn model, effort, or service-tier overrides for
  explicit experiments; normal work uses the pinned named-agent definitions.
- Leave the fast service tier off for delegated work: it roughly doubles cost
  for about 1.5x throughput, and subagent tier resolution is currently
  unreliable.
- Skills and subagent workflows may sequence named agents, but they do not
  replace or override the pinned agent definitions.

### Parallelism

Parallelize read-heavy investigation and independent implementation tasks.
Avoid giving multiple write-capable agents overlapping file ownership, and
strictly serialize implementers that share a worktree: dispatch the next writer
only after the previous writer has exited and the intended tree state has been
verified. Follow any additional delegated-work verification rules in the
applicable project guidance.

Before spawning agents, provide an assignment table with one row per agent and
these columns:

- agent name
- assigned task
- permitted file or subsystem scope
- acceptance criteria
- dependencies on other assignments

Spawn named custom agents with bounded task context rather than a full-history
fork. A full-history fork inherits the parent's agent type and Codex rejects an
attempt to combine it with a different custom-agent name.
<!-- home-server:codex-orchestration:end -->
