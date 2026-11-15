# Guest Interface

## Overview

This document specifies the interface between the hypervisor and the software it runs. The hypervisor never learns which language produced the bytes it reads: a guest is any Linux image that boots the project kernel, talks to the x86 I/O ports in the table below, and prints lines that begin with `CELESTE ` on the serial console. An SDK is a convenience over this interface, and a project that only prints acknowledgements can run without one. The Zig side reads the ports in `src/ports.zig`, the console in `src/verdict.zig`, and the event block in `src/faults.zig`; each SDK carries its own hand-written copy of the event block so that a drift between the two decoders fails a run instead of hiding.

## Boot

The kernel command line carries the run's configuration. Each word of the form `celeste.<key>=<value>` is exported by `/init` as the environment variable `CELESTE_<KEY>`, with the key upper-cased and dots turned into underscores, so `celeste.mode=check` becomes `CELESTE_MODE=check` and `celeste.coverage=1` becomes `CELESTE_COVERAGE=1`. The hypervisor appends `celeste.eventually_ns=<N>` when the eventually phase is configured, and `celeste.targets=<a,b,...>` and `celeste.links=<x,y,...>` when the configuration's `fault_roster` names targets or links.

| Variable | Description |
|---|---|
| `CELESTE_MODE` | The boot's purpose: `run` executes the workload, `check` verifies what survived a power loss, and `halt` reboots at once. |
| `CELESTE_COVERAGE` | A value of `1` turns on coverage reporting in each SDK that supports it. |
| `CELESTE_EVENTUALLY_NS` | The length of the eventually phase in nanoseconds, or `0` when there is none. |
| `CELESTE_NODES` | The space-separated names of the network namespaces to create before the services start. |
| `CELESTE_TARGETS` | The comma-separated names of the fault targets, in roster order. |
| `CELESTE_LINKS` | The comma-separated names of the network links, in roster order. |
| `CELESTE_FAULTS` | The path of the fault rules, `/opt/project/harness/faults.json` when unset. |

A project lives at `/opt/project` and declares itself through executable files in `/opt/project/harness`. The `/init` script sources `env`, brings up the nodes, runs `services`, runs `setup` once on the first boot (the marker is `/var/lib/celeste-setup`), runs `start` with the mode as its argument, and then runs `run` or `check` by mode. A guest reboots with `reboot -f` when the last script returns.

| File | Description |
|---|---|
| `env` | An optional shell fragment that exports the project's variables, including `CELESTE_NODES` and any `PATH` additions. |
| `services` | An optional script that starts the project's own servers on every boot, before `setup`. The base image starts none. |
| `setup` | A script that initialises state on the first boot, after the services are up. |
| `start` | A script that starts the project's own processes; it receives the mode. |
| `run` | The workload. It calls ready, drives the system, and ends with a power loss or a return. |
| `check` | The verifier. It prints a `CELESTE PRESENT` line per surviving acknowledgement and ends with `CELESTE CHECK DONE`. |
| `nodes` | An optional hosts file fragment naming each node's address. |
| `faults.json` | The fault rules: how the agent finds each target named in `CELESTE_TARGETS` and each link named in `CELESTE_LINKS`. Required when the roster names anything. |
| `eventually` | An optional liveness check a project runs after the faults stop. |

The agent (`python3 -m celeste_agent`, at `/opt/sdk`) executes the faults inside the guest. It is started by the SDK's ready call as a child of the workload, and a guest without it receives no faults. The agent reads its rules, copies `tc` and the libraries its loader lists into `/dev/shm/celeste-tools`, locks its own memory, and creates `/dev/shm/celeste-agent-ready`, all before ready opens the fault window, so a disk read error or memory pressure the agent injects never reaches the agent's own code or `tc`. The ready call writes `2` to the control port only after that file or `/dev/shm/celeste-agent-error` appears, and when neither appears within 10 seconds it prints `CELESTE AGENT ERROR` and creates `/dev/shm/celeste-agent-error` itself, so an agent that never starts fails the attempt rather than hanging it. Ready then creates `/dev/shm/celeste-window`, and the agent asks for its first event only once that file exists, so the first fault can land in the first moments of the workload. At the quiet point the agent also restarts each target that has a `restart` command and no live process, unless a restart for it is already pending, the way a supervisor would bring back a service that a fault drove to exit on its own (a postmaster that shuts down when crash recovery meets a full disk). The agent creates `/dev/shm/celeste-quiet` once every fault has stopped and healed, `/dev/shm/celeste-unhealed` in its place when every fault has stopped but a heal or such a restart failed or the root filesystem refuses a write to `/var/lib/celeste-writable` (a write error that aborts the ext4 journal leaves the filesystem refusing writes, which only the reboot that follows undoes, and the mount flags do not show it), and `/dev/shm/celeste-agent-error` when it prints an `AGENT ERROR`. An SDK's quiet wait ends at whichever comes first and returns true only for the first: the eventually phase may begin after quiet, an unhealed guest cannot be expected to recover without the reboot that follows, and an agent error means the attempt has already failed and need not wait.

## Ports

Each port is one byte wide and is read and written through `/dev/port` (or `in`/`out` after `ioperm`). A multi-byte value is little-endian across consecutive ports. The draw, event, and guidance exchanges happen under an exclusive `flock` on `/dev/shm/celeste-draw`, so that processes drawing at once receive whole words.

| Port | Description |
|---|---|
| `0x505` | The control port. A write of `1` is the power loss, after which an SDK's power-loss call waits instead of returning, so nothing after it runs when a debug session ignores the cut; `2` is ready, `3` asks for the next event's delay, `4` marks the quiet point, and `5` asks for the due event. |
| `0x508` to `0x50f` | The run's seed, readable at any time. |
| `0x510` to `0x5df` | The served event block, readable after a control write of `3` or `5`. |
| `0x5e0` | The draw latch. A write of `1` draws the next word of the workload stream. |
| `0x5e1` to `0x5e8` | The drawn word. |
| `0x5f0` to `0x5f2` | A fresh coverage index. The third byte commits the three. |
| `0x5f4` to `0x5ff` | A guidance report: the crc32 of the message, then the value. The twelfth byte commits. |

## Draws

A draw returns one 64-bit word from the workload stream. The mapping from a word to a value is fixed so that a shrunk stream of minimal words is the smallest workload: `below(n)` is `(word * n) >> 64`, `boolean` is the top bit, and `choice` indexes a list with `below(len)`. A word is drawn, never reused, so each draw advances the stream by one.

## Events

The agent asks twice per event. A control write of `3` serves a block whose `delay_ns` is the time to wait and whose kind is none. A control write of `5` after the wait serves the due event. A kind of none ends the timeline, and its `delay_ns` then carries the time left in the fault window, which an eventually phase uses to schedule the heal. The agent echoes each event it receives as `CELESTE EVENT <fields> END`, and the hypervisor fails the attempt when the echo differs from what it served.

## Roster

The hypervisor names no process and no service. A project's configuration declares a `fault_roster`: the targets its kill, pause, thread pause, and throttle events draw from, and the links its network events draw from. The hypervisor knows each entry only by name and by two flags; the guest's `faults.json` says how to find it.

```zon
.fault_roster = .{
    .targets = .{
        .{ .name = "web_worker" },
        .{ .name = "database", .restart = true },
        .{ .kill = false, .name = "workload" },
    },
    .links = .{ "database" },
},
```

| Field | Description |
|---|---|
| `targets` | At most 16 entries. A kill event draws only from entries with `kill` true (the default); a pause, thread pause, or throttle event draws from every entry. `restart` true lets a kill carry a restart. |
| `links` | At most 6 names. |

Each name is 1 to 32 characters of `a-z`, `0-9`, and `_`, and appears once. A roster changes only the target and the link an event names, so every other field of a seed's events is the same under any roster; with no targets, a targeted draw serves no event, and with no links, a network draw serves none. A target that matches no process is a logged no-op (`CELESTE FAULT kill <target> absent`).

`faults.json` maps each name to a rule. The agent fails the attempt with `CELESTE AGENT ERROR` when a name in `CELESTE_TARGETS` or `CELESTE_LINKS` has no rule, when a rule carries an unknown field, or when a target rule has no selector.

```json
{
    "targets": {
        "web_worker": {"parent_pidfile": "/run/gunicorn.pid"},
        "database": {
            "pidfile": "/var/lib/postgresql/17/main/postmaster.pid",
            "restart": ["/opt/project/harness/service", "postgres"]
        },
        "workload": {"workload": true}
    },
    "links": {
        "database": {"port": 5432}
    }
}
```

| Target field | Description |
|---|---|
| `pidfile` | Selects the process whose pid the file holds. |
| `parent_pidfile` | Selects the children of the process whose pid the file holds; a tree pause starts from that parent. |
| `program` | Selects processes whose executable's base name equals the value. |
| `command_prefix` | Selects processes whose command line starts with the value. |
| `command_contains` | Selects processes whose command line contains any of the listed strings. |
| `workload` | `true` selects the workload, the agent's parent. |
| `restart` | The argv the agent runs to restart the target after a kill. |
| `node_env` | The environment variable holding the node the target runs on; a fault on a target with a node acts on the whole node. |

Selectors combine: a process must pass every one present.

| Link field | Description |
|---|---|
| `port` | The TCP port whose requests (destination) and replies (source) the link's faults act on. |
| `node_env` | The environment variable holding the node the link's server runs on; a fault on a link with a node acts on the node's interface. |

## Event block

The block is 184 bytes of 64-bit little-endian fields in this order.

| Field | Description |
|---|---|
| `magic` | The constant `0x32455453454c4543` (`CELESTE2`). A different value means the ports are not served or speak another interface version. |
| `kind` | The event kind: `0` none, `1` clock_jump, `2` clock_slew, `3` disk_full, `4` kill, `5` memory, `6` network, `7` pause, `8` thread_pause, `9` throttle. |
| `delay_ns` | The delay the agent waited before this event was due. |
| `duration_ns` | The length of a timed event. |
| `target` | `0` for none, otherwise the 1-based index of the target in the roster. |
| `choice` | The index among the target's processes. |
| `restart` | A value of `1` when a killed service is restarted. |
| `restart_delay_ns` | The delay before the restart. |
| `clock_jump_ns` | A signed jump of the real-time clock. |
| `clock_slew_ppm` | A signed slew rate. |
| `disk_full_slack_kib` | The free space a disk-full fault leaves. |
| `memory_immune` | A value of `1` when the hog is immune to the OOM killer. |
| `memory_kills` | The number of OOM kills the hog waits for. The hog fills memory down to 32 MiB available and then asks the kernel's OOM killer for each kill in turn through sysrq, since reclaim without swap thrashes long before the kernel kills on its own. |
| `network_delay_ns` | The added latency. |
| `network_direction` | The direction: `0` both, `1` requests, `2` replies. |
| `network_jitter_ns` | The latency jitter. |
| `network_link` | `0` for none, otherwise the 1-based index of the link in the roster. |
| `network_loss_permille` | The loss rate; `1000` is a partition. |
| `network_peers` | A bit mask of partitioned peers; `0` means everyone. |
| `network_reorder_permille` | The reorder rate. |
| `pause_tree` | A value of `1` when a pause covers the target's whole process tree. |
| `thread_choice` | The index of the paused thread. |
| `throttle_permille` | The CPU quota of a throttle. |

The echo lists each field after the magic as `name=value`, separated by single spaces, with `kind` and `network_direction` printed by name, `target` and `network_link` as their indices, and the signed fields as signed decimals.

## Coverage

A coverage source hashes each location it sees for the first time into a 24-bit index, sets that bit in the shared bitmap at `/dev/shm/celeste-coverage`, and writes the index to the coverage ports under the draw lock. The hypervisor records the exit at which each fresh bit arrived and forks continuations from those points. The Python SDK hashes `file:qualname:line` from `sys.monitoring`; the compiled SDKs hash the guard ordinal from SanitizerCoverage's `trace-pc-guard` instrumentation.

## Guidance

A guidance report carries the crc32 of a declared `maximize` message and a value. The hypervisor keeps the run's maximum per message and the fork point where it was reached, and the explorer prefers runs that raise a maximum.

## Console

Each line is `CELESTE <WORD> ...` followed by a newline, written to `/dev/console` in one write so that lines from different processes never interleave. Another process may still leave an unfinished line on the console, such as the progress dots of `pg_ctl -w`, so the verdict reads a line from its first `CELESTE ` and ignores whatever precedes it. The verdict reads the lines in the first table; the lines in the second are informational and tests search for them.

| Line | Description |
|---|---|
| `CELESTE DECLARE <kind> <message>` | A property the run will report on. The kind is `always`, `sometimes`, `reachable`, `unreachable`, or `maximize`. A message holds at most 1024 bytes, carries no `\|`, and a run declares at most 256 properties. |
| `CELESTE ACK <uuid>` | An acknowledgement the outside world received. The identifier is a 36-character UUID. |
| `CELESTE PRESENT <uuid>` | An acknowledgement found intact after recovery. An acknowledged identifier without a present line is a lost write. |
| `CELESTE ALWAYS PASS <message>` | A passed check of an always property. |
| `CELESTE ALWAYS FAIL <message> \| <details>` | A failed check. The details are optional and free-form. |
| `CELESTE SOMETIMES <message>` | A sometimes property that was reached. |
| `CELESTE REACHABLE <message>` | A reachable property that was reached. |
| `CELESTE UNREACHABLE <message> \| <details>` | An unreachable property that was reached, which fails the run. |
| `CELESTE EVENT <fields> END` | The agent's echo of a served event. |
| `CELESTE EVENTUALLY PASS` or `CELESTE EVENTUALLY FAIL` | The result of the eventually phase. |
| `CELESTE AGENT ERROR <text>` | A failure inside the agent, which fails the attempt. |
| `CELESTE SERVICES EXIT <code>` | The project's `services` script returned. A nonzero code fails the attempt as `HarnessFailed`, which is never shrunk, since the workload ran against a site that never came up. |
| `CELESTE SETUP EXIT <code>` | The first-boot setup finished. A nonzero code fails the attempt the same way. |
| `CELESTE CHECK DONE` | The end of a check. A run without it has not been verified. |

| Line | Description |
|---|---|
| `CELESTE GUEST UP` | The init reached user space. |
| `CELESTE CPUS <n>` | The processors the workload sees. |
| `CELESTE FAULT ...` | The agent applied, healed, or could not apply a fault. |
| `CELESTE KERNEL ...` | A kernel log line the agent forwards: I/O errors, filesystem errors, and OOM kills. |
| `CELESTE QUIET` | The faults stopped and the eventually phase may begin. |
| `CELESTE STEP <text>` | One step of the workload, printed through its SDK's step call as the step starts, so a reader can place the faults between the steps the workload took. The hypervisor ignores it. |
| `CELESTE NOTE <text>` | A free-form line a workload prints through its SDK's note call, such as its own summary. |

## Vocabulary

One word has one meaning everywhere celeste is spoken: in the hypervisor's configuration and report, in this interface, in each SDK, and in an integration built on them such as celeste-django. An SDK names each call after the word in this table, in its language's case, and an integration maps its own terms onto these rather than inventing a second set.

| Word | Meaning |
|---|---|
| `seed` | The 64-bit value a run is derived from. One seed replays identically on the same hardware. |
| `run` | The boot that executes the workload, from the kernel to the power loss. |
| `check` | The boot after the power loss, which verifies what survived and ends with `CHECK DONE`. |
| `mode` | What a boot is for: `run`, `check`, or `halt`. |
| `draw` | One 64-bit word pulled from the seed's workload stream, mapped by `random`, `below`, `boolean`, and `choice`. |
| `property` | A statement the run reports on, declared before `ready` with a kind and a message. |
| `kind` | How a property is judged: `always`, `sometimes`, `reachable`, `unreachable`, or `maximize`. |
| `message` | The text that names a property, a step, or a note: one line, at most 1024 bytes, with no `\|`. |
| `details` | Free-form text after a failed check, separated by ` \| `. |
| `acknowledgement` | A write the outside world was told succeeded, named by a UUID: `ack` during the run and `present` during the check. An acknowledged identifier with no present line is a lost write. |
| `ready` | The call that starts the agent and then opens the fault window. |
| `power loss` | The end of the run, when the hypervisor cuts the machine. |
| `fault` | One act of the agent: a kill, a pause, a thread pause, a throttle, a network impairment, a clock jump, a clock slew, a disk fill, or memory pressure. |
| `event` | The block that describes one fault, served through the ports and echoed on the console. |
| `roster` | The targets and links a project's faults may name. |
| `target` | A process or service a fault acts on, found through the rules in `faults.json`. |
| `link` | A TCP port a network fault acts on. |
| `agent` | The program inside the guest that applies the faults, `python3 -m celeste_agent`. |
| `quiet` | The point where every fault has stopped and been healed. |
| `eventually` | The phase after quiet in which liveness is checked, and the verdict line that ends it. |
| `step` | One unit of the workload, narrated as it starts. |
| `note` | A free-form informational line. |
| `transcript` | The console text of one attempt, saved by the hypervisor per seed. |
| `report` | The hypervisor's JSON account of a batch: one result per seed, the roster, and the properties no seed reached. |
| `reproducer` | A `.zon` file that replays one seed's shrunk choices. |

## Minimum

A project without an SDK prints `CELESTE ACK` lines as it receives acknowledgements, writes `2` to the control port when it is ready and `1` when it wants the power loss, and prints `CELESTE PRESENT` lines and `CELESTE CHECK DONE` in the check boot. That is enough for the crash, replay, shrink, and reproducer machinery. The draws, properties, events, coverage, and guidance each add one port exchange or one line from the tables above.
