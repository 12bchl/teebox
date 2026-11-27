# TODO: inner container engine (sysbox) instead of the host engine socket

Status: proposal, nothing implemented. Researched 2026-11. Facts marked
(verify) are from docs only and must be confirmed in the spike before anything ships.

## Problem

With `docker-host` on, the box gets the host engine socket so the agent can run containers. Whoever
holds that socket can start a sibling container with any mount or privilege:

- docker (rootful): `docker run -v /:/host --privileged ...` -> root on host.
- podman rootless: `podman run -v $HOME:/h ...` -> rw on the user's whole home,
  incl. shell rc files (host code exec as the user on next login) and
  `~/.config/teebox/config.toml` (widen the next box: `docker-host`, `ro`).
- either engine: `volume create --opt type=none --opt o=bind --opt device=/x`
  (bind without `-v`), `--network host` (reach localhost-only host services),
  `exec`/`cp`/`inspect` on unrelated containers (secrets in their env).

So the `$PWD`-only fence holds only for an agent that never touches docker.

Second, smaller hole, present even without the socket: the `agent` user has
NOPASSWD sudo, and rootful docker has no userns. Root in the box = host uid 0 on
every rw mount (default caps incl. `CHOWN`, `FSETID`, `MKNOD`). It can drop a
setuid-root binary or a `0666` block-device node into `$PWD`; the next host
process that runs/opens it is root. `--privileged` is never passed, but the box
is "unprivileged" only in the docker-flag sense.

## Threat model ("air-tight")

- In scope: any path from the agent to host root or host user via the
  container runtime, engine API, mounts, devices, or files the agent leaves
  on the host for a host process to run/open. Agent assumed hostile.
- Out of scope: kernel vulnerabilities.
- Must decide explicitly: workspace poisoning. A rw `$PWD` lets the agent
  write `.git/config` (`core.fsmonitor`, `core.sshCommand`, aliases),
  `.git/hooks/*`, `.envrc`, IDE task files, build scripts; host git/IDE/direnv
  then runs them as the host user. No runtime choice closes this. Options:
  mount `.git/hooks` + `.git/config` ro in the box (breaks `git remote add`,
  upstream tracking), or document as accepted and keep host tooling from
  auto-running workspace code.
- Setuid/device plant (any mode where box root writes `$PWD` as host uid 0):
  closed host-side by a `nosuid,nodev` mount of the workspace tree, e.g.
  fstab `/home/u/GIT /home/u/GIT none bind,nosuid,nodev 0 0`. Wrapper can
  check `findmnt -no OPTIONS -T "$HOST_PWD"` and refuse/warn. Cheap, and
  holds regardless of runtime or uid mapping.

## Goal and constraints

- Agent keeps full docker ability: run/build/compose, nested
  `docker -v "$(pwd)/x"`, published ports reachable.
- Nothing the agent does reaches outside `$PWD`, `/refs` (ro), and its own
  volumes. Project will be public -> must hold against a hostile agent, not
  just a careless one.
- Stay simple: no policy engine to maintain per Docker API version.
- Cover both engine branches (docker rootful, podman rootless).

## Proposal

Give each box its own private engine instead of the host's socket. That inner
engine only sees the box's filesystem, so the fence holds by construction.
The mirror mount (`$PWD` at its real host path) means nested
`docker -v "$(pwd)/x"` works unchanged.

### Docker host: sysbox runtime + inner dockerd

Host prerequisite (user installs once): sysbox CE package, rootful docker,
kernel 6.3+ preferred (ID-mapped mounts on all fs; 5.12+ minimum).

Wrapper (`teebox`):
- `run --runtime=sysbox-runc`; drop the `/var/run/docker.sock` mount, its
  `--group-add`, and `DOCKER_HOST`.
- Detect `sysbox-runc` in `docker info` runtimes. Missing -> refuse with
  install hint, unless an explicit opt-out (`--host-engine`, loud warning) is
  given. Default must be the safe mode.
- Inner `/var/lib/docker` = named volume `teebox-docker-<container name>`.
  Sysbox otherwise uses a per-container host dir that `--rm` deletes, so the
  image cache would be cold every run. Keyed by container name because a
  volume may serve only one inner dockerd at a time (`box_proj` vs
  `box_proj_2`). Must NOT live in the home volume: the ownership heal would
  `chown -R` root-owned image layers. -> amend the "one volume" invariant in
  CLAUDE.md to "one home volume + one inner-engine volume".
- Drop `--user`; sysbox gives container root an unprivileged host uid range,
  and the entrypoint drops to `agent` itself.
- `--group-add` with host gids becomes meaningless (outside the userns map).
- `host.docker.internal` stays (sysbox supports `--add-host`) for host
  services. Ports published by inner containers bind inside the box; reach
  them from the host via the box's bridge IP, or have the wrapper publish a
  configured port list on the box.

Image (`Dockerfile`, -> new `BUILD_HASH` input):
- Add `dockerd` + `containerd` (+ `docker-compose` / buildx plugins, which also
  restores BuildKit). Static docker tarball already ships them; keep binaries
  instead of only `docker`.
- Remove NOPASSWD sudo (see hardening below).

Entrypoint (`entrypoint.sh`):
- Starts as box root (= unprivileged on host). Do root-only work (ownership
  heal) without sudo, start `dockerd` in background, wait for
  socket, then `exec setpriv --reuid agent --regid agent --init-groups
  --no-new-privs ... <agent cmd>`. `agent` is in the inner `docker` group.

### Podman host: nested rootless podman

Sysbox does not support podman (issue #128 open since 2020). Instead run
rootless podman inside the box:
- Box run adds `--device /dev/fuse` (fuse-overlayfs) and
  `--security-opt label=disable` (SELinux hosts only; no-op on Debian).
  Rootless-in-rootless needs no extra caps and no `--privileged`.
- Image adds `podman`, `fuse-overlayfs`, `uidmap`; `/etc/subuid` +
  `/etc/subgid` entries for `agent` (nested range inside the outer keep-id
  map; needs the host user's subuid range to be large enough (verify)).
- Entrypoint starts `podman system service` on a user socket and sets
  `DOCKER_HOST` to it, so the in-box `docker` CLI and compose keep working.
- Inner storage (`~/.local/share/containers`) falls under the home volume ->
  already persistent, no new volume. Check the ownership heal never touches
  it with a `chown -R` (subuid-owned files).
- Drop the host podman socket mount.

Isolation is a user namespace only (no `/proc` virtualisation like sysbox);
acceptable because the outer box is already rootless.

### Serial devices

Blocker for sysbox: it does not support `docker run --device` in any release.
Device nodes also show as `nobody:nogroup` inside the userns (host gid
`dialout`=20 is unmapped). A device-manager feature merged to sysbox master
2026-09 (GPU, tun) is unreleased and does not cover serial.

Options, preferred first:
1. Serial sidecar: wrapper starts a small runc (non-sysbox) container that
   gets `--device` and runs `ser2net` (RFC2217), on a private network shared
   with the box. In the box: `socat pty,link=$HOME/dev/<name>,raw
   tcp:<sidecar>:<port>` or pyserial `rfc2217://`. Box never holds a host
   device; baud/modem-line changes go over RFC2217 (verify tool compat,
   esp. flashers that toggle DTR/RTS for reset). Hotplug: sidecar gets
   `/dev` + cgroup rules instead of the box.
   Sidecar hardening: fixed wrapper-chosen command, non-root with only the
   device's group, `--cap-drop ALL`, read-only rootfs, network = box link
   only. Agent reaches it only via the RFC2217 TCP stream. esptool supports
   `rfc2217://` natively.
2. When `device` is set, run that box with plain runc,
   the device, and no engine at all. Still air-tight (plus hardening flags +
   `nosuid,nodev`), but no docker in those sessions.
3. Legacy: runc + device + host socket (today's behaviour). Not air-tight;
   explicit opt-in only.

Podman branch unaffected: devices keep working via `keep-groups`.

### Hardening to do regardless (also fixes the setuid/mknod hole today)

- Remove NOPASSWD sudo from the image; entrypoint does root work before
  dropping privileges (needs entrypoint to start as root: today it runs as
  `--user uid`).
- `--security-opt no-new-privileges` on the box run.
- `--cap-drop ALL` plus only what the entrypoint root phase needs (verify
  list: likely `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`;
  `MKNOD` dropped).
- Under sysbox the inner engine still gives the agent root in the box (see
  open question 1), so these do not replace the uid-mapping check.

## Spike 2026-11-17: rootless dockerd in a plain runc box (no host runtime)

Run on docker 29.10 rootful, kernel 7.1, Debian forky, AppArmor on, with
`docker:dind-rootless` as stand-in for the box. Outer process: host uid 1000,
`CapEff` 0, no `--privileged`.

- Needed, each verified by removal: `--security-opt seccomp=unconfined`
  (userns clone), `--security-opt apparmor=unconfined` (mount propagation),
  `--security-opt systempaths=unconfined` (inner `/proc` mount),
  `--device /dev/net/tun` (slirp4netns).
- `--cap-drop ALL --cap-add SETUID --cap-add SETGID` works (setuid
  `newuidmap`/`newgidmap` need exactly those). `no-new-privileges` breaks
  `newuidmap` ("Could not set caps") -> not usable in this mode.
- Works inside: `docker run`, BuildKit `docker build`, `-p` publish (reachable
  in the box), nested `-v "$PWD/x:$PWD/x"`.
- Inner root writes the workspace as host uid 1000, inner non-root as subuid
  (100999): no host-uid-0 files, a planted setuid binary is setuid-self.
- Nested `-v /etc:/h` shows the box's `/etc`, not the host's.
- Inner `docker run --privileged` fails (sysfs mount EPERM). Rootless without
  systemd = no cgroup limits for inner containers.
- Precondition: nothing in the box may reach uid 0. Unmasked `/proc/sys` is
  writable by init-userns root (`core_pattern` = host root). So: no sudo, strip
  setuid bits except `newuidmap`/`newgidmap`.
- Not tested: rootless podman as outer engine (inner subuid range must fit the
  keep-id map), a seccomp profile tighter than `unconfined`, gVisor.

## Why dind needs --privileged and sysbox does not

dockerd needs to mount (overlayfs, proc, sysfs, cgroupfs), create namespaces,
manage cgroups, set up netns + iptables, write `/proc/sys`. A normal container
blocks all of that (dropped caps, seccomp, AppArmor, ro `/proc/sys` + `/sys`).
`--privileged` lifts every restriction, but container root is host root (no
userns), so the caps are effective against the host: mount host disks, load
modules, etc. `docker:dind-rootless` also needs `--privileged` (per Docker
docs: to disable seccomp, AppArmor, mount masks).

Sysbox puts every container in its own user namespace (root -> unprivileged
host range). Caps are then real but scoped to resources that namespace owns.
`sysbox-fs` (FUSE) virtualises the `/proc` and `/sys` paths dockerd writes,
and seccomp-notify traps `mount`, `umount2`, `chown` etc. to allow only safe
cases. Even `docker run --privileged` inside is privileged only within the box.
Remaining boundary: the kernel's userns code (shared kernel).

## Alternatives considered

- Plain dind: needs `--privileged` -> no boundary. Rejected.
- dind-rootless: still `--privileged`. Rejected.
- Socket-filtering proxy (allowlist parsed request bodies: mounts under
  `$PWD`, no privileged/caps/devices/host namespaces/volume driver opts/
  swarm/plugins, exec only on box-labelled containers): works on both
  engines, keeps host image cache, but is a security policy that must track
  every Docker API version; one missed field = escape. Docker authz plugins
  (e.g. OPA) apply daemon-wide and cannot tell box from user over the unix
  socket. Rejected for maintenance burden.
- Dedicated host user with own rootless engine: shrinks reach (not the
  user's 0700 home) but still sees world-readable files, the network, the
  kernel; needs workspace ACLs and messes up ownership. Rejected.
- gVisor (`runsc`) with dockerd inside: real contender, see next section.
- Kata / Firecracker microVM (`--runtime io.containerd.kata.v2`): hardware
  isolation. Needs KVM, rootful, no podman, devices only via VFIO. Heavy.
- Docker Sandboxes (`sbx`): microVM per agent with private engine and egress
  proxy; a product overlapping teebox itself. Needs KVM, Docker sign-in,
  Ubuntu 24.04+/Rocky packaging. Worth watching, not a building block.
- Docker Desktop ECI: sysbox under the hood; Desktop VM only.

## gVisor vs sysbox (docker branch)

- Mechanism: gVisor = user-space kernel (Sentry) answers the box's syscalls;
  host sees a small seccomp-filtered set; file access via a separate gofer
  process. Sysbox = real kernel + userns, plus root host daemons
  (sysbox-fs, sysbox-mgr) that service trapped syscalls and FUSE reads.
- In-scope escape surface: sysbox's root daemons parse container-controlled
  input -> a bug there = host root, not a kernel bug. gVisor's Sentry is
  itself sandboxed (namespaces + seccomp); escape needs a Sentry bug AND a
  second break. gVisor wins.
- Track record: gVisor = Google, production in GKE Sandbox / Cloud Run,
  frequent releases. Sysbox = community best-effort, ~7-month lag on 2025-11
  runc CVEs. gVisor wins.
- Host install: gVisor = one static `runsc` + `runsc install` (daemon.json
  runtime entry). Sysbox = package with two systemd daemons. gVisor lighter.
- Inner docker: sysbox = native dockerd, bridge networking, `-p` works.
  gVisor = dockerd needs `--iptables=false` (no `-p` publish), tmpfs or
  snapshotter tweaks for `/var/lib/docker`, extra runsc flags for v28+.
  Sysbox wins (verify how compose networking behaves under gVisor).
- Performance: sysbox ~native. gVisor slower on syscall/file-heavy work
  (compiles, `npm install`, `go build`); improved by directfs + systrap but
  measurable. Sysbox wins.
- Compat: sysbox = full kernel. gVisor = most syscalls, gaps (io_uring off,
  some ioctls, /proc). Sysbox wins.
- Devices: neither passes host serial devices (gVisor: only proxied GPU/TPU/
  fuse/tun; verify). Tie -> serial sidecar either way.
- Podman: neither fits rootless podman (runsc refuses rootless create;
  sysbox unsupported). Tie -> nested rootless podman either way.
- uid mapping: both may write `$PWD` as host uid 0 from box root (verify for
  gVisor gofer) -> `nosuid,nodev` host mount check covers both.

Net: gVisor fits the air-tight definition better; sysbox gives the agent a
more capable, faster engine. Spike both behind one wrapper flag
(`--runtime=runsc|sysbox-runc`); the box-side changes (inner dockerd, no
socket, entrypoint drop, no sudo) are identical.

## Agent capability deltas (sysbox mode)

- Same: docker run/build/compose, nested `-v "$(pwd)/x"`, host services via
  `host.docker.internal`.
- Gained: BuildKit/buildx (plugins shipped with inner engine).
- Lost: `--network host`, `--pid host`, `--userns host` for inner containers
  (unsupported by sysbox; host meant "box" anyway); visibility of host
  containers/images; serial devices without the sidecar.
- Changed: cold image cache per new box name; inner published ports are not
  on the host's ports; dockerd start adds launch latency.

## Spike checklist (open questions, in priority order)

1. Ownership of writes to `$PWD` by box root (via `docker run -v
   $PWD:$PWD alpine ...` inside). Docs: ID-mapped bind mounts keep host uids
   0-65535 identical -> box root may write as host uid 0 -> setuid-root
   binary planted in the workspace is host root escalation. Must find a
   mapping/config where box root does not land as host root (options to test:
   sysbox per-container uid mapping config, inner dockerd `userns-remap`,
   disabling ID-mapped mounts for the workspace), or document a host-side
   `nosuid` mount requirement. Blocks shipping.
2. Files written by the agent (box uid = host uid) land host-owned.
3. Inner dockerd start time; persistent `/var/lib/docker` volume behaviour
   across runs and a second concurrent box.
4. Compose, buildx, `docker -v "$(pwd)/x"`, `host.docker.internal` from
   inner containers.
5. Serial sidecar with a real flasher (DTR/RTS reset) and a plain terminal.
6. Podman branch: nested rootless podman with only `/dev/fuse` under Debian
   (no SELinux) and subuid range sizing.
7. Hardening flags (`no-new-privileges`, cap set) do not break the
   entrypoint root phase or toolchains.

## Risks

- Shared kernel: sysbox widens the kernel surface reachable from the box
  (userns-only syscalls, e.g. nftables). Kernel CVEs like CVE-2022-0185 were
  container escapes. Keep host kernel patched; VM modes are the only fix.
- Sysbox maintenance is community best-effort: runc escape CVEs of 2025-11
  were fixed in sysbox only in v0.7.0 (2026-06), ~7 months exposed. Pin a
  version, watch releases.
- No published security advisories / SECURITY.md for sysbox.

## Sources

- https://github.com/nestybox/sysbox/blob/master/docs/user-guide/security.md
- https://github.com/nestybox/sysbox/blob/master/docs/user-guide/design.md
- https://github.com/nestybox/sysbox/blob/master/docs/user-guide/storage.md
- https://github.com/nestybox/sysbox/blob/master/docs/user-guide/limitations.md
- https://github.com/nestybox/sysbox/blob/master/docs/user-guide/dind.md
- https://github.com/nestybox/sysbox/blob/master/docs/user-guide/security-cve.md
- https://github.com/nestybox/sysbox/issues/128 (podman)
- https://www.redhat.com/en/blog/podman-inside-container
- https://docs.docker.com/engine/security/rootless/tips/
- https://gvisor.dev/docs/tutorials/docker-in-gvisor/
- https://github.com/kata-containers/kata-containers/blob/main/docs/Limitations.md
- https://docs.docker.com/ai/sandboxes/security/isolation/
- https://edera.dev/stories/sysbox-increases-kernel-attack-surface-by-267-percent
