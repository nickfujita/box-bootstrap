<!-- home-server:codex-orchestration:start -->
## Delegation policy

The multi-agent orchestration doctrine that lived here is retired. Global
instructions no longer make every session an orchestrator. A session does
small tasks itself and delegates only when a Dark Factory playbook it has
explicitly entered says to.

Delegation rules, agent selection, and per-role model policy live in the
dark-factory repo: the df router skill, its playbooks, and
`skills/df/references/model-policy.md`. The named Codex agents (`luna_max`,
`terra_xhigh`, `sol_high`) stay defined in `~/.codex/agents/*.toml`. Those
definitions say what each agent is. The df skills say when to use one.
<!-- home-server:codex-orchestration:end -->
