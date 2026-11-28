# teebox

Wrapper running an AI coding agent (claude, codex, gemini, ...; one per image)
in permission-bypass mode inside a Docker/Podman container whose **only rw view
of the host is `$PWD`**, mounted at its real host path. `README.md` is the
source of truth for behaviour.

## Files

- `teebox` — bash wrapper: flags + TOML config, mounts, content-hash image tag, engine command.
- `config/defaults.toml` — every setting's default + built-in `[agents.*]`; the key reference.
- `completions/teebox.bash`, `completions/_teebox` — bash / native zsh completion. Both
  parse flags from `teebox --help` (usage line `  [-x, ]--key[ VAL|[=VAL]]  desc`,
  `(list)` in desc = repeatable: the format they rely on), topics from
  `teebox --topics`, agents from `[agents.NAME]` headers. Behaviour change -> both.
- `install.sh` — symlinks `teebox` + login shell's completion; never edits rc files.
- `Dockerfile` — debian-slim + node 22 + docker CLI + Go/C++/Conan + one agent
  (build-arg `AGENT_PKG`), non-root `agent` user. Build context holds only `ca/` (the
  optional host CA).
- `entrypoint.sh` (`sh`, bind-mounted ro) — home overlays, per-agent trust,
  topic-session args, then sources `./.teebox/init.sh`.
- `config/home-example/` - recommended agent files, `$HOME` layout (incl. in-box
  memory file `.claude/CLAUDE.md`); the user copies them into the overlay. teebox never writes
  agent config itself (only args/env).

## Invariants

- **Image tag = content hash** of `Dockerfile` + Go version + host
  `NODE_EXTRA_CA_CERTS` file + agent `package` (+ `version` when pinned) (+ uid/gid
  under docker). A new build input MUST join `BUILD_HASH`. Go version = config,
  else `GOTOOLCHAIN=local go env GOVERSION` run from `/` (no go.mod may trigger
  a download), else `latest`.
- **A normal run: no network, no state outside the mounts.** Round-trips and
  cache files belong in the `need_build` branch. `latest` is resolved there
  (unchanged release = layer cache hit), hence never in `BUILD_HASH`. No
  timestamp cache-bust (caused the tag pileup). Sole host write: a run with a
  TOPIC appends `workspace<TAB>topic` to `$XDG_STATE_HOME/teebox/topics.tsv`
  (not under `--dry-run`); `--topics` reads it.
- **Dockerfile order is cache-tuned:** apt -> CA -> node -> docker CLI ->
  C++/conan -> Go -> agent -> user. Agent bumps invalidate one layer and agents
  share everything above; a uid change rebuilds almost nothing.
- **Config is never baked.** Only `go-version` and the agent's `package`/`version`
  reach the build; `entrypoint.sh` is bind-mounted, never baked.
- **`/home/agent` is ONE named volume**: agent state + every toolchain cache. No
  per-cache volumes. An existing volume shadows image content, so anything that
  must land in `$HOME` goes through `apply_home`, never the Dockerfile.
- **Private volume only for a project root** (`./.teebox/` at the workspace,
  adopted from any subdir). Default `volume = "teebox-{dir}"`; `{dir}` = project
  root dirname, else `home` -> shared `teebox-home`. Reason: the project overlay
  copy is additive and would leak into every box forever. Duplicate caches are
  the accepted cost; same-named projects share a volume (user's choice; `{hash}`
  separates them). `volume = ""` = `teebox-home`, or
  `teebox-home-{dir}-{hash}` with a project root. Host-side only.
- **Host paths = XDG base dirs** (also macOS): config `$XDG_CONFIG_HOME/teebox/`,
  state `$XDG_STATE_HOME/teebox/`; unset/relative = `~/.config`, `~/.local/state`.
  No `~/.teebox/` (collides with the project marker), no `/etc`.
- **Host overlay** `<config dir>/home/` (`home = ""`) mirrors `/home/agent`: bound ro at
  `/host-home`, copied when the volume lacks `~/.teebox-seeded` or on `--seed`.
  Project tier `./.teebox/home/` applies every start and wins.
- **Settings = flags = config keys.** One table of keys in the wrapper
  (`VALUE_KEYS` / `LIST_KEYS` / `SWITCH_KEYS`, `CLI_ONLY` for per-run flags);
  config `<config dir>/config.toml` deep-merges over `config/defaults.toml`, then
  flags override (lists append). A new setting: add it to the key table,
  `config/defaults.toml`, usage, README. Unknown keys die. No `TEEBOX_*` on the host side.
- **Config is data, never code.** Host deps: bash 4.4+, jq + either yq flavor
  (mikefarah `yq -p toml`, or python yq's `tomlq`), used only for TOML -> JSON;
  jq merges and flattens. One such pipeline per run; keep it one.
- **Agents = `[agents.NAME]` tables.** Only `package` (+ `version`) is a build
  input; `args`, flags, env, session args are runtime. Agent-specific entrypoint logic
  keys on `TEEBOX_AGENT`. New built-in: table in `config/defaults.toml` + README rows +
  optional files under `config/home-example/`.
- **Wrapper -> entrypoint = entrypoint options before `--`** (`--seed`, `--new`,
  `--alias`, `--session`), never env. In-box `TEEBOX_*` = only the two
  documented below.
- **Topic sessions are data-driven:** wrapper expands `session-*`
  placeholders and passes newline-separated args; the entrypoint picks RESUME
  when the `$HOME`-relative FOUND glob matches, else NEW. Session id = uuid from
  sha256 of `$HOST_PWD` + TOPIC; keep stable (existing sessions key on it).
- **Host env is never a setting.** Sanctioned reads: `pass-env` forwarding,
  `NODE_EXTRA_CA_CERTS` (CA), `DOCKER_HOST`/`SSH_AUTH_SOCK` when a socket
  setting is `true`, `XDG_CONFIG_HOME`/`XDG_STATE_HOME` (file locations).
- **Never source anything from the workspace on the host.** Project behaviour
  is selected by *presence* of `./.teebox/`. `./.teebox/init.sh` runs only in
  the box (entrypoint, last before `exec`); the wrapper never reads it.
- **Ownership heal is conditional** (top of `$HOME` owned by another uid).
  Unconditional = `chown -R` of a multi-GB cache every start.
- **Container name** = `name` setting (default `{topic}`; renders empty -> `teebox-<random6>`). With a placeholder
  (`{dir}` `{topic}` `{hash}`) it is a template probed `_2.._99` while taken; without, verbatim, no probe. Probe
  skipped under `--dry-run`.
- **Workspace at its real host path** (nested `docker -v "$(pwd)/x"`, absolute symlinks).
- **Two engines** (docker / rootless podman) differ in uid mapping, sockets,
  device groups: every host-integration change covers both.
- **Host sockets are opt-in** (`false` default, `true` inherits host, or a
  path); not a live socket = die before the build (`ssh-agent`: warn, run
  without it). Never autodetect on. Socket
  gid via `--group-add` under docker only (host gids invalid in podman userns).
- **Host env crosses by name only** (`-e KEY` after `export`): values never in
  engine argv or `--dry-run`. Values come from the `HOST_ENV` snapshot taken at
  start, never from wrapper variables; the export is the last step before
  `exec`. GO* `pass-env` names resolve in the single `go env` call.
  Defaults exclude host paths, binaries, locales, `localhost` URLs.
- **Host `/dev` is never mounted**, and devices add nothing to the run unless
  `device` is set (`/dev/...` path or bare name; never resolved against `$PWD`).
  Start-time snapshot only, `--device real:name` with the exact major:minor. No
  hotplug: it needed a privileged host-side `exec` of box-controlled binaries.
  Never bind `/dev` (host ptys, `/dev/shm`, all user devices under podman).
- **No secrets in image layers** (`docker history`). The CA is public; nothing
  else is COPYed.

## Two agents — don't confuse them

- **Repo-claude** (edits this repo) reads this file.
- **In-box agent** (inside a box) does NOT; its brief is the host overlay's
  memory file (`home/.claude/CLAUDE.md`, `home/.codex/AGENTS.md`; template
  `config/home-example/.claude/CLAUDE.md`). In-box env that brief relies on, keep stable:
  - `NODE_EXTRA_CA_CERTS` — path of the extra CA file (empty if none).
  - `TEEBOX_AGENT` — running agent. `TEEBOX_TOPIC` — TOPIC arg (unset if none).
  - `host.docker.internal` -> host (docker: wrapper `--add-host`; podman: built in).

## Verify

```
bash -n teebox && sh -n entrypoint.sh && bash -n install.sh completions/teebox.bash && zsh -n completions/_teebox
./install.sh --dry-run
./teebox --dry-run
./teebox --engine podman --dry-run
./teebox -a codex --dry-run TOPIC
./teebox --build --shell -- 'true'    # full build + run
```
