# teebox

Run an AI coding agent (`claude`, `codex`, `gemini`, `copilot`, `opencode`, `pi`,
or your own) in permission-bypass ("god") mode inside a Docker/Podman container
whose **only read-write view of the host is the current directory**. Everything
else on the host is invisible unless added read-only.

```
~/src/teebox/install.sh                 # symlinks teebox + completion
cd ~/some/project
teebox                                  # claude (default agent)
teebox -a codex                         # codex instead
teebox -- -p "explain"                  # args after -- go to the agent
```

`install.sh` links `teebox` into the first of `$XDG_BIN_HOME`, `~/.local/bin`,
`~/bin` on `PATH` (else `~/.local/bin`), plus tab completion (flags, agents,
and the [topics](#topic-sessions) used in this workspace) for your login shell
(`$SHELL`; `--shell bash|zsh` to choose):

| Shell | Link | Needs |
|---|---|---|
| bash | `teebox` in bash-completion's user dir (`$BASH_COMPLETION_USER_DIR/completions`, else `~/.local/share/bash-completion/completions`) | bash-completion 2.8+; else `source completions/teebox.bash` in `~/.bashrc` |
| zsh | `_teebox` in a user dir on `$fpath` (`.zsh_functions`, `.zfunc`, `zsh/site-functions`, ... under `$HOME`; never a framework's), else `~/.local/share/zsh/site-functions` | that dir on `fpath` before `compinit` |

It only creates or replaces symlinks, never edits rc files (prints the line to
add instead), and `--uninstall` removes its links. `--dry-run` shows the plan.

Host: Linux, bash 4.4+, jq, and a TOML reader: [mikefarah/yq](https://github.com/mikefarah/yq)
v4.40+ (brew, release binary; Ubuntu's apt build 4.30 can't read TOML) or python
yq's `tomlq` (Debian `apt install yq`).

## Usage

```
teebox [OPTIONS] [TOPIC] [-- AGENT_ARGS...]
```

Every setting is both a flag and a key in the [config](#config) file
`~/.config/teebox/config.toml` (same name). Value flags: `--key VAL` or
`--key=VAL`. List flags repeat and add to the config list. Switches: `--key` or `--key=false`.

| Setting | Effect |
|---|---|
| `-a, --agent NAME` | agent to run (default `claude`); see [agents](#agents) |
| `--engine NAME` | `docker` or `podman` (default: autodetect, docker first) |
| `--image NAME` | image base name (`teebox`) |
| `--name NAME` | container name (default `{topic}`); see [names](#names) |
| `--volume NAME` | home volume (default `teebox-{dir}`); see [home volume](#home-volume) |
| `--home DIR` | host home overlay (default: `home/` in the [config dir](#config)) |
| `--go-version VER` | Go baked into the image (default: host `go env GOVERSION`, else latest) |
| `--ro PATH` | read-only include at `/refs/<basename>` (list) |
| `-e, --env KEY=VAL` | env var in the box (list) |
| `--pass-env NAME` | host env var forwarded by name (list) |
| `--pass-env-add NAME` | like `pass-env`; in the config appends to it instead of replacing (list) |
| `--add-host NAME:ADDR` | extra `/etc/hosts` entry (list) |
| `--device DEV` | host device, see [devices](#devices) (list) |
| `--docker-host[=URL]` | engine socket, see [host sockets](#host-sockets) |
| `--ssh-agent[=PATH]` | ssh-agent socket, see [host sockets](#host-sockets) |

Per run only:

| Flag | Effect |
|---|---|
| `-d, --dir DIR` | workspace = DIR instead of `$PWD`, no [root search](#project-root); relative paths resolve against it |
| `-n, --new` | delete `TOPIC`'s existing session first, see [topic sessions](#topic-sessions) |
| `--shell` | bash instead of the agent (`-- 'cmd'` = one `bash -c`) |
| `--seed` | re-apply the host home overlay over the home volume |
| `--build` | rebuild the image (refreshes a `latest` agent) |
| `--allow-home` | allow `$PWD` = `$HOME`, an ancestor of it, or a system root |
| `--dry-run` | print the engine command and the config file read, then exit (no build) |
| `--topics` | list the TOPICs used in this workspace, then exit (feeds tab completion) |
| `TOPIC` | at most one: exported as `TEEBOX_TOPIC`, names the [session](#topic-sessions) |

## Agents

One agent per image: its npm package is the last heavy layer, so images for
different agents share all layers above it. All agents share the home volume,
each in its own dotdir. Packages and agent args: `config/defaults.toml`.

| Agent | Auth forwarded | [Topic session](#topic-sessions) |
|---|---|---|
| `claude` | `CLAUDE_CODE_OAUTH_TOKEN` `ANTHROPIC_API_KEY` `ANTHROPIC_AUTH_TOKEN` `ANTHROPIC_BASE_URL` | `--session-id` new, `--resume` once `~/.claude/projects/*/<id>.jsonl` exists; named `TOPIC` |
| `codex` | `OPENAI_API_KEY` `OPENAI_BASE_URL` | none: codex can't start a session with a chosen id; `TEEBOX_TOPIC` only |
| `gemini` | `GEMINI_API_KEY` `GOOGLE_API_KEY` | `--session-id` new, `--resume` once `~/.gemini/tmp/*/chats/session-*-<id8>.json` exists |
| `copilot` | `COPILOT_GITHUB_TOKEN` `GH_TOKEN` `GITHUB_TOKEN` | `--session-id` (create-or-resume) |
| `opencode` | Anthropic, OpenAI, OpenRouter, Gemini/Google, Groq keys | `--session ses_<hex>` (create-or-resume) |
| `pi` | Anthropic, OpenAI, OpenRouter, Gemini, xAI, Groq keys | `--session-id` (create-or-resume) |

teebox never edits an agent's own config. It sets only what a config file
can't: session args, auth `pass-env`, the agent's `args` (gemini/copilot
`--yolo`, CLI-only; a `.bashrc` alias keeps them on a bare command in
`--shell`), claude `CLAUDE_CODE_SANDBOXED=1` (trusts every workspace; process
env only) and `CLAUDE_PROJECT_DIR` (= workspace). God mode and first-run
prompts are settled in the [overlay](#box-home); `config/home-example/` holds
recommended files, laid out like `$HOME`:

```sh
cp -rn config/home-example/. ~/.config/teebox/home/   # -n: keep files you already have
```

| File | Sets |
|---|---|
| `home/.claude/settings.json` | bypass permissions + no disclaimer, no auto-memory, surveys, tips, updater, nonessential traffic |
| `home/.claude/CLAUDE.md` | box memory file: tells the agent what the box is and where durable knowledge goes |
| `home/.codex/config.toml` | approvals `never` + `danger-full-access`, no update check, analytics, full-access warning |
| `home/.gemini/settings.json` | folder trust off, no auto-update, usage stats, tips |

Without these files claude and codex ask for permission. Still shown once per
fresh volume, then saved in it: claude's theme picker and its "make auto mode
your default" prompt (answer "No, keep bypass permissions"). Codex has no
global trust switch: it asks once per project. For an existing volume `--seed`
copies the whole overlay over it.

**Custom agent / override:** built-ins are `[agents.NAME]` tables in
`config/defaults.toml` (which documents the keys and placeholders); a table in your
config is merged over them key by key.

```toml
# ~/.config/teebox/config.toml
[agents.qwen]
package = "@qwen-code/qwen-code"
args = ["--yolo"]
pass-env = ["DASHSCOPE_API_KEY"]

[agents.codex]
version = "0.169.1"
```

### Topic sessions

`TOPIC` maps to a fixed session id (uuid from sha256 of workspace path + TOPIC),
so `teebox PROJ-123_x` twice = same conversation. Skipped with `--shell`, or
when the agent args already pick a session (`-c`, `--continue`, `--resume`,
`--session`, `--session-id`, ...). Claude and gemini write no transcript until
the first message, so an empty start is created again next time.

Every run with a `TOPIC` (not `--dry-run`) appends `workspace<TAB>topic` to
`~/.local/state/teebox/topics.tsv` unless already there; `--topics` and tab
completion list the workspace's entries. Delete lines (or the file) to forget
topics; sessions are untouched.

`-n`/`--new` starts the topic over: the entrypoint deletes whatever the agent's
`session-found` glob matches, then starts it as new (same id). Without an
existing session it changes nothing. Needs a `TOPIC` and an agent with both
`session-new` and `session-found` (claude, gemini); dies otherwise, as
create-or-resume agents can't be cleared.

### Project init

`./.teebox/init.sh`, if present, is sourced (POSIX `sh`, `set -e`) by the
entrypoint **inside the box** right before the agent starts; its exports reach
the agent. It never runs on the host. Typical use: derive vars from the topic.

```sh
case "$TEEBOX_TOPIC" in
    PROJ-[0-9]*_*) TICKET=${TEEBOX_TOPIC%%_*} TOPIC=${TEEBOX_TOPIC#*_} ;;
    *)             TICKET=PROJ-0         TOPIC=$TEEBOX_TOPIC ;;
esac
export TICKET TOPIC
```

Having `./.teebox/` also gives the project a [private home volume](#home-volume).

### Project root

Without `--dir`, when `$PWD` has no `./.teebox/`, teebox walks up the physical
path and uses the nearest ancestor that has one as the workspace: mount, volume,
container name, session ids, init all as if started there. Run from
`<project>/src/x`, it opens `<project>`. Relative `--ro` paths still resolve
against the directory you ran from. Ancestors that would be refused (`$HOME`,
its ancestors, system roots) are not adopted unless `--allow-home`.
`--dir .` stays in `$PWD`.

## Isolation

- `$PWD` is the only rw mount, at its real host path (`pwd` in box = host path,
  absolute symlinks inside it resolve, nested `docker -v "$(pwd)/x"` works).
  Files keep your uid/gid.
- `--ro PATH` -> `/refs/<basename>`, read-only.
- Nothing else from the host is mounted. Symlinks pointing outside `$PWD`
  dangle; bring targets in with `--ro`.
- Refuses to run when the workspace is `$HOME`, an ancestor of it, or a system
  root (`/`, `/etc`, `/usr`, ...) unless `--allow-home`.

## Auth and host env

Host agent state (`~/.claude`, `~/.codex`, ...) is never mounted. Auth comes
from the selected agent's env vars (table above), forwarded **by name** (`-e KEY`)
when set and non-empty, so values never appear in the engine argv, `ps`, or
`--dry-run`. Alternatively log in inside the box once; it persists in the home
volume.

Also forwarded: `TERM` `COLORTERM` `TERM_PROGRAM` `TERM_PROGRAM_VERSION`
`NO_COLOR`, `TZ` (from `/etc/localtime` when unset), and `GOPRIVATE`
`GONOPROXY` `GONOSUMDB` `GOINSECURE` (via host `go env`, so `go env -w`
counts). Never forwarded by default: host paths, binaries, locales, `localhost`
URLs (`PATH`, `HOME`, `XDG_*`, `GOPATH`, `GOPROXY`, `HTTP(S)_PROXY`, `LANG`, ...).
`pass-env` in the config replaces the default list; `pass-env-add` in the config
and `--pass-env NAME` add to it.

## Host sockets

Off by default. Each is `false`, `true` (inherit the host's), or an explicit
path. Anything that isn't a live socket fails the run before any build, except
`ssh-agent`: warns and runs without it.

```toml
docker-host = true   # $DOCKER_HOST, else /var/run/docker.sock (podman: $XDG_RUNTIME_DIR/podman/podman.sock)
ssh-agent = true     # $SSH_AUTH_SOCK
```

- **Engine socket:** mounted at its host path, `DOCKER_HOST` set in the box.
  Picks which engine the *agent* drives, independent of `--engine`. Rootful
  `docker.sock` is effectively host root: it bounds accidental damage, not a
  deliberate escape. Rootless podman carries only your privileges (podman setup:
  `apt install podman podman-docker passt`, `systemctl --user enable --now podman.socket`).
  Nested `-v SRC:...` sources are resolved by the host engine; workspace paths
  match, so `$(pwd)/x` works.
- **ssh-agent:** mounted at `/run/ssh-agent.sock`. The box can ask the agent to
  sign, never read keys; it can do so silently while running, so load sensitive
  keys with `ssh-add -c`. First contact with an ssh host needs `known_hosts`:
  ship `home/.ssh/known_hosts` in the overlay.

## TLS-intercepting proxies

The host's `NODE_EXTRA_CA_CERTS` (a PEM file with just the extra CA certs, e.g.
Cloudflare WARP / Zscaler) is copied into the build and installed with
`update-ca-certificates`; rotating it rebuilds. In the box,
`NODE_EXTRA_CA_CERTS` points at that same file (empty without one), handy for
copying into sibling containers; `REQUESTS_CA_BUNDLE` covers python requests,
everything else uses the system store.

```
openssl s_client -showcerts -connect deb.nodesource.com:443 </dev/null 2>/dev/null \
  | awk '/BEGIN CERT/,/END CERT/' | csplit -z -f cert- -b '%02d.pem' - '/BEGIN CERT/' '{*}'
# the self-signed one (subject == issuer) is the interceptor
```

## Box home

`/home/agent` is **one named volume**: every agent's state, logins, history,
plugins, and every toolchain cache (Go modules, Conan, npm, ...). Anything a tool
caches under `$HOME` persists.

**Overlay.** `~/.config/teebox/home/` mirrors `/home/agent`:

```
~/.config/teebox/home/
  .claude/settings.json   -> ~/.claude/settings.json
  .claude/CLAUDE.md       # box memory file (see config/home-example/)
  .codex/AGENTS.md
  .gitconfig
  .ssh/known_hosts
```

Bound read-only and copied over `$HOME` (modes kept) when the volume is fresh
(no `~/.teebox-seeded`) or on `--seed`; otherwise in-box changes stick. It may
be a symlink (e.g. into dotfiles); symlinks *inside* it are copied as links and
absolute ones dangle. A project's `./.teebox/home/` uses the same shape, applies
every start, and wins.

### Home volume

Default `volume = "teebox-{dir}"`, with `{dir}` = the project root's dirname:

| Workspace | Volume |
|---|---|
| no `.teebox/` here or above | `teebox-home`, shared |
| [project root](#project-root) `.../api/.teebox/` | `teebox-api`, private, from anywhere under `.../api` |

The shared volume is shared state: whatever one box leaves in `$HOME` (agent
logins and settings, shell rc files, binaries on `PATH`) is there for every
other project and agent. **Create a `./.teebox/` (`mkdir .teebox`) to isolate a
project's home volume.** An empty directory is enough.

The project overlay copy is additive (nothing is ever un-set), so a project with
`./.teebox/` gets its own volume rather than leaking settings into every box.
Cost: a separate toolchain cache and separate logins per such project. Projects
with the same dirname share a volume; add `{hash}` to tell them apart, e.g.
`volume = "teebox-{dir}-{hash}"`. `volume = "teebox-home"` is always shared;
`volume = ""` = `teebox-home`, or `teebox-home-{dir}-{hash}` with a project root.
Nothing prunes volumes; `docker volume rm` one to start fresh.

## Image and rebuilds

debian-slim + node 22 + docker CLI (static, no buildx) + Go + build-essential,
cmake, Conan 2 + one agent. amd64 only. Tag: `teebox:<agent>-<uid>-<gid>-<hash>`
(podman: `teebox:<agent>-podman-<hash>`); docker and podman keep separate
images and volumes.

The hash covers the build inputs only: `Dockerfile`, Go version, the CA file,
the agent package (+ version when pinned). `entrypoint.sh` is bind-mounted and
config never reaches the build, so neither rebuilds.

A normal run makes no network calls. Agent versions default to `latest`
(`version` in the agent's table pins it): `--build` resolves it to an exact
version from npm, so no new release = layer cache hit; the old image dangles
and `docker image prune` removes it.

## Devices

Host `/dev` is never mounted, and nothing device-related is added to the run
unless `device` is set: a `/dev/...` path, or a bare name looked up under
`/dev/serial/by-id/`, `/dev/serial/by-path/`, `/dev/`.

A device is a start-time snapshot: the node is passed with its exact
major:minor, under its real name and under the name you gave (so a `by-id` path
works in the box), and its group is added (docker: numeric gid; podman:
`keep-groups`, so you need that group on the host). A device absent at start is
skipped with a warning. No hotplug: after a (re)plug, quit and re-run the box.

## Names

`name` (default `{topic}`) and `volume` take placeholders, each sanitized to
`[a-zA-Z0-9_.-]`: `{dir}` ([project root](#project-root) dirname, else
`home`), `{topic}` (TOPIC), `{hash}` (sha8 of the workspace path). Separators left trailing by an empty `{topic}`
are trimmed: in project `api`, `name = "box_{dir}_{topic}"` gives
`box_api_PROJ-123_x`, or `box_api` with no TOPIC. A `name` that renders empty (default `{topic}`, no
TOPIC) becomes `teebox-<random6>`. A `name` with a placeholder is a template, tried as
is, then `_2` .. `_99` while taken; without one it is verbatim and a clash is
the engine's error.

## Config

Host files follow the XDG base dirs, on macOS too (unset or relative = default):

| Path | Default | Holds |
|---|---|---|
| `$XDG_CONFIG_HOME/teebox/` | `~/.config/teebox/` | `config.toml`, `home/` overlay |
| `$XDG_STATE_HOME/teebox/` | `~/.local/state/teebox/` | `topics.tsv` (topic history) |

No `~/.teebox/`: `.teebox/` marks a [project root](#project-root), so one in
`$HOME` would make `$HOME` a project. No system-wide (`/etc`) config.

`config.toml` is deep-merged over the shipped
`config/defaults.toml`, which documents every key: a key you set
replaces the default, arrays included; an agent table merges key by key.
Unknown keys fail the run. Values starting `~/` expand to `$HOME`. Flags
override config; list flags append. The config never runs code, and nothing is
read from the workspace on the host. Host env is read only for forwarding
(`pass-env`), the CA (`NODE_EXTRA_CA_CERTS`), and sockets set to `true`.
