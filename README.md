# Distributed Iron Dome — Setup & Running Guide

This document explains what is in this repository, what has to be installed
and where, and the exact steps to compile and run the simulation — from a
single-machine sanity check up to a full multi-machine deployment. For a
description of how the code is put together internally (process trees,
inter-node interfaces, state machines), see
[`PROJECT_REPORT.md`](PROJECT_REPORT.md).

> **Prerequisites, at a glance** (on the coordinator machine — see the next
> section for exactly what each machine needs):
> - [**rebar3**](https://rebar3.org)
> - **Erlang/OTP 27.10**

## 1. What this repository contains

| Path | What it is |
|---|---|
| `distributed-iron-dome-erlang/` | The Erlang/OTP application — the actual project |
| `distributed-iron-dome-erlang/src/` | All application source code, one subfolder per subsystem (`app`, `cluster`, `sector`, `hostile`, `iron_dome`, `graphics`, `utilities`) |
| `distributed-iron-dome-erlang/rebar.config` | Build configuration for `rebar3` |
| `distributed-iron-dome-erlang/sys.config` | Runtime configuration: sectors, timings, cluster nodes, gameplay defaults |
| `distributed-iron-dome-erlang/deploy.escript` | Compiles the project and pushes it to every machine in the cluster |
| `distributed-iron-dome-erlang/README.md` | Module-by-module architecture reference (shipped with the source) |
| `distributed-iron-dome-erlang/LICENSE` | Apache License 2.0 |
| `distributed-iron-dome-erlang/test/` | EUnit unit tests and Common Test integration suites (see the Testing section below) |
| `distributed-iron-dome-erlang/.github/workflows/ci.yml` | CI: compile, EUnit, Common Test, Dialyzer on every push |
| `Docker/docker-compose.yml`, `Docker/Dockerfile` | Docker Compose setup that spins up 4 bare "worker" containers on one machine, for local testing without real hardware — see the "Local multi-node test with Docker Compose" section below for exact commands |
| `RUNNING_5_MACHINES.txt`, `read` | Original working notes this guide is based on and supersedes |
| `PROJECT_REPORT.md` | Design/architecture report: process trees, interfaces, state machines |

## 2. What you need installed, and where

Two node roles exist: **coordinator** (exactly one machine — runs cluster
orchestration and the graphics window) and **host / worker** (any number of
machines; the shipped configuration defines 4 sectors, so 4 workers is the
natural fit, but the code tolerates fewer or more).

| Machine role | Needs the project source? | Needs a compiler / `rebar3`? | Needs Erlang/OTP? | Needs graphics (`wx`)? |
|---|---|---|---|---|
| Coordinator | **Yes** — full checkout | **Yes** — `rebar3` | Yes | Yes (degrades to headless if unavailable) |
| Worker / host | **No** | **No** | Yes — just the `erl` runtime | No |

This asymmetry is intentional and is implemented by `deploy.escript`: it runs
`rebar3 compile` **locally, on the coordinator only**, then ships the
resulting compiled `.beam` binaries to each worker over the network and loads
them straight into that worker's already-running Erlang VM
(`code:load_binary/3` over RPC — see `deploy/4` in `deploy.escript` and
`push_modules/1` in `cluster_coordinator.erl`). A worker machine only ever
runs the stock `erl` shell that ships with Erlang/OTP: it never receives
`.erl` source, never runs `rebar3`, and never needs a git checkout of this
repository.

Concretely, before you start:

- **On the coordinator machine only:** a clone/copy of this repository,
  [rebar3](https://rebar3.org) on `PATH`, and an Erlang/OTP build that
  includes `wx` (see below).
- **On every worker machine:** Erlang/OTP installed so the `erl` command
  works. Nothing else — no source, no `rebar3`, no `sys.config`.

### Erlang/OTP version

**Required: Erlang/OTP 27.10**, plus **rebar3** on the coordinator. This is
the exact combination the project is built and tested against; match it on
every machine before doing anything else below. Nothing in the code relies
on syntax newer than that (`gen_statem` in `state_functions` mode, maps,
ETS, `erpc`), so nearby OTP 27 patch releases are expected to work too —
but keep versions close across nodes regardless, since distributed Erlang
assumes compatible peers, and use exactly 27.10 if you want your setup to
match this guide precisely. The bundled `Docker/Dockerfile` builds its worker
image from `erlang:27-slim`.

### `wx` (graphics) on the coordinator

On startup the coordinator tries to open a `wxWidgets` window
(`graphics_server`/`graphics` modules). If the local Erlang build lacks `wx`
support, or no display is reachable, this fails **gracefully**: the
coordinator logs `[graphics] window unavailable, running headless` and keeps
running the simulation with no visible window — nothing crashes. For a
working GUI, install an Erlang/OTP package built with `wx` (on Debian/Ubuntu
this usually means installing the `erlang-wx` package alongside `erlang`),
and run the coordinator on a machine with a display (or `DISPLAY` forwarded
over X11).

### Network requirements

Every machine (coordinator and every worker) must:

- Be reachable from every other machine over the network.
- Use the **same Erlang distribution cookie**. This project hardcodes
  `iron_dome_cookie` directly in the run commands and in `deploy.escript`, so
  no manual setup is needed — just don't change it on only one machine.
- Allow inbound TCP **4369** (`epmd`, the Erlang port mapper).
- Allow inbound TCP **9100** (the fixed Erlang distribution port this
  project uses — see `-kernel inet_dist_listen_min 9100
  inet_dist_listen_max 9100` in every command below).
- Start `erl` with `-kernel prevent_overlapping_partitions false` (already
  included in every command below). `deploy.escript` explicitly refuses to
  deploy to a node that was not started with this flag.

> The shared cookie is a plaintext secret checked into the scripts. That is
> fine on a trusted lab/classroom network but should not be relied on as a
> security boundary on an untrusted network.

## 3. Compiling the code — do you need to do it yourself?

No manual compilation step is required to run the project.
`deploy.escript` runs `rebar3 compile` for you as its first action, and
aborts with a clear error if compilation fails. You only need to run
`rebar3 compile` yourself if you want to sanity-check that the code builds,
or to use `rebar3 shell` for local development (the sanity check below).

Compiled output lands in
`distributed-iron-dome-erlang/_build/default/lib/iron_dome/ebin/*.beam` —
this is exactly the set of files `deploy.escript` reads and pushes to every
worker. Nothing else is copied to workers: no `.erl` source and no
`sys.config` file travel over the network — configuration values are sent as
an in-memory application-environment term instead (see
`shared_config/1`/`application_terms/2` in `deploy.escript`).

## 4. Quick local sanity check (single machine, no cluster)

Useful to confirm the project compiles and the graphics window opens, before
attempting a full distributed run:

```bash
cd distributed-iron-dome-erlang
rebar3 shell
```

This compiles the code and starts the application with `role = coordinator`
(the default in `sys.config`) as a non-distributed node. Because the
coordinator never runs sectors itself, and no worker is connected here,
you'll see an empty map with every sector reading `NO NODE AVAILABLE` — that
confirms the build and the GUI work, but this is **not** a full simulation.
Stop it with `Ctrl+C` twice, or by closing the window.

## 5. Local multi-node test with Docker Compose

The fastest way to exercise the *real* distributed behavior (4 worker nodes,
sector load-balancing, live failover) on a single machine, using the bundled
`Docker/docker-compose.yml` (Docker files live under the `Docker/` folder).
It starts four bare `erl_hostN` containers on a private Docker network
(`30.30.30.0/24`). Each container boots with nothing but an SSH server
running (see `Docker/Dockerfile`) — no Erlang node starts by itself. You
SSH into each container and start a plain `erl` node by hand, exactly the
same command as the real-machine case in section 6 below, just reached over
SSH instead of sitting at the machine. The coordinator itself still runs
directly on your host machine (it needs `wx`, which the slim container
image doesn't have).

**Docker is a convenience here, not a requirement.** The actual worker
requirement is just "a machine with Erlang/OTP installed" (see section 2
above) — nothing about `cluster_coordinator` or `deploy.escript` cares
whether that machine is bare metal, a VM, or a container. If you already
have real machines on your network, skip straight to section 6 and start
`erl` on each of them directly; that is the normal way to run this project.
What Docker Compose buys you is being able to try the *same* four-worker
setup without owning four separate machines — it stands in for them by
running four lightweight containers side by side on one computer. That
convenience has a cost: the coordinator and all four workers then compete
for that one machine's CPU and RAM, so how smoothly the simulation runs
depends entirely on that machine's hardware.

All `docker compose` commands below are run from the repository root with
`-f Docker/docker-compose.yml` (equivalently, `cd Docker` first and drop the
`-f` flag — either works, since `docker-compose.yml` pins its network's real
name to `iron_dome_net` regardless of which directory you run it from).

```bash
# 1. Start the four worker containers (each boots with just an SSH server
#    running — no Erlang node yet)
cd distributed-iron-dome-erlang
docker compose -f Docker/docker-compose.yml up -d
docker compose -f Docker/docker-compose.yml ps     # confirm all 4 are "Up"
```

**2. SSH into each container and start its Erlang node** — one block below
per container, each pasted into its **own terminal window/tab**, left
running (same as "leave every window open" in section 6 — closing one
removes that worker from the cluster). The login for every container is
the same: user `tal`, password `1234` (set in `Docker/Dockerfile`).

```bash
ssh tal@30.30.30.11                    # password: 1234
erl -name erl_host1@30.30.30.11 \
    -setcookie iron_dome_cookie \
    -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100 \
            prevent_overlapping_partitions false
```

```bash
ssh tal@30.30.30.12                    # password: 1234
erl -name erl_host2@30.30.30.12 \
    -setcookie iron_dome_cookie \
    -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100 \
            prevent_overlapping_partitions false
```

```bash
ssh tal@30.30.30.13                    # password: 1234
erl -name erl_host3@30.30.30.13 \
    -setcookie iron_dome_cookie \
    -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100 \
            prevent_overlapping_partitions false
```

```bash
ssh tal@30.30.30.14                    # password: 1234
erl -name erl_host4@30.30.30.14 \
    -setcookie iron_dome_cookie \
    -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100 \
            prevent_overlapping_partitions false
```

```bash
# 3. Find your host machine's IP on the compose network — this is the
#    address the containers can reach the coordinator on. It is normally
#    the ".1" address of the compose subnet (30.30.30.1), but confirm it:
ip addr show dev br-$(docker network inspect iron_dome_net -f '{{.Id}}' | cut -c1-12)

# 4. Back on your host machine, from the repository root: compiles locally
#    and pushes the compiled code to each of the four containers, then
#    starts the coordinator (with graphics) on your host machine — all
#    four workers in one paste:
./deploy.escript 30.30.30.1 \
    erl_host1@30.30.30.11 erl_host2@30.30.30.12 \
    erl_host3@30.30.30.13 erl_host4@30.30.30.14
```

Replace `30.30.30.1` in step 4 with whatever address step 3 actually reports
if it differs. When deployment finishes you'll see `Deployment complete.`
and the graphics window should open, showing four sectors each owned by one
container.

To exercise the recovery logic by simulating a worker failure:

```bash
docker compose -f Docker/docker-compose.yml stop erl_host2
    # cluster_coordinator detects this within roughly one heartbeat cycle
    # and redistributes sector_2 to a live worker
docker compose -f Docker/docker-compose.yml start erl_host2
    # only the container's SSH server comes back automatically — SSH back
    # in and re-run the erl_host2 command from step 2 above; only once
    # that node is reachable again does the coordinator notice, clear any
    # stale state on it, and give it sectors again
```

Tear everything down with `docker compose -f Docker/docker-compose.yml down`.

## 6. Real multi-machine deployment (e.g. 5 physical/virtual machines)

One coordinator machine (with a display, for the graphics window) plus one
or more worker machines. The shipped `sys.config` defines 4 sectors, so 4
workers is the natural match, but any number ≥ 1 works — sectors are
load-balanced across whatever is online, with `sector_N` preferring `hostN`
when it's available.

**Step 1 — on every worker machine.** No project checkout needed anywhere
here. Open a terminal on that machine — directly if you're at it, or over
SSH if it's remote (e.g. `ssh <user>@<that machine's IP>`, with whatever
username/password or key that machine actually uses — there's nothing
project-specific about it) — then start a bare Erlang node and leave the
terminal open — it now waits for the coordinator to push compiled code to
it:

```bash
erl -name erl_host1@<this machine's real LAN IP> \
    -setcookie iron_dome_cookie \
    -kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100 \
            prevent_overlapping_partitions false
```

Repeat on each additional worker, changing only the node name
(`erl_host2`, `erl_host3`, `erl_host4`, ...) and using that machine's own
real IP. **Leave every one of these windows open** — closing it removes that
worker from the cluster.

**Step 2 — on the coordinator machine.** This is the only machine that
needs the actual project checkout:

```bash
git clone <repo URL>
cd distributed-iron-dome-erlang
./deploy.escript <coordinator's own LAN IP> \
    erl_host1@<IP1> erl_host2@<IP2> erl_host3@<IP3> erl_host4@<IP4>
```

Under the hood, `deploy.escript`:

1. Starts a temporary distributed node on the coordinator
   (`deployer@<coordinator IP>`).
2. Pings each worker and verifies it was started with
   `prevent_overlapping_partitions false`.
3. Runs `rebar3 compile` locally.
4. Loads every compiled module into each worker's running VM
   (`code:load_binary/3` over RPC) and starts the `iron_dome` application
   there with `role = host`.
5. Starts the `iron_dome` application locally with `role = coordinator` and
   `graphics_enabled = true`.

On success it prints `Deployment complete.`. If it instead prints `pang` for
a node, see Troubleshooting below.

## 7. While it's running

The graphics window's bottom control bar lets you change, live and across
the whole cluster: the missile movement tick interval, the hostile launch
interval, interceptor hit chance, and hostile accuracy. Edit a value and
click **APPLY** — the new values are pushed via RPC to the coordinator and
every currently-known worker node, with automatic retries if any node
doesn't confirm. **Reset** clears every sector's statistics without
stopping the simulation.

## 8. Shutting down

Close the graphics window, or `Ctrl+C` in the coordinator's terminal. This
tells `cluster_coordinator` to stop every worker node first, then stop
itself, so the whole cluster goes down together. Worker terminals that were
started manually (real multi-machine case) simply exit on their own; Docker
Compose containers stop as part of the `iron_dome` application being shut
down remotely inside them (`docker compose -f Docker/docker-compose.yml ps`
will show them exited — `docker compose -f Docker/docker-compose.yml up -d`
starts a fresh run).

## 9. Configuration reference

All simulation values live in `distributed-iron-dome-erlang/sys.config`.
This file is read by the coordinator; the values workers need are packaged
and sent to them by `deploy.escript` — worker machines never need their own
copy of it. Key settings:

| Setting | Meaning |
|---|---|
| `role` | Default node role: `coordinator` or `host` (`deploy.escript` overrides this per node) |
| `graphics_enabled` | Enables/disables the graphics window |
| `tick_ms` | Movement update interval for all missiles |
| `snapshot_interval_ms` | Interval between checkpoint collection rounds |
| `checkpoint_history_ms` | Amount of checkpoint history retained, for recovery |
| `graphics_sync_ms` | Time between graphics frames (`33` ≈ 30 FPS) |
| `heartbeat_interval_ms` / `heartbeat_timeout_ms` | Worker liveness check cadence / timeout |
| `cluster_nodes` | Worker node list, used only when none is given on the `deploy.escript` command line |
| `defaults.radar.sample_ms` | Radar sampling interval |
| `defaults.launcher.interceptors_per_engagement` | Interceptors launched per engagement |
| `defaults.interceptor.hit_radius` / `hit_chance` | Interceptor collision radius / hit probability |
| `defaults.hostile_city.spawn_ms` | Time between hostile launches |
| `defaults.hostile_missile.speed_range` / `min_launch_angle` / `accuracy` / `city_hit_radius` | Hostile launch physics and accuracy |
| `sectors` | Per-sector boundaries, launcher position, and city positions |

Probability values use the range `0.0`–`1.0` (e.g. `0.8` means 80%). See
`distributed-iron-dome-erlang/README.md` for the full annotated table, and
[`PROJECT_REPORT.md`](PROJECT_REPORT.md) for how these values are used
architecturally.

## 10. Testing

Before deploying anywhere, you can verify the code itself is sound on a single machine — no cluster, no graphics, no containers:

```bash
cd distributed-iron-dome-erlang
rebar3 eunit       # physics & config unit tests
rebar3 ct           # single-node sector integration test + a real
                     # multi-node cluster-failover test (spins up
                     # actual distributed Erlang nodes locally)
rebar3 dialyzer     # static analysis
```

`rebar3 ct` in particular runs an automated version of the "kill a
worker and watch it recover" drill from the Docker Compose section
above: it brings up a coordinator and two worker nodes as real, separate
distributed Erlang nodes on your machine, confirms sectors land where
expected, then kills one worker outright and confirms
`cluster_coordinator` reassigns its sector to the survivor — the same
thing that section has you trigger by hand with `docker compose stop`,
just checked on every run instead of only before a demo. See
`distributed-iron-dome-erlang/README.md`'s "Testing" section for what
each suite covers, and the "Testing & Quality Assurance" section of
[`PROJECT_REPORT.md`](PROJECT_REPORT.md) for the reasoning behind what
is and isn't automated.

## 11. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `deploy.escript` prints `pang` for a node | Wrong node name/IP, cookie mismatch, or a firewall blocking TCP 4369/9100 on that machine. |
| `Restart <node> with -kernel prevent_overlapping_partitions false` | The worker's `erl` was started without that flag — restart it with the exact command in Step 1 of the multi-machine deployment section above. |
| `rebar3 compile failed with status ...` | A syntax error was introduced, or `rebar3`/Erlang isn't correctly on `PATH` on the coordinator. |
| Graphics window never appears; log shows `window unavailable, running headless` | The coordinator's Erlang build lacks `wx`, or no display is reachable. The simulation still runs — install `erlang-wx` (or equivalent) and/or run on a machine with a display to get the GUI. |
| A sector shows `NO NODE AVAILABLE` | No worker is currently online for that sector. Start/reconnect a worker; `cluster_coordinator` reassigns automatically once one appears. |
| Windows machines: connections silently fail the first time | Windows Defender Firewall blocks the first inbound connection to `erl.exe`/`epmd.exe` silently, then stops blocking once you grant access. **Rehearse the full deployment once before any live demo** to catch this in advance rather than during it. |

## 12. Roles at a glance

```text
Coordinator machine                    Worker machine(s)
--------------------                    ------------------
git checkout .............. required    not needed
rebar3 / compiler ......... required    not needed
erl (Erlang/OTP runtime) .. required    required
wx (graphics library) ..... required*   not needed
runs ....................... deploy.escript   plain `erl -name ... -setcookie ...`
ends up running ............ role=coordinator role=host (pushed remotely)

* falls back to headless automatically if unavailable — simulation still runs
```
