# Distributed Iron Dome Simulation

An Erlang/OTP student project that simulates a distributed air-defense system. Hostile cities launch ballistic missiles, radars observe them, Iron Dome computers predict their paths, and launchers fire interceptors to protect cities.

The environment contains four sectors. Each sector runs on a worker node, while a separate coordinator manages sector assignments, snapshots, recovery, and graphics.

## Architecture

```text
Coordinator node
├── cluster_coordinator
├── snapshot_manager
└── graphics_server
    └── graphics

Worker node
└── node_manager
    └── sector_supervisor (one per sector)
        ├── sector_controller
        ├── iron_dome_radar
        ├── iron_dome_computer
        ├── iron_dome_launcher
        ├── hostile_city processes
        ├── hostile_missile processes
        └── iron_dome_missile processes
```

The coordinator does not run sectors. It assigns sectors to workers and manages recovery when a worker disconnects.

## Source Code

The source code is organized by responsibility under `src/`.

### `src/app/`

| File | Responsibility |
|---|---|
| `app.erl` | OTP application callback that starts the root supervisor |
| `app_sup.erl` | Starts coordinator processes or the worker's `node_manager`, according to the node role |
| `config.erl` | Provides shared access to simulation settings and sector ownership |

`src/iron_dome.app.src` defines the OTP application, modules, dependencies, and default environment.

The application has two roles:

- `coordinator` starts `snapshot_manager`, `graphics_server`, and `cluster_coordinator`.
- `host` starts `node_manager`.

### `src/cluster/`

| File | Responsibility |
|---|---|
| `cluster_coordinator.erl` | Assigns sectors, checks worker heartbeats, performs failover, and handles worker recovery |
| `node_manager.erl` | Starts, stops, and monitors sectors on one worker node |
| `snapshot_manager.erl` | Stores current snapshots and checkpoint history for graphics and recovery |

When a worker fails, the coordinator pauses the surviving workers, obtains a complete checkpoint, redistributes all sectors, restores their state, and resumes the simulation.

Each sector has a preferred home host based on its number. For example, `sector_2` prefers `host2`. If that host is unavailable, the sector is assigned to the live worker with the lowest number of sectors. Host names resolve ties.

### `src/sector/`

| File | Responsibility |
|---|---|
| `sector_supervisor.erl` | Supervises all permanent and temporary processes in one sector |
| `sector_controller.erl` | Stores sector entities and statistics, manages ETS, and creates sector snapshots |

Each sector has its own ETS entity table. Missile processes update their public state in this table, and the radar reads local hostile positions from it. ETS is local to one Erlang node; distributed data is transferred through Erlang messages and calls.

### `src/hostile/`

| File | Responsibility |
|---|---|
| `hostile_city.erl` | Selects protected-city targets and periodically launches hostile missiles |
| `hostile_missile.erl` | Simulates hostile missile movement, sector transfer, interception, and ground impact |

### `src/iron_dome/`

| File | Responsibility |
|---|---|
| `iron_dome_radar.erl` | Samples hostile missiles in its sector and broadcasts observations |
| `iron_dome_computer.erl` | Reconstructs trajectories from three observations, assesses threats, and plans interceptions |
| `iron_dome_launcher.erl` | Launches interceptor missiles |
| `iron_dome_missile.erl` | Simulates interceptor movement and collision checks |

### `src/graphics/`

| File | Responsibility |
|---|---|
| `graphics_server.erl` | Receives graphics events, reads snapshots, and manages the wx event loop |
| `graphics.erl` | Creates the window, draws frames, and implements the simulation controls |

The graphics display live sector ownership, cities, launchers, missiles, explosions, and global and per-sector statistics.

### `src/utilities/`

| File | Responsibility |
|---|---|
| `physics.erl` | Contains gravity, ballistic motion, trajectory reconstruction, aiming, distance, and timing calculations |

## Simulation Flow

1. A `hostile_city` selects a protected city and creates a hostile missile.
2. The missile follows a ballistic path calculated by `physics`.
3. The radar in the missile's current sector broadcasts observations to all Iron Dome computers.
4. Each computer uses three observations to reconstruct the missile path.
5. The responsible computer selects an interception and asks its launcher to fire.
6. The interceptor moves toward the planned interception point.
7. Interception, ground impact, or leaving the environment completes the missile process and updates the statistics.

## Configuration

All main simulation settings are defined in `config/sys.config`.

| Setting | Meaning |
|---|---|
| `role` | Default node role: `coordinator` or `host` |
| `graphics_enabled` | Enables or disables the graphics window |
| `tick_ms` | Movement update interval for all missiles |
| `snapshot_interval_ms` | Interval between checkpoint collection rounds |
| `checkpoint_history_ms` | Amount of checkpoint history retained |
| `graphics_sync_ms` | Time between graphics frames; `33` is approximately 30 FPS |
| `heartbeat_interval_ms` | Time between worker checks |
| `heartbeat_timeout_ms` | Maximum time to wait for a worker response |
| `cluster_nodes` | Worker nodes when they are not supplied during deployment |
| `defaults.radar.sample_ms` | Radar sampling interval |
| `defaults.launcher.interceptors_per_engagement` | Number of interceptors launched for one threat |
| `defaults.interceptor.hit_radius` | Collision radius for an interception |
| `defaults.interceptor.hit_chance` | Probability that a valid collision destroys the hostile missile |
| `defaults.hostile_city.spawn_ms` | Time between hostile launches |
| `defaults.hostile_missile.speed_range` | Random hostile launch-speed range |
| `defaults.hostile_missile.min_launch_angle` | Minimum low-trajectory launch angle |
| `defaults.hostile_missile.accuracy` | Probability that a hostile missile lands within the city hit radius |
| `defaults.hostile_missile.city_hit_radius` | Protected-city hit radius |
| `sectors` | Sector boundaries and city and launcher positions |

Probability values use the range `0.0` to `1.0`. For example, `0.8` means 80%.

## Distributed Deployment

Deployment is performed by `scripts/deploy.escript` from the coordinator computer. Only the coordinator needs the source code. The script:

1. Starts a temporary distributed Erlang node on the coordinator.
2. Checks that every worker is reachable and correctly configured.
3. Compiles every module under `src/`.
4. Loads the compiled BEAM files into each worker.
5. Loads the application configuration from `config/sys.config`.
6. Starts the application with the `host` role on workers.
7. Starts the application with the `coordinator` role and graphics locally.

Before deployment, start a plain Erlang node on every worker computer:

```bash
erl -name host1@10.0.0.43 \
    -setcookie iron_dome_cookie \
    -kernel inet_dist_listen_min 9100 \
            inet_dist_listen_max 9100 \
            prevent_overlapping_partitions false
```

Use a unique host name and the correct LAN IP on every worker.

Run the deployment from the project directory on the coordinator:

```bash
./scripts/deploy.escript 10.0.0.30 \
    host1@10.0.0.43 \
    host2@10.0.0.44 \
    host3@10.0.0.31
```

The first argument is the coordinator IP. The remaining arguments are the worker node names.

Every node must:

- Use the same Erlang cookie.
- Be reachable over the local network.
- Allow TCP port `4369` for EPMD.
- Allow TCP port `9100` for Erlang distribution.
- Use `prevent_overlapping_partitions false`.

If deployment reports `pang`, verify the node name, IP address, cookie, firewall, and distribution ports.
