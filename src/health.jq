. + {failed_units: {system: $system_units, user: $user_units}, filesystems: $filesystems,
  temperatures: [$sensors[0] | to_entries[] | .value | objects | to_entries[]
    | select(.value | type == "object") | .key as $label | .value | to_entries[]
    | select(.key | test("^temp[0-9]+_input$")) | {sensor: $label, celsius: .value}]}
| . + {hottest_c: ([.temperatures[].celsius] | max)}
| . + {alerts: [
    if .memory_total_mib > 0 and .memory_available_mib / .memory_total_mib < 0.05 then "Less than 5% memory available" else empty end,
    if .pressure_avg10.cpu > 10 then "CPU pressure exceeds 10%" else empty end,
    if .pressure_avg10.memory > 1 then "Memory pressure exceeds 1%" else empty end,
    if .pressure_avg10.io > 5 then "I/O pressure exceeds 5%" else empty end,
    if .hottest_c >= 90 then "A temperature sensor is at least 90 C" else empty end,
    if any(.filesystems[]; .used_percent >= 90) then "A monitored filesystem is at least 90% full" else empty end,
    if any(.budgets[]; .oom_kills_delta > 0) then "A monitored cgroup had an OOM kill during this sample" else empty end,
    if (.failed_units.system // [] | length) > 0 then "System units have failed" else empty end,
    if (.failed_units.user // [] | length) > 0 then "User units have failed" else empty end
  ]}
