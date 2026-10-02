#!/usr/bin/env bash
set -euo pipefail
repository=$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")/..")
export metadata="$repository/src/metadata.awk"
export snapshot_filter="$repository/src/snapshot.jq"
export enrich_filter="$repository/src/health.jq"
export history_filter="$repository/src/history.jq"
export render_filter="$repository/src/render.jq"
# Budgets and the agent slice are configuration; the fixtures below keep their
# own synthetic paths so nothing on the running host is read.
export SYSTEM_HEALTH_BUDGETS="agents=/user.slice/user-%u.slice/user@%u.service/app.slice/app-agents.slice;absent=/system.slice/system-health-absent-fixture.service;research=/agent.slice/agent-research.slice;research-service=/agent.slice/agent-research.slice/agent-research.service"
export SYSTEM_HEALTH_AGENT_SLICE="app-agents.slice"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
export XDG_STATE_HOME="$temporary/state"
mkdir -p "$temporary/proc/pressure" "$temporary/cgroups"
printf '20 0\n' > "$temporary/proc/uptime"
printf 'cpu 100 0 50 800 20 0 0 0 0 0\n' > "$temporary/proc/stat"
printf 'MemTotal: 8192 kB\nMemAvailable: 4096 kB\nSwapTotal: 1024 kB\nSwapFree: 512 kB\n' > "$temporary/proc/meminfo"
printf 'some avg10=1.25 avg60=2.00 avg300=3.00 total=100\n' > "$temporary/proc/pressure/cpu"
process() {
  local pid=$1 parent=$2 comm=$3
  mkdir -p "$temporary/proc/$pid"
  {
    printf '%s (%s) S %s ' "$pid" "$comm" "$parent"
    for field in {3..19}; do
      if [[ "$field" == 18 ]]; then printf '1 '; else printf '0 '; fi
    done
    printf '100 4096 2 0\n'
  } > "$temporary/proc/$pid/stat"
  printf '0::/user.slice/app-agents.slice/agent-fixture.scope\n' > "$temporary/proc/$pid/cgroup"
}
process 100 1 codex
printf 'codex\0app-server\0--listen\0PROMPT_SECRET\0' > "$temporary/proc/100/cmdline"
process 101 1 codex
printf 'codex\0app-server\0daemon\0updater\0' > "$temporary/proc/101/cmdline"
process 102 1 codex
printf 'codex\0resume\0PROMPT_SECRET\0' > "$temporary/proc/102/cmdline"
process 103 102 'odd) name'
process 104 1 .firefox-wrappe
group="$temporary/cgroups/user.slice/user-999.slice/user@999.service/app.slice/app-agents.slice"
mkdir -p "$group"
printf '200000 100000\n' > "$group/cpu.max"
printf 'usage_usec 100000\nthrottled_usec 10000\nnr_throttled 1\n' > "$group/cpu.stat"
printf 'high 2\noom_kill 0\n' > "$group/memory.events"
for field in memory.current memory.high memory.max pids.current pids.max; do printf '1024\n' > "$group/$field"; done
printf '259:0 rbytes=1024 wbytes=2048 rios=1 wios=1\n254:0 rbytes=1024 wbytes=2048 rios=1 wios=1\n' > "$group/io.stat"
research_group=/agent.slice/agent-research.slice/agent-research.service
mkdir -p "$temporary/cgroups$research_group"
printf 'usage_usec 1000\n' > "$temporary/cgroups$research_group/cpu.stat"
printf 'usage_usec 1000\n' > "$temporary/cgroups${research_group%/*}/cpu.stat"
awk -v ticks=100 -v uid=999 -v proc_root="$temporary/proc" -v cgroup_root="$temporary/cgroups" \
  -v budgets="$SYSTEM_HEALTH_BUDGETS" -v agent_slice="$SYSTEM_HEALTH_AGENT_SLICE" \
  -f "$metadata" "$temporary"/proc/[0-9]*/stat > "$temporary/before"
if rg -q PROMPT_SECRET "$temporary/before"; then exit 1; fi
jq -e 'select(.pid == 103) | .comm == "odd_ name" and .ppid == 102 and .start_ticks == 100
  and .state == "S" and .has_terminal == false and .threads == 1' "$temporary/before" > /dev/null
jq -e 'select(.type == "budget" and .name == "research") | .available' "$temporary/before" > /dev/null
# An unconfigured deployment reports no budgets and no budgeted processes, and a
# malformed entry is skipped instead of failing the sample.
awk -v ticks=100 -v uid=999 -v proc_root="$temporary/proc" -v cgroup_root="$temporary/cgroups" \
  -v budgets="" -v agent_slice="" -f "$metadata" "$temporary"/proc/[0-9]*/stat > "$temporary/unconfigured"
jq -s -e '[.[] | select(.type == "budget")] | length == 0
  and all(.[] | select(.type == "process"); .agent_scope == false)' \
  "$temporary/unconfigured" > /dev/null
awk -v ticks=100 -v uid=999 -v proc_root="$temporary/proc" -v cgroup_root="$temporary/cgroups" \
  -v budgets=";=broken;/system.slice/system-health-fixture.service;empty=;agents=/user.slice/user-%u.slice/user@%u.service/app.slice/app-agents.slice;;;" \
  -v agent_slice="absent-slice" -f "$metadata" "$temporary"/proc/[0-9]*/stat > "$temporary/malformed"
jq -s -e '[.[] | select(.type == "budget") | .name] == ["agents"]
  and all(.[] | select(.type == "process"); .agent_scope == false)' "$temporary/malformed" > /dev/null
jq -c 'if .type == "host" then .uptime += 1 | .cpu_total += 100 | .cpu_idle += 50 | .cpu_iowait += 10
  elif .type == "budget" and .name == "agents" then .usage_us += 500000 | .throttled_us += 20000
    | .io |= map(.read_bytes += 1024 | .write_bytes += 2048)
  elif .pid == 104 then .start_ticks += 1 else . end' "$temporary/before" > "$temporary/after"
cat > "$temporary/activity" <<'JSON'
{"sysstat":{"hosts":[{"number-of-cpus":8,"nodename":"DO_NOT_STORE","statistics":[{
  "task-cpu-load":[{"PID":"100","cpu":10},{"PID":"101","cpu":0},{"PID":"102","cpu":20},{"PID":"103","cpu":30},{"PID":"104","cpu":99}],
  "task-memory":[{"PID":"100","RSS":1024}],"kernel":[{"PID":"100","threads":150}]
}]}]}}
JSON
jq --slurpfile before "$temporary/before" --slurpfile after "$temporary/after" --argjson timestamp 100 \
  -f "$snapshot_filter" "$temporary/activity" > "$temporary/result"
jq -e '
  .cpu_percent == 40 and .iowait_percent == 10 and .codex.cli == 1
  and .codex.app_server == 1 and .codex.app_server_helper == 1
  and .memory_available_mib == 4 and .pressure_avg10.memory == null
  and .families[0].cpu_percent == 60 and .families[0].threads == 153
  and .scopes[0].agent_scope == true and .processes[0].pid == 103
  and ([.processes[] | select(.pid == 104)] | length == 0)
  and .budgets[0].cpu_percent == 50 and .budgets[0].quota_cores == 2
  and .budgets[0].throttled_ms == 20 and .budgets[1].cpu_percent == null
  and .budgets[0].io[0].read_kib_s == 1 and .budgets[0].io[0].write_kib_s == 2
  and (.budgets[0].io | length) == 2 and .budgets[1].io == null
  and ([.budgets[] | select(.name == "research") | .available] == [true])
' "$temporary/result" > /dev/null
if rg -q 'PROMPT_SECRET|DO_NOT_STORE' "$temporary/result"; then exit 1; fi
jq '. + {temperatures: [], filesystems: [], failed_units: {system: null, user: []}}' "$temporary/result" \
  | jq -r -f "$render_filter" > "$temporary/rendered"
rg -q 'app-server' "$temporary/rendered"
jq '. + {temperatures: [], hottest_c: null, filesystems: [], failed_units: {system: null, user: []}}' "$temporary/result" \
  | jq -r --arg mode watch --argjson rows 24 -f "$render_filter" > "$temporary/watch-view"
[[ $(wc -l < "$temporary/watch-view") -le 24 ]]
[[ $(wc -L < "$temporary/watch-view") -lt 80 ]]
rg -q 'Codex: 1 CLI, 1 app-server, 1 helper' "$temporary/watch-view"
rg -q 'Top interval CPU' "$temporary/watch-view"
# Missing counters remain unavailable, including devices appearing mid-sample.
jq -c 'if .type == "host" then .uptime = 20 else . end
  | if .type == "budget" and .name == "agents" then .io += [{device:"8:0",read_bytes:1,write_bytes:1}] else . end' \
  "$temporary/after" > "$temporary/edge-after"
jq --slurpfile before "$temporary/before" --slurpfile after "$temporary/edge-after" --argjson timestamp 100 \
  -f "$snapshot_filter" "$temporary/activity" \
  | jq -e '.interval_seconds == 0 and .budgets[0].cpu_percent == null and all(.budgets[0].io[]; .write_kib_s == null)' > /dev/null
printf '{"chip":{"sensor":{"temp1_input":91}}}\n' > "$temporary/sensors"
printf '{"mount":"/","used_percent":90}\n' > "$temporary/filesystems"
jq '.memory_available_mib = 0 | .pressure_avg10 = {cpu:11,memory:2,io:6} | .budgets[0].oom_kills_delta = 1' "$temporary/result" \
  | jq --slurpfile sensors "$temporary/sensors" --slurpfile filesystems "$temporary/filesystems" \
    --argjson system_units '["SYNTHETIC_PRIVATE_UNIT"]' --argjson user_units '["SYNTHETIC_PRIVATE_UNIT"]' -f "$enrich_filter" \
  | jq -e '.hottest_c == 91 and (.alerts | length) == 9 and all(.alerts[]; contains("SYNTHETIC_PRIVATE_UNIT") | not)' > /dev/null
jq --argjson sensors '[{}]' --argjson filesystems '[]' --argjson system_units null --argjson user_units null \
  -f "$enrich_filter" "$temporary/result" \
  | jq -e '.hottest_c == null and .alerts == [] and .failed_units.system == null' > /dev/null
# Hourly summaries retain counts, weighted means, peak times and event deltas.
jq -c '[
  (. + {timestamp:3600,cpu_percent:10,memory_available_mib:4,hottest_c:45,failed_units:{system:0,user:null}}
    | .budgets[0].throttled_ms = 2 | .budgets[0].oom_kills_delta = 0),
  (. + {timestamp:3660,cpu_percent:90,memory_available_mib:1,hottest_c:95,failed_units:{system:2,user:null}}
    | .budgets[0].throttled_ms = 20 | .budgets[0].oom_kills_delta = 1),
  (. + {timestamp:3720,cpu_percent:null,memory_available_mib:2,hottest_c:null,failed_units:{system:null,user:null}}
    | .budgets[0].throttled_ms = null | .budgets[0].oom_kills_delta = null)
] | .[]' "$temporary/result" > "$temporary/hour-input"
jq -cs -f "$history_filter" "$temporary/hour-input" > "$temporary/hour-summary"
jq -e 'length == 1 and .[0].schema == 2 and .[0].kind == "hour"
  and .[0].samples == 3 and .[0].cpu_samples == 2 and .[0].cpu_mean_percent == 50
  and .[0].cpu_percent == 90 and .[0].cpu_peak_timestamp == 3660
  and .[0].memory_available_mib == 1 and .[0].hottest_c == 95
  and .[0].first_timestamp == 3600 and .[0].last_timestamp == 3720
  and .[0].observed_seconds == 3 and .[0].failed_units.system == 2
  # Hourly budgets are grouped by name, so select them instead of by position.
  and ([.[0].budgets[] | select(.name == "agents")
    | .throttled_ms == 22 and .oom_kills_delta == 1] == [true])
  and ([.[0].budgets[] | select(.name == "absent") | .available] == [false])
' "$temporary/hour-summary" > /dev/null
# Re-folding existing hourly data must not double-count its samples or events.
jq -c '.[0]' "$temporary/hour-summary" > "$temporary/hour-folded"
jq -cs -f "$history_filter" "$temporary/hour-folded" > "$temporary/hour-again"
cmp -- "$temporary/hour-summary" "$temporary/hour-again"
jq -c '.[0] | del(.cpu_mean_percent)' "$temporary/hour-summary" > "$temporary/malformed-hour"
if jq -cs -f "$history_filter" "$temporary/malformed-hour" > /dev/null 2>&1; then exit 1; fi
jq -n -c 'range(0;1440) as $minute | {schema:1,timestamp:($minute*60),interval_seconds:1,
  cpu_percent:(if $minute == 0 then 99 else 1 end),memory_available_mib:1024,
  processes:[{cmd:"PROMPT_SECRET"}],private_identity:"DO_NOT_STORE"}' > "$temporary/day-input"
jq -cs -f "$history_filter" "$temporary/day-input" > "$temporary/day-summary"
jq -e 'length == 24 and (map(.samples) | add) == 1440
  and .[0].cpu_percent == 99 and .[0].cpu_peak_timestamp == 0
  and .[0].samples == 60 and (map(.observed_seconds) | add) == 1440' "$temporary/day-summary" > /dev/null
[[ $(stat -c %s "$temporary/day-summary") -le 1048576 ]]
if rg -q 'PROMPT_SECRET|DO_NOT_STORE' "$temporary/day-summary"; then exit 1; fi
if bash "$repository/src/system-health.sh" --threads nope 2>/dev/null; then exit 1; fi
if bash "$repository/src/system-health.sh" --watch --record 2>/dev/null; then exit 1; fi
mkdir -p "$XDG_STATE_HOME"
ln -s "$temporary" "$XDG_STATE_HOME/system-health"
if bash "$repository/src/system-health.sh" --record 2>/dev/null; then exit 1; fi
rm -- "$XDG_STATE_HOME/system-health"
# Exercise the actual CLI and round-trip its private, aggregate-only history.
bash "$repository/src/system-health.sh" --record
history="$XDG_STATE_HOME/system-health"
today=$(date -u +%F)
file="$history/$today.jsonl"
[[ $(stat -c %a "$history") == 700 && $(stat -c %a "$file") == 600 ]]
jq -e 'has("processes") == false and has("scopes") == false and has("temperatures") == false
  and (.failed_units.system == null or (.failed_units.system | type) == "number")
  and (.failed_units.user == null or (.failed_units.user | type) == "number")' "$file" > /dev/null
# Watched filesystems are configuration: a stale or relative path is skipped
# instead of reporting usage for the wrong mount. Each case uses its own state
# directory so the hourly fold cannot merge it with the recorded sample.
mkdir -p "$temporary/fs-skipped" "$temporary/fs-root"
XDG_STATE_HOME="$temporary/fs-skipped" SYSTEM_HEALTH_FILESYSTEMS="$temporary/missing relative/path" \
  bash "$repository/src/system-health.sh" --record
jq -e '.filesystems == []' "$temporary/fs-skipped/system-health/$today.jsonl" > /dev/null
XDG_STATE_HOME="$temporary/fs-root" SYSTEM_HEALTH_FILESYSTEMS="/ /" \
  bash "$repository/src/system-health.sh" --record
jq -e '.filesystems | length == 1 and .[0].mount == "/"' \
  "$temporary/fs-root/system-health/$today.jsonl" > /dev/null
bash "$repository/src/system-health.sh" --history --json | jq -e '.schema == 2 and .samples == 1' > /dev/null
bash "$repository/src/system-health.sh" --history > "$temporary/history-view"
rg -q 'CPU peak=' "$temporary/history-view"
cp -- "$file" "$history/$(date -u -d '8 days ago' +%F).jsonl"
cp -- "$file" "$history/$(date -u -d tomorrow +%F).jsonl"
awk 'NR == 1 {while (bytes <= 1048576) {print; bytes += length($0) + 1}}' "$file" > "$temporary/oversized"
cat -- "$temporary/oversized" > "$file"
# A bounded history must keep an early spike when a day exceeds its byte limit.
jq -sc --argjson timestamp "$(date -u -d "$today 00:01:00" +%s)" \
  '.[0] | .schema = 1 | .timestamp = $timestamp | .cpu_percent = 100 | .memory_available_mib = 1
    | del(.kind,.samples,.cpu_samples,.cpu_mean_percent,.cpu_peak_timestamp,.first_timestamp,.last_timestamp,.observed_seconds)' "$file" \
  > "$temporary/early-peak"
cat -- "$temporary/early-peak" "$file" > "$temporary/with-peak"
cat -- "$temporary/with-peak" > "$file"
bash "$repository/src/system-health.sh" --record
[[ $(stat -c %s "$file") -le 1048576 ]]
[[ ! -e "$history/$(date -u -d '8 days ago' +%F).jsonl" && ! -e "$history/$(date -u -d tomorrow +%F).jsonl" ]]
jq -e '.schema == 2 and .kind == "hour"' "$file" > /dev/null
jq -se 'map(.cpu_percent) | max == 100' "$file" > /dev/null
jq -se 'map(.memory_available_mib) | min == 1' "$file" > /dev/null
printf '{"schema":99,"timestamp":0}\n' > "$file"
before_digest=$(sha256sum "$file")
if bash "$repository/src/system-health.sh" --record 2>/dev/null; then exit 1; fi
[[ $(sha256sum "$file") == "$before_digest" ]]
if compgen -G "$history/.next.*" > /dev/null; then exit 1; fi
chmod 644 "$file"
if bash "$repository/src/system-health.sh" --history 2>/dev/null; then exit 1; fi
echo "System health counters, attribution, alerts, hourly peaks, private history and atomic retention checks passed."
