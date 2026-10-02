# shellcheck shell=bash
# The Nix wrapper supplies the data/filter paths.
# shellcheck disable=SC2154
set -euo pipefail
export LC_ALL=C S_COLORS=never
umask 077
# Monitored budgets are deployment configuration, not tool policy: a semicolon
# separated "name=cgroup/path" list where %u expands to the effective UID. The
# packaging module supplies the defaults; the environment overrides them.
budgets=${SYSTEM_HEALTH_BUDGETS:-}
agent_slice=${SYSTEM_HEALTH_AGENT_SLICE:-}
# Monitored filesystems are deployment configuration as well.
filesystems=${SYSTEM_HEALTH_FILESYSTEMS:-/}
mode=live
json=false
pid=
for argument in "$@"; do
  if [[ "$mode" == threads && -z "$pid" ]]; then
    [[ "$argument" =~ ^[1-9][0-9]*$ ]] || { echo "Expected a positive PID." >&2; exit 2; }
    pid=$argument
    continue
  fi
  case "$argument" in
    --json) json=true ;;
    --watch|--record|--history|--threads)
      [[ "$mode" == live ]] || { echo "Choose one mode." >&2; exit 2; }
      mode=${argument#--} ;;
    --help|-h)
      echo "Usage: system-health [--json] [--watch | --record | --history | --threads PID]"
      echo "Live interval metrics; private aggregate history; five seconds of thread CPU."
      echo "Monitored budgets come from SYSTEM_HEALTH_BUDGETS; SYSTEM_HEALTH_AGENT_SLICE"
      echo "names the slice whose processes count as budgeted agents, and"
      echo "SYSTEM_HEALTH_FILESYSTEMS lists the mounts to watch."
      exit 0 ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done
if [[ "$mode" == threads ]]; then
  [[ -n "$pid" && -r "/proc/$pid/stat" && "$json" == false ]] || {
    echo "Use --threads with a readable, running PID (without --json)." >&2; exit 2;
  }
  exec pidstat -t -u -p "$pid" 1 5
fi
state_base=${XDG_STATE_HOME:-$HOME/.local/state}
[[ "$state_base" == /* ]] || { echo "XDG_STATE_HOME must be absolute." >&2; exit 2; }
state="$state_base/system-health"
private_directory() {
  [[ ! -L "$state" ]] || { echo "Refusing a symlink as the history directory." >&2; exit 1; }
  if [[ "$mode" == record ]]; then mkdir -p -- "$state"; fi
  [[ -d "$state" && "$(stat -c '%u:%a' -- "$state")" == "$(id -u):700" ]] || {
    echo "History directory must exist, be owned by the current user and have mode 0700." >&2; exit 1;
  }
}
if [[ "$mode" == history ]]; then
  if [[ ! -e "$state" && ! -L "$state" ]]; then
    echo "No history yet. The sampling timer starts after host activation and login." >&2; exit 1;
  fi
  private_directory
  shopt -s nullglob
  files=("$state"/????-??-??.jsonl)
  [[ ${#files[@]} -gt 0 ]] || { echo "No history samples yet." >&2; exit 1; }
  for file in "${files[@]}"; do
    [[ -f "$file" && ! -L "$file" && "$(stat -c '%u:%a' -- "$file")" == "$(id -u):600" ]] || {
      echo "Refusing non-private history file." >&2; exit 1;
    }
  done
  cutoff=$(date -u -d '7 days ago' +%s)
  if [[ "$json" == true ]]; then
    jq -cs -f "$history_filter" "${files[@]}" \
      | jq -c --argjson cutoff "$cutoff" '.[] | select(.last_timestamp >= $cutoff)'
  else
    jq -cs -f "$history_filter" "${files[@]}" \
      | jq -r --argjson cutoff "$cutoff" '
        def n: if . == null then "unavailable" else ((. * 10 | round) / 10 | tostring) end;
        .[] | select(.last_timestamp >= $cutoff)
        | "\((.timestamp | todateiso8601)[:13]):00 UTC  samples=\(.samples)  CPU peak=\(.cpu_percent | n)%  CPU sample mean=\(.cpu_mean_percent | n)%  available memory min=\(.memory_available_mib | n) MiB  hottest=\(.hottest_c | n) C  CPU pressure peak=\(.pressure_avg10.cpu | n)%  agent CPU peak=\([.budgets[] | select(.name == "agents") | .cpu_percent] | max | n)%"
      '
  fi
  exit
fi
temporary=$(mktemp -d)
next=
trap 'rm -rf -- "$temporary"; if [[ -n "$next" ]]; then rm -f -- "$next"; fi' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
collect_metadata() {
  awk -v ticks="$(getconf CLK_TCK)" -v uid="$(id -u)" -v budgets="$budgets" \
    -v agent_slice="$agent_slice" -f "$metadata" /proc/[0-9]*/stat
}
failed_units() {
  if timeout --foreground 2s systemctl "$@" --failed --plain --no-legend --no-pager > "$temporary/units" 2>/dev/null; then
    awk '{print $1}' "$temporary/units" | jq -Rsc 'split("\n") | map(select(length > 0))'
  else
    echo null
  fi
}
sample() {
  collect_metadata > "$temporary/before"
  pidstat -u -r -v -p ALL -o JSON 1 1 > "$temporary/activity"
  collect_metadata > "$temporary/after"
  jq --slurpfile before "$temporary/before" --slurpfile after "$temporary/after" \
    --argjson timestamp "$(date -u +%s)" -f "$snapshot_filter" "$temporary/activity" > "$temporary/sample"
  if ! sensors -j > "$temporary/sensors" 2>/dev/null; then echo '{}' > "$temporary/sensors"; fi
  for mount in $filesystems; do
    [[ "$mount" == /* && "$mount" != *..* && -d "$mount" ]] || continue
    printf '%s\n' "$mount"
  done | awk '!seen[$0]++' > "$temporary/mounts"
  # Each mount is measured on its own, so one failing path cannot hide the rest.
  : > "$temporary/disks"
  while read -r mount; do
    df -P -- "$mount" 2> /dev/null | tail -n +2 >> "$temporary/disks"
  done < "$temporary/mounts"
  awk '{gsub(/%/, "", $5); printf "{\"mount\":\"%s\",\"used_percent\":%d}\n", $6, $5}' "$temporary/disks" > "$temporary/filesystems"
  jq --slurpfile sensors "$temporary/sensors" --slurpfile filesystems "$temporary/filesystems" \
    --argjson system_units "$(failed_units)" --argjson user_units "$(failed_units --user)" \
    -f "$enrich_filter" "$temporary/sample"
}
record() {
  private_directory
  lock="$state/.lock"
  [[ ! -L "$lock" ]] || { echo "Refusing a symlink as the history lock." >&2; exit 1; }
  exec 9> "$lock"
  flock -n 9 || { echo "History sampling is already running." >&2; exit 75; }
  sample | jq -c '
    del(.processes, .scopes, .temperatures)
    | .failed_units |= with_entries(.value |= if . == null then null else length end)
  ' > "$temporary/record"
  shopt -s nullglob
  # Use the actual sample date even if collection crosses UTC midnight.
  read -r today cutoff < <(jq -r '.timestamp as $stamp
    | "\($stamp | strftime("%Y-%m-%d")) \(($stamp - 518400) | strftime("%Y-%m-%d"))"' "$temporary/record")
  for file in "$state"/????-??-??.jsonl; do
    name=${file##*/}
    [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\.jsonl$ ]] || continue
    if [[ "$name" < "$cutoff.jsonl" || "$name" > "$today.jsonl" ]]; then rm -- "$file"; fi
  done
  file="$state/$today.jsonl"
  [[ ! -L "$file" && (! -e "$file" || (-f "$file" && "$(stat -c '%u:%a' -- "$file")" == "$(id -u):600")) ]] || {
    echo "Refusing non-private history file." >&2; exit 1;
  }
  # At most 24 hourly rows per day. Preserve early peaks instead of evicting them.
  inputs=("$temporary/record")
  if [[ -f "$file" ]]; then inputs=("$file" "${inputs[@]}"); fi
  next=$(mktemp -- "$state/.next.XXXXXX")
  jq -cs -f "$history_filter" "${inputs[@]}" | jq -c '.[]' > "$next"
  (($(stat -c %s -- "$next") <= 1048576)) || {
    echo "Hourly history exceeds its daily budget; the previous history is unchanged." >&2; exit 1;
  }
  # The replacement lives in the same directory so interruption cannot truncate history.
  mv -f -- "$next" "$file"
  next=
}
if [[ "$mode" == record ]]; then record; exit; fi
while :; do
  sample > "$temporary/result"
  if [[ "$json" == true ]]; then
    jq -c . "$temporary/result"
  else
    if [[ "$mode" == watch && -t 1 ]]; then printf '\033[H\033[2J'; fi
    rows=24
    columns=80
    if [[ "$mode" == watch && -t 1 ]]; then
      dimensions=$(stty size <&1 2>/dev/null) || dimensions="24 80"
      read -r rows columns <<< "$dimensions"
      [[ "$rows" =~ ^[1-9][0-9]*$ ]] || rows=24
      [[ "$columns" =~ ^[1-9][0-9]*$ ]] || columns=80
    fi
    jq -r --arg mode "$mode" --argjson rows "$rows" --argjson columns "$columns" -f "$render_filter" "$temporary/result"
  fi
  [[ "$mode" == watch ]] || break
  sleep 4
done
