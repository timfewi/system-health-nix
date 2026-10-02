def n: if . == null then "unavailable" else ((. * 10 | round) / 10 | tostring) end;
def mib: if . == null then "unlimited / unavailable" else (. / 1048576 | n) end;
(if $ARGS.named.mode == "watch" then
"System health — \(.timestamp | todateiso8601)",
"Health thresholds: \(if (.alerts // [] | length) == 0 then "no alerts in this sample" else "\(.alerts | length) alerts; \(.alerts[0])" end)",
"CPU \(.cpu_percent | n)% of \(.logical_cpus) logical CPUs; I/O wait \(.iowait_percent | n)%",
"Memory available \(.memory_available_mib | n) MiB; swap used \(.swap_used_mib | n) MiB",
"Pressure (10s waiting %): CPU \(.pressure_avg10.cpu | n), memory \(.pressure_avg10.memory | n), I/O \(.pressure_avg10.io | n)",
"Codex: \(.codex.cli) CLI, \(.codex.app_server) app-server, \(.codex.app_server_helper) helper; outside budget \(.codex.outside_budget)",
"Failed units: system \(.failed_units.system | if . == null then "unavailable" else length end), user \(.failed_units.user | if . == null then "unavailable" else length end)",
"Busiest workloads (100% = one core):",
(.families | sort_by(-.cpu_percent)[:2][] | "  \(.family): \(.cpu_percent | n)% CPU; \(.threads) threads"),
"Budgets (CPU %, quota cores, memory MiB, max device write KiB/s):",
(.budgets[] | if .available then
  "  \(.name): \(.cpu_percent | n)% / \(.quota_cores | n); \(.memory_bytes | mib) MiB; write \([.io[]?.write_kib_s] | max | n)"
  else "  \(.name): unavailable / inactive" end),
"Top interval CPU (PID / PPID; role):",
(.processes[:([1, (($ARGS.named.rows // 24) - 21)] | max | [., 12] | min)][]
  | "  \(.cpu_percent | n)%  \(.pid) / \(.ppid)  \(.comm) [\(.role)]"),
"Hottest \(.hottest_c | n) C; filesystems: \([.filesystems[] | "\(.mount) \(.used_percent)%"] | join(", "))",
"Run system-health for all processes, limits and device I/O; --history for peaks."
else
"System health — \(.timestamp | todateiso8601)",
"Health thresholds: \(if (.alerts // [] | length) == 0 then "no alerts in this sample" else .alerts | join("; ") end)",
"CPU \(.cpu_percent | n)% of \(.logical_cpus) logical CPUs; I/O wait \(.iowait_percent | n)%",
"Memory available \(.memory_available_mib | n) / \(.memory_total_mib | n) MiB; swap used \(.swap_used_mib | n) MiB",
"Pressure (10s waiting %): CPU \(.pressure_avg10.cpu | n), memory \(.pressure_avg10.memory | n), I/O \(.pressure_avg10.io | n)",
"Codex: \(.codex.cli) CLI, \(.codex.app_server) app-server, \(.codex.app_server_helper) daemon helper; \(.codex.outside_budget) processes outside agent slice",
"Failed units: system \(.failed_units.system | if . == null then "unavailable" else length end), user \(.failed_units.user | if . == null then "unavailable" else length end)",
"\nWorkloads (100% = one CPU core; threads include sleeping threads):",
(.families | sort_by(-.cpu_percent)[] | "  \(.family): \(.cpu_percent | n)% CPU, \(.processes) processes, \(.threads) threads"),
"\nBudgets (cgroup counters; throttle and event deltas cover this sample):",
(.budgets[] | if .available then
  "  \(.name): \(.cpu_percent | n)% CPU / \(.quota_cores | if . == null then "unlimited / unavailable" else n end) cores; throttle \(.throttled_ms | n) ms; memory \(.memory_bytes | mib) / \(.memory_max_bytes | mib) MiB; tasks \(.tasks) / \(.tasks_max); pressure events +\(.high_events_delta), OOM kills +\(.oom_kills_delta)"
  else "  \(.name): unavailable / inactive" end),
"\nBudget I/O per block device (KiB/s; stacked devices can report the same I/O):",
(.budgets[] | .name as $name
  | if .io == null then "  \($name): unavailable" else .io[]
    | "  \($name) \(.device): read \(.read_kib_s | n), write \(.write_kib_s | n)" end),
"\nCodex processes (all observed, including idle; TTY means a controlling terminal):",
(.processes[] | select(.comm == "codex")
  | "  \(.pid) / \(.ppid)  \(.role)  \(.cpu_percent | n)% CPU  \(.threads) threads  state=\(.state)  TTY=\(.has_terminal)  age=\(.age_seconds | n)s  \(.scope)"),
"\nTop processes (interval CPU, PID / PPID, role, age, scope):",
(.processes[:15][] | "  \(.cpu_percent | n)%  \(.pid) / \(.ppid)  \(.comm) [\(.role)]  \(.threads) threads  \(.age_seconds | n)s  \(.scope)"),
"\nAgent scopes:",
(.scopes[] | select(.agent_scope)
  | "  \(.scope): \(.cpu_percent | n)% CPU, \(.processes) processes, \(.threads) threads"),
"\nTemperatures:",
(.temperatures[]? | "  \(.sensor): \(.celsius | n) C"),
"\nFilesystems:",
(.filesystems[] | "  \(.mount): \(.used_percent)% used"),
"\nAncestor budgets also apply. Throttle time aggregates CPU wait and can exceed elapsed time.",
"Use system-health --threads PID for busy threads; Firefox about:processes for tabs/extensions.",
"Use system-health --history for recorded peaks. OS process counts do not count conversation subagents."
end)
| if $ARGS.named.mode == "watch" and length >= ($ARGS.named.columns // 80) then
    .[:[0, (($ARGS.named.columns // 80) - 2)] | max] + "…"
  else . end
