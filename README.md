# system-health-nix

`system-health` is a single-command monitor for a Linux host. It samples one
second of real activity — not the lifetime average `ps` reports — and attributes
CPU, memory and I/O to processes, workloads and cgroup budgets. With a sampling
timer it also keeps a private, aggregate-only history of hourly peaks.

It is written for interactive use on a workstation: no daemon, no database, no
network listener and no telemetry. Nothing leaves the machine.

```sh
system-health                     # one full snapshot
system-health --watch             # compact view, refreshed about every 4 s
system-health --json              # one structured snapshot
system-health --threads PID       # five seconds of thread CPU for one process
system-health --record            # append one aggregate sample to the history
system-health --history           # hourly peaks of the last seven days
system-health --history --json    # the same records as structured JSON
```

## What it measures

| Area | Detail |
| --- | --- |
| CPU | Interval utilisation, I/O wait and the logical CPU count |
| Memory | Available and total memory, swap in use |
| Pressure | `avg10` CPU, memory and I/O pressure |
| Processes | PID, parent, age, threads, state, controlling terminal and cgroup scope |
| Workloads | Totals per process family, including descendants |
| Budgets | CPU quota, throttling, memory and task limits, memory-pressure and OOM event deltas, per-device I/O for each monitored cgroup |
| Devices | Temperatures and filesystem usage |
| Services | Failed system and user units |

Health alerts are plain diagnostic thresholds, not hardware limits: less than
5 % memory available, CPU pressure above 10 %, memory pressure above 1 %, I/O
pressure above 5 %, any measured temperature at or above 90 C, a monitored
filesystem at or above 90 % full, failed units, and observed OOM kills.
Unavailable metrics stay unavailable — the absence of alerts is not proof that
unobserved resources are healthy.

Sampling covers processes that exist with the same PID and start time at both
endpoints, so a short-lived process can be missed. A sample takes about one
second; an unresponsive service manager can add bounded delays.

## Process attribution

The sampler reads only numeric counters from `/proc` and the cgroup filesystem.
It never reads `argv` beyond a binary name and, for coding agents, one
subcommand token. Recognised families include the common coding agents, common
browsers, Nix and this tool's own peers; anything else is reported as `other`.

A controlling terminal (`TTY=true`) shows that a session has one, not that a
person is currently using it. Process and workload CPU percentages use **100 %
for one logical CPU**, while the host CPU percentage covers all logical CPUs
together. Threads include sleeping threads, so a browser with hundreds of
threads can still be mostly idle.

## Monitored budgets

Which cgroups appear in the budgets section is deployment configuration, not
tool policy. Define them in the NixOS module (see below) or through the
environment:

```sh
SYSTEM_HEALTH_BUDGETS='nix-daemon=/system.slice/nix-daemon.service;agents=/user.slice/user-%u.slice/user@%u.service/app.slice/app-agents.slice'
SYSTEM_HEALTH_AGENT_SLICE=app-agents.slice
system-health --json
```

Entries are `name=/absolute/cgroup/path` separated by semicolons; `%u` expands
to the caller's effective UID, which selects the matching user slice. A
malformed entry is skipped instead of failing the sample, and a cgroup that does
not exist or cannot be read is reported as unavailable. `SYSTEM_HEALTH_AGENT_SLICE`
names the slice whose processes count as running inside an agent budget.

The watched mounts are configuration too. `SYSTEM_HEALTH_FILESYSTEMS` is a
space-separated list of absolute mount points, `/` by default. A path that is
missing, relative or unreadable is skipped instead of reporting usage for the
wrong mount.

The packaged command embeds whatever the deployment configured and lets the
environment override it per invocation.

## Private history

`--record` writes one aggregate sample per invocation and folds the day into at
most 24 hourly summaries. Each daily file holds:

- workload counts and CPU totals, host CPU peaks, pressure maxima
- cgroup budget peaks, throttling and event totals
- filesystem usage, the highest sensor temperature, failed-unit counts
- the timestamps at which host and workload CPU peaked

Records deliberately omit process names, PIDs, unit names, scope identifiers,
command lines, host identity and sensor labels. The state directory is mode
0700 and its files are 0600; a symlink, a foreign owner or a group- or
world-readable path is refused. Writing is locked with `flock`, and the daily
file is replaced atomically, so an interrupted run cannot truncate history. A
malformed existing record aborts the update and leaves the previous file intact.

Retention keeps seven UTC days with at most 1 MiB per daily file. Legacy
minute-level records are folded into hourly records on read or on the next
write. Keep the directory out of Git; treat even aggregate metrics as private
operational data.

## NixOS module

```nix
{
  inputs.system-health.url = "github:timfewi/system-health-nix";

  outputs =
    { nixpkgs, system-health, ... }:
    {
      nixosConfigurations.host = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          system-health.nixosModules.default
          ({ ... }: {
            systemHealth = {
              enable = true;
              # Only this account's user manager samples.
              sampler.user = "operator";
              # Processes in this slice count as budgeted agents.
              agentSlice = "app-agents.slice";
              # Watched mounts; default is "/".
              filesystems = [
                "/"
              ];
              budgets = [
                {
                  name = "nix-daemon";
                  cgroup = "/system.slice/nix-daemon.service";
                }
                {
                  name = "agents";
                  cgroup = "/user.slice/user-%u.slice/user@%u.service/app.slice/app-agents.slice";
                }
              ];
            };
          })
        ];
      };
    };
}
```

The module installs the command and, unless `systemHealth.sampler.enable` is
turned off, a user-level `system-health-sample.service` and
`system-health-sample.timer`. The sampler runs once per minute without root
privileges, limited to 10 % of one CPU, 128 MiB and 32 tasks, and stops after
20 seconds. It runs while a user manager is active and does not enable
lingering. `systemHealth.package` accepts a prebuilt variant.

## Requirements

Linux with systemd and cgroup v2, plus `procps`-style `/proc`, `pidstat`
(sysstat), `lm_sensors`, `jq`, `gawk`, coreutils, systemd tools and util-linux.
The Nix package brings its own runtime dependencies.

## Privacy

The tool reads process counters, cgroup counters, sensor readings and failed
unit names. It does not open browser profiles, other processes' environments or
credential files, and it opens no network socket. Budget paths and slice names
are deployment configuration; keep host-specific values in your own
configuration instead of forking this package.

## Development

```sh
nix develop            # pinned toolchain
just test              # CLI regression against synthetic /proc fixtures
just check             # project-check fast: format, lint, shellcheck, tests, flake eval
just verify            # project-check full: also builds the package
```

Checks are declared in `.project-checks.json`. The regressions use synthetic
`/proc` and cgroup fixtures, so they neither read nor write host state.

## License

MIT. See [LICENSE](LICENSE).