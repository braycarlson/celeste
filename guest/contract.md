# Guest Contract

## Overview

This document is the contract between the hypervisor and the software it runs. The hypervisor never learns which language produced the bytes it reads: a guest is any Linux image that boots the project kernel, talks to the x86 I/O ports in the table below, and prints lines that begin with `DST ` on the serial console. An SDK is a convenience over this contract, and a project that only prints acknowledgements can run without one. The Zig side reads the ports in `src/ports.zig`, the console in `src/verdict.zig`, and the event block in `src/faults.zig`; each SDK carries its own hand-written copy of the event block so that a drift between the two decoders fails a run instead of hiding.

## Boot

The kernel command line carries the run's configuration. Each word of the form `dst.<key>=<value>` is exported by `/init` as the environment variable `DST_<KEY>`, with the key upper-cased and dots turned into underscores, so `dst.mode=check` becomes `DST_MODE=check` and `dst.coverage=1` becomes `DST_COVERAGE=1`. The hypervisor appends `dst.eventually_ns=<N>` when the eventually phase is configured.

| Variable | Description |
|---|---|
| `DST_MODE` | The boot's purpose: `run` executes the workload, `check` verifies what survived a power loss, and `halt` reboots at once. |
| `DST_COVERAGE` | A value of `1` turns on coverage reporting in each SDK that supports it. |
| `DST_EVENTUALLY_NS` | The length of the eventually phase in nanoseconds, or `0` when there is none. |
| `DST_NODES` | The space-separated names of the network namespaces to create before the services start. |
| `DST_SERVICES` | The space-separated services `/init` starts in order before the setup: `postgres`, `redis`, or `rabbitmq`. |

A project lives at `/opt/project` and declares itself through executable files in `/opt/project/harness`. The `/init` script sources `env`, brings up the nodes, starts the services named in `DST_SERVICES`, runs `setup` once on the first boot (the marker is `/var/lib/dst-setup`), runs `start` with the mode as its argument, and then runs `run` or `check` by mode. A guest reboots with `reboot -f` when the last script returns.

| File | Description |
|---|---|
| `env` | A shell fragment that exports the project's variables, including `DST_SERVICES`, `DST_NODES`, and any `PATH` additions. |
| `setup` | A script that initialises state on the first boot, after the services are up. |
| `start` | A script that starts the project's own processes; it receives the mode. |
| `run` | The workload. It calls ready, drives the system, and ends with a power loss or a return. |
| `check` | The verifier. It prints a `DST PRESENT` line per surviving acknowledgement and ends with `DST CHECK DONE`. |
| `nodes` | An optional hosts file fragment naming each node's address. |
| `eventually` | An optional liveness check a project runs after the faults stop. |

The agent (`python3 -m dst.agent`, at `/opt/sdk`) executes the faults inside the guest. It is started by the SDK's ready call as a child of the workload, and a guest without it receives no faults.

## Ports

Each port is one byte wide and is read and written through `/dev/port` (or `in`/`out` after `ioperm`). A multi-byte value is little-endian across consecutive ports. The draw, event, and guidance exchanges happen under an exclusive `flock` on `/dev/shm/dst-draw`, so that processes drawing at once receive whole words.

| Port | Description |
|---|---|
| `0x505` | The control port. A write of `1` is the power loss, `2` is ready, `3` asks for the next event's delay, `4` marks the quiet point, and `5` asks for the due event. |
| `0x508` to `0x50f` | The run's seed, readable at any time. |
| `0x510` to `0x5df` | The served event block, readable after a control write of `3` or `5`. |
| `0x5e0` | The draw latch. A write of `1` draws the next word of the workload stream. |
| `0x5e1` to `0x5e8` | The drawn word. |
| `0x5f0` to `0x5f2` | A fresh coverage index. The third byte commits the three. |
| `0x5f4` to `0x5ff` | A guidance report: the crc32 of the message, then the value. The twelfth byte commits. |

## Draws

A draw returns one 64-bit word from the workload stream. The mapping from a word to a value is fixed so that a shrunk stream of minimal words is the smallest workload: `below(n)` is `(word * n) >> 64`, `boolean` is the top bit, and `choice` indexes a list with `below(len)`. A word is drawn, never reused, so each draw advances the stream by one.

## Events

The agent asks twice per event. A control write of `3` serves a block whose `delay_ns` is the time to wait and whose kind is none. A control write of `5` after the wait serves the due event. A kind of none ends the timeline, and its `delay_ns` then carries the time left in the fault window, which an eventually phase uses to schedule the heal. The agent echoes each event it receives as `DST EVENT <fields> END`, and the hypervisor fails the attempt when the echo differs from what it served.

A project's configuration names the roster its kill, pause, thread pause, and throttle events draw their targets from: `services` (the default: celery_worker, gunicorn_worker, postgres_backend, postmaster, rabbitmq, and redis_server) or `docker` (containerd and dockerd). The roster changes only the target an event names, so every other field of a seed's events is the same under either roster, and a target the guest lacks is a logged no-op (`DST FAULT kill <target> absent`).

The block is 184 bytes of 64-bit little-endian fields in this order.

| Field | Description |
|---|---|
| `magic` | The constant `0x31544e5645545344`. A different value means the ports are not served. |
| `kind` | The event kind: `0` none, `1` clock_jump, `2` clock_slew, `3` disk_full, `4` kill, `5` memory, `6` network, `7` pause, `8` thread_pause, `9` throttle. |
| `delay_ns` | The delay the agent waited before this event was due. |
| `duration_ns` | The length of a timed event. |
| `target` | The target: `0` none, `1` celery_worker, `2` gunicorn_worker, `3` postgres_backend, `4` postmaster, `5` rabbitmq, `6` redis_server, `7` workload, `8` containerd, `9` dockerd. |
| `choice` | The index among the target's processes. |
| `restart` | A value of `1` when a killed service is restarted. |
| `restart_delay_ns` | The delay before the restart. |
| `clock_jump_ns` | A signed jump of the real-time clock. |
| `clock_slew_ppm` | A signed slew rate. |
| `disk_full_slack_kib` | The free space a disk-full fault leaves. |
| `memory_immune` | A value of `1` when the hog is immune to the OOM killer. |
| `memory_kills` | The number of OOM kills the hog waits for. |
| `network_delay_ns` | The added latency. |
| `network_direction` | The direction: `0` both, `1` requests, `2` replies. |
| `network_jitter_ns` | The latency jitter. |
| `network_link` | The link: `0` none, `1` postgres, `2` rabbitmq, `3` redis. |
| `network_loss_permille` | The loss rate; `1000` is a partition. |
| `network_peers` | A bit mask of partitioned peers; `0` means everyone. |
| `network_reorder_permille` | The reorder rate. |
| `pause_tree` | A value of `1` when a pause covers the target's whole process tree. |
| `thread_choice` | The index of the paused thread. |
| `throttle_permille` | The CPU quota of a throttle. |

The echo lists each field after the magic as `name=value`, separated by single spaces, with the enumerated fields printed by name and the signed fields as signed decimals.

## Coverage

A coverage source hashes each location it sees for the first time into a 24-bit index, sets that bit in the shared bitmap at `/dev/shm/dst-coverage`, and writes the index to the coverage ports under the draw lock. The hypervisor records the exit at which each fresh bit arrived and forks continuations from those points. The Python SDK hashes `file:qualname:line` from `sys.monitoring`; the compiled SDKs hash the guard ordinal from SanitizerCoverage's `trace-pc-guard` instrumentation.

## Guidance

A guidance report carries the crc32 of a declared `maximize` message and a value. The hypervisor keeps the run's maximum per message and the fork point where it was reached, and the explorer prefers runs that raise a maximum.

## Console

Each line is `DST <WORD> ...` followed by a newline, written to `/dev/console` in one write so that lines from different processes never interleave. The verdict reads the lines in the first table; the lines in the second are informational and tests search for them.

| Line | Description |
|---|---|
| `DST DECLARE <kind> <message>` | A property the run will report on. The kind is `always`, `sometimes`, `reachable`, `unreachable`, or `maximize`. A message holds at most 1024 bytes, carries no `\|`, and a run declares at most 256 properties. |
| `DST ACK <uuid>` | An acknowledgement the outside world received. The identifier is a 36-character UUID. |
| `DST PRESENT <uuid>` | An acknowledgement found intact after recovery. An acknowledged identifier without a present line is a lost write. |
| `DST ALWAYS PASS <message>` | A passed check of an always property. |
| `DST ALWAYS FAIL <message> \| <details>` | A failed check. The details are optional and free-form. |
| `DST SOMETIMES <message>` | A sometimes property that was reached. |
| `DST REACHABLE <message>` | A reachable property that was reached. |
| `DST UNREACHABLE <message> \| <details>` | An unreachable property that was reached, which fails the run. |
| `DST EVENT <fields> END` | The agent's echo of a served event. |
| `DST EVENTUALLY PASS` or `DST EVENTUALLY FAIL` | The result of the eventually phase. |
| `DST AGENT ERROR <text>` | A failure inside the agent, which fails the attempt. |
| `DST CHECK DONE` | The end of a check. A run without it has not been verified. |

| Line | Description |
|---|---|
| `DST GUEST UP` | The init reached user space. |
| `DST CPUS <n>` | The processors the workload sees. |
| `DST SERVICE <name> EXIT <code>` | A service started by `/init`. |
| `DST SETUP EXIT <code>` | The first-boot setup finished. |
| `DST FAULT ...` | The agent applied, healed, or could not apply a fault. |
| `DST KERNEL ...` | A kernel log line the agent forwards: I/O errors, filesystem errors, and OOM kills. |
| `DST QUIET` | The faults stopped and the eventually phase may begin. |
| `DST WORKLOAD DONE ...` | The workload's own summary. |

## Minimum

A project without an SDK prints `DST ACK` lines as it receives acknowledgements, writes `2` to the control port when it is ready and `1` when it wants the power loss, and prints `DST PRESENT` lines and `DST CHECK DONE` in the check boot. That is enough for the crash, replay, shrink, and reproducer machinery. The draws, properties, events, coverage, and guidance each add one port exchange or one line from the tables above.
