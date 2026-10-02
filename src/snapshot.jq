def index_pid: map({key: (.pid | tostring), value: .}) | from_entries;
def total(field): map(.[field] // 0) | add // 0;
def family(metadata; pid; depth):
  metadata[pid | tostring] as $p
  | if $p == null or depth >= 32 then "other"
    elif $p.family != "other" then $p.family
    else family(metadata; $p.ppid; depth + 1) end;
def delta(after; before):
  if after == null or before == null then null else [0, after - before] | max end;
def io_rate(after; before; elapsed):
  delta(after; before) as $value
  | if elapsed <= 0 or $value == null then null else $value / (elapsed * 1024) end;

($before[] | select(.type == "host")) as $a
| ($after[] | select(.type == "host")) as $b
| ([$before[] | select(.type == "process")] | index_pid) as $old
| ([$after[] | select(.type == "process")] | index_pid) as $metadata
| ($b.uptime - $a.uptime) as $elapsed
| ($b.cpu_total - $a.cpu_total) as $cpu_delta
| .sysstat.hosts[0] as $sample
| $sample.statistics[0] as $stats
| ($stats["task-memory"] // [] | map({key: .PID, value: .RSS}) | from_entries) as $rss
| ($stats.kernel // [] | map({key: .PID, value: .threads}) | from_entries) as $threads
| [$stats["task-cpu-load"][]?
   | .PID as $pid | $metadata[$pid] as $p
   | select($p != null and $old[$pid].start_ticks == $p.start_ticks)
   | $p + {cpu_percent: .cpu, rss_kib: $rss[$pid], threads: ($threads[$pid] // $p.threads),
           family: family($metadata; $p.pid; 0)}
   | del(.type, .start_ticks)] as $processes
| {
    schema: 1, timestamp: $timestamp, interval_seconds: $elapsed,
    logical_cpus: $sample["number-of-cpus"],
    cpu_percent: (if $cpu_delta > 0 then
      100 * (1 - (($b.cpu_idle - $a.cpu_idle) + ($b.cpu_iowait - $a.cpu_iowait)) / $cpu_delta)
      else null end),
    iowait_percent: (if $cpu_delta > 0 then 100 * ($b.cpu_iowait - $a.cpu_iowait) / $cpu_delta else null end),
    memory_available_mib: ($b.memory_available_kib / 1024),
    memory_total_mib: ($b.memory_total_kib / 1024),
    swap_used_mib: (($b.swap_total_kib - $b.swap_free_kib) / 1024),
    pressure_avg10: $b.pressure,
    codex: {cli: ([$processes[] | select(.family == "codex" and .role == "cli")] | length),
            app_server: ([$processes[] | select(.role == "app-server")] | length),
            app_server_helper: ([$processes[] | select(.role == "app-server-helper")] | length),
            outside_budget: ([$processes[] | select(.family == "codex" and .agent_scope == false)] | length)},
    families: ($processes | group_by(.family) | map({family: .[0].family,
      cpu_percent: total("cpu_percent"), processes: length, threads: total("threads")})),
    scopes: ($processes | group_by(.scope) | map({scope: .[0].scope,
      agent_scope: any(.agent_scope), cpu_percent: total("cpu_percent"), processes: length, threads: total("threads")})),
    budgets: [$after[] | select(.type == "budget") | . as $end
      | ($before[] | select(.type == "budget" and .name == $end.name)) as $start
      | . + {
          cpu_percent: (if $elapsed > 0 and .usage_us != null and $start.usage_us != null
            then delta(.usage_us; $start.usage_us) / ($elapsed * 10000) else null end),
          quota_cores: (if .quota_us != null and .period_us > 0 then .quota_us / .period_us else null end),
          throttled_ms: (delta(.throttled_us; $start.throttled_us) | if . == null then null else . / 1000 end),
          high_events_delta: delta(.high_events; $start.high_events),
          oom_kills_delta: delta(.oom_kills; $start.oom_kills),
          io: (if .io == null then null else [.io[] | . as $device
            | ([($start.io // [])[] | select(.device == $device.device)] | first) as $previous
            | {device: .device,
               read_kib_s: io_rate(.read_bytes; $previous.read_bytes; $elapsed),
               write_kib_s: io_rate(.write_bytes; $previous.write_bytes; $elapsed)}] end)}
      | del(.type, .usage_us, .throttled_us, .quota_us, .period_us)],
    processes: ($processes | sort_by(-.cpu_percent))
  }
