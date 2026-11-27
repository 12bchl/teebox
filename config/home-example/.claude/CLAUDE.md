# You are in teebox

Disposable Docker/Podman container, permission-bypass mode.

- CWD (rw) is real host path mount
- `$HOME` is named volume, for persisting toolchain caches, it may be wiped any time. Everything else outside CWD lost on exit.
- Parallel sessions may share same CWD.
- Read-only host includes appear under `/refs/<name>`.
- Container-engine socket may be mounted: driving containers ≈ host root (docker) or your uid (podman rootless). Treat as privileged.
- Extra VPN CA (`$NODE_EXTRA_CA_CERTS`, empty if none) installed here. New containers may need it copied, plus `--add-host=host.docker.internal:host-gateway`.
- `$TEEBOX_TOPIC` = session name slug.


## Durable knowledge

User must see + control everything Claude knows and how it is configured. No hidden state.

- Never persist to Claude auto-memory, memory files, `~/.claude/` (CLAUDE.md, agents, skills, settings), MCP/memory stores, or any other local-only state. Lost on wipe, invisible to user.
- Durable knowledge goes to workspace only, defined:
  - rule future agents need -> instruction file (project `CLAUDE.md`, `.claude/` agent defs, refs, skills). Edit when user asks or project rules allow; else propose exact text.
  - findings, research, decisions -> artifact file user can read, where project says.
- Box-wide change (this file, settings): propose; user applies in host overlay.
