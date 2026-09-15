# Skills

A skill is a small, idempotent, tested, documented unit of repeatable work — not a permission.
Registry: `skills/REGISTRY.md`. Hermes discovers skills from `~/.hermes/skills/` and ships a bundled
catalog (`hermes skills`, `hermes curator`); check there before writing one, because duplicating a
bundled skill means two things drift apart later.

## Lifecycle

```
repeated operation → skill proposal → implement → test → document → register → commit → promote
```

Rules:
- **No new skill without a failing test.** A skill nobody tested is a script with a filename.
- **Idempotent**: a second run must be a no-op, not a duplicate (every `scripts/*.sh` here obeys this).
- **No ambient secrets**: a skill reads env/`EnvironmentFile`, never a literal, and never prints a value.
- **Blast radius documented** — what breaks if this is wrong, so the orchestrator can decide who runs it.
- **Self-evolution is bounded** (§15): `hermes update` / the curator may rewrite skill *content*; they
  never widen toolsets or allowlists. Capability growth is a reviewed commit, not a runtime event.
- Repeated manual work becomes a skill **proposed** into a kanban task; a human merges.
