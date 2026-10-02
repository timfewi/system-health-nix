# Project policy

## Scope

This repository is the `system-health` command: interval metrics, process and
workload attribution, monitored cgroup budgets and a private aggregate history.
It owns its CLI behaviour, its Nix package, its optional NixOS module and its
checks. It does not own host policy: which cgroups are monitored, which slice
counts as an agent budget and which account samples stay with the deployment.

## Honesty rules

- Report only what was measured. An unreadable counter is `unavailable`, never a
  guess, and the absence of alerts never means "healthy".
- Do not read or record `argv` beyond what attribution needs, and never add
  telemetry, a network listener or an exporter.
- Keep the documented privacy properties true: no process names, PIDs, unit
  names, scopes or command lines in the stored history; 0700 directories, 0600
  files, atomic replacement, bounded retention.
- Do not claim continuous monitoring. One-minute samples miss short spikes.

## Privacy

No credentials, personal data, host names, account names or deployment paths
belong in the repository, its documentation, its fixtures or its history. Budget
paths and slice names are deployment configuration; use synthetic or generic
examples. Runtime state stays out of Git.

## Working on it

- Inspect `git status --short` and the staged and unstaged diffs before editing.
  Existing work must be preserved; never reset it.
- Enter the pinned toolchain with `nix develop` (or reload direnv) before running
  Nix commands.
- Keep the sampling behaviour unchanged unless the change and its reason are
  written down in the README.

## Checks

Run the documented fast gate before reporting work:

```sh
project-check fast
```

Checks are declared in `.project-checks.json` and never run on their own.
`project-check full` additionally builds the package. Missing tools or offline
dependencies are environment blockers, not failures.

The fast gate covers Nix formatting, Statix, Deadnix, ShellCheck, the CLI
regression against synthetic `/proc` and cgroup fixtures, and flake evaluation
for both supported systems. The package check additionally exercises the
installed command's history round-trip and verifies that deployment defaults
reach the packaged script.