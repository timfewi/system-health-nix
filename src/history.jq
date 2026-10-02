# Merge legacy minute samples and hourly records without dropping early peaks.
def numeric_values(key): [.[] | .[key] | numbers];
def peak(key): numeric_values(key) | max;
def low(key): numeric_values(key) | min;
def total(key): numeric_values(key) | if length == 0 then null else add end;
def cpu_peak:
  max_by(.cpu_percent // -1) as $record
  | {cpu_percent: peak("cpu_percent"),
     cpu_peak_timestamp: (if $record.cpu_percent == null then null
       else $record.cpu_peak_timestamp // $record.timestamp end)};
def io_peaks:
  if all(.io == null) then null else
    [.[].io[]? | select(.device | test("^[0-9]+:[0-9]+$"))]
    | group_by(.device) | map({device: .[0].device,
        read_kib_s: peak("read_kib_s"), write_kib_s: peak("write_kib_s")}) end;
def workload_peaks:
  [.[] as $record | $record.families[]?
    | . + {cpu_peak_timestamp: (.cpu_peak_timestamp // $record.timestamp)}]
  | group_by(.family)
  | map(cpu_peak + {family: .[0].family,
      processes: peak("processes"), threads: peak("threads")});
def budget_peaks:
  [.[] as $record | $record.budgets[]?
    | . + {cpu_peak_timestamp: (.cpu_peak_timestamp // $record.timestamp),
           _timestamp: ($record.last_timestamp // $record.timestamp)}]
  | group_by(.name)
  | map(max_by(._timestamp) as $latest
    | cpu_peak + {name: .[0].name, available: any(.available == true),
        quota_cores: $latest.quota_cores, memory_high_bytes: $latest.memory_high_bytes,
        memory_max_bytes: $latest.memory_max_bytes, tasks_max: $latest.tasks_max,
        memory_bytes: peak("memory_bytes"), tasks: peak("tasks"),
        throttled_ms: total("throttled_ms"),
        high_events_delta: total("high_events_delta"), oom_kills_delta: total("oom_kills_delta"),
        io: io_peaks});

map(
  if (.schema != 1 and .schema != 2) or (.timestamp | type) != "number"
    then error("Unsupported or malformed history record") else . end
  | if .schema == 2 then
      if .kind != "hour" or (.samples | type) != "number" or .samples < 1
        or (.cpu_samples | type) != "number" or .cpu_samples < 0 or .cpu_samples > .samples
        or .samples != (.samples | floor) or .cpu_samples != (.cpu_samples | floor)
        or (.first_timestamp | type) != "number" or (.last_timestamp | type) != "number"
        or .first_timestamp > .last_timestamp
        or (.cpu_samples > 0 and ((.cpu_mean_percent | type) != "number" or (.cpu_percent | type) != "number"))
        then error("Malformed hourly history record") else . end
    else . + {samples: 1, cpu_samples: (if .cpu_percent == null then 0 else 1 end),
              cpu_mean_percent: .cpu_percent, observed_seconds: .interval_seconds,
              first_timestamp: .timestamp, last_timestamp: .timestamp}
    end
)
| group_by(.timestamp / 3600 | floor)
| map(
  max_by(.last_timestamp) as $latest
  | (total("samples")) as $samples | (total("cpu_samples")) as $cpu_samples
  | cpu_peak + {
      schema: 2, kind: "hour", timestamp: (.[0].timestamp / 3600 | floor) * 3600,
      first_timestamp: low("first_timestamp"), last_timestamp: peak("last_timestamp"),
      samples: $samples, cpu_samples: $cpu_samples, observed_seconds: total("observed_seconds"),
      cpu_mean_percent: (if $cpu_samples == 0 then null else
        (map((.cpu_mean_percent // 0) * .cpu_samples) | add) / $cpu_samples end),
      iowait_percent: peak("iowait_percent"), logical_cpus: $latest.logical_cpus,
      memory_available_mib: low("memory_available_mib"), memory_total_mib: $latest.memory_total_mib,
      swap_used_mib: peak("swap_used_mib"), hottest_c: peak("hottest_c"),
      pressure_avg10: ([.[].pressure_avg10] | {cpu: peak("cpu"), memory: peak("memory"), io: peak("io")}),
      codex: ([.[].codex] | {cli: peak("cli"), app_server: peak("app_server"),
        app_server_helper: peak("app_server_helper"), outside_budget: peak("outside_budget")}),
      failed_units: ([.[].failed_units] | {system: peak("system"), user: peak("user")}),
      alerts: ([.[].alerts[]?] | unique),
      filesystems: ([.[].filesystems[]?] | group_by(.mount)
        | map({mount: .[0].mount, used_percent: peak("used_percent")})),
      families: workload_peaks, budgets: budget_peaks
    }
)
