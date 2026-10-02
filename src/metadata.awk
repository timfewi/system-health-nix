# Read only numeric procfs/cgroup counters and process identity. Never emit argv.
function read_line(path, value) {
    value = ""
    getline value < path
    close(path)
    return value
}
function quote(value) {
    gsub(/[^[:alnum:]_.:@\/ -]/, "_", value)
    return "\"" value "\""
}
function number(value) { return value ~ /^[0-9]+$/ ? value : "null" }
function codex_role(path, separator, executable, subcommand, option) {
    separator = RS; RS = "\x00"
    getline executable < path
    getline subcommand < path
    if (subcommand == "app-server") getline option < path
    close(path); RS = separator
    if (subcommand == "app-server") return option == "daemon" ? "app-server-helper" : "app-server"
    return subcommand == "mcp-server" ? "mcp-server" : "cli"
}
function counter(path, key, line, fields) {
    while ((getline line < path) > 0) {
        split(line, fields, " ")
        if (fields[1] == key) { close(path); return fields[2] }
    }
    close(path)
    return ""
}
function pressure(resource, line, fields) {
    line = read_line(proc_root "/pressure/" resource)
    split(line, fields, " ")
    sub(/^avg10=/, "", fields[2])
    return fields[2] ~ /^[0-9.]+$/ ? fields[2] : "null"
}
function io(path, line, fields, pair, read_status, result, separator, i, read_bytes, write_bytes) {
    result = "["; separator = ""
    while ((read_status = (getline line < path)) > 0) {
        split(line, fields, " ")
        if (fields[1] !~ /^[0-9]+:[0-9]+$/) continue
        read_bytes = ""; write_bytes = ""
        for (i = 2; i <= length(fields); i++) {
            split(fields[i], pair, "=")
            if (pair[1] == "rbytes") read_bytes = pair[2]
            if (pair[1] == "wbytes") write_bytes = pair[2]
        }
        result = result separator "{\"device\":" quote(fields[1]) ",\"read_bytes\":" number(read_bytes) ",\"write_bytes\":" number(write_bytes) "}"
        separator = ","
    }
    close(path)
    return read_status < 0 ? "null" : result "]"
}
function group(name, path, quota) {
    split(read_line(path "/cpu.max"), quota, " ")
    printf "{\"type\":\"budget\",\"name\":%s,\"available\":%s", quote(name), read_line(path "/cpu.stat") != "" ? "true" : "false"
    printf ",\"usage_us\":%s,\"throttled_us\":%s,\"throttled_periods\":%s", number(counter(path "/cpu.stat", "usage_usec")), number(counter(path "/cpu.stat", "throttled_usec")), number(counter(path "/cpu.stat", "nr_throttled"))
    printf ",\"quota_us\":%s,\"period_us\":%s", number(quota[1]), number(quota[2])
    printf ",\"memory_bytes\":%s,\"memory_high_bytes\":%s,\"memory_max_bytes\":%s", number(read_line(path "/memory.current")), number(read_line(path "/memory.high")), number(read_line(path "/memory.max"))
    printf ",\"tasks\":%s,\"tasks_max\":%s", number(read_line(path "/pids.current")), number(read_line(path "/pids.max"))
    printf ",\"io\":%s", io(path "/io.stat")
    printf ",\"high_events\":%s,\"oom_kills\":%s}\n", number(counter(path "/memory.events", "high")), number(counter(path "/memory.events", "oom_kill"))
}
function process(path, line, fields, pid, name, start, parent, scope, bounded, role, family, state, threads, has_terminal) {
    line = read_line(path)
    if (!match(line, /^([0-9]+) \((.*)\) (.*)$/, fields)) return
    pid = fields[1]; name = fields[2]
    split(fields[3], fields, " ")
    parent = fields[2]; start = fields[20]
    state = fields[1]; threads = fields[18]; has_terminal = fields[5] ~ /^-?[0-9]+$/ ? (fields[5] != 0 ? "true" : "false") : "null"
    scope = read_line(proc_root "/" pid "/cgroup")
    bounded = agent_slice != "" && index(scope, "/" agent_slice "/") > 0 ? "true" : "false"
    sub(/^.*\//, "", scope)
    role = "process"; family = "other"
    if (name == "codex") {
        family = "codex"; role = "cli"
        # Read only the subcommand and, for app-server, the following token.
        role = codex_role(proc_root "/" pid "/cmdline")
    } else if (name ~ /^\.?claude/) { family = "claude"; role = "cli" }
    else if (name ~ /^\.?opencode/) { family = "opencode"; role = "cli" }
    else if (name ~ /^\.?firefox/) { family = "firefox"; role = "browser" }
    else if (name ~ /^host-observer/) family = "observer"
    else if (name == "nix-daemon") family = "nix"
    printf "{\"type\":\"process\",\"pid\":%d,\"ppid\":%d,\"start_ticks\":%d,\"age_seconds\":%.1f", pid, parent, start, uptime - start / ticks
    printf ",\"state\":%s,\"threads\":%s,\"has_terminal\":%s", quote(state), number(threads), has_terminal
    printf ",\"comm\":%s,\"scope\":%s,\"agent_scope\":%s,\"family\":%s,\"role\":%s}\n", quote(name), quote(scope), bounded, quote(family), quote(role)
}
BEGIN {
    if (proc_root == "") proc_root = "/proc"
    if (cgroup_root == "") cgroup_root = "/sys/fs/cgroup"
    uptime = read_line(proc_root "/uptime") + 0
    split(read_line(proc_root "/stat"), cpu, " ")
    # Guest time is already included in user/nice; omit guest columns.
    for (i = 2; i <= 9; i++) total += cpu[i]
    printf "{\"type\":\"host\",\"uptime\":%.2f,\"cpu_total\":%d,\"cpu_idle\":%d,\"cpu_iowait\":%d", uptime, total, cpu[5], cpu[6]
    printf ",\"memory_total_kib\":%s,\"memory_available_kib\":%s", number(counter(proc_root "/meminfo", "MemTotal:")), number(counter(proc_root "/meminfo", "MemAvailable:"))
    printf ",\"swap_total_kib\":%s,\"swap_free_kib\":%s", number(counter(proc_root "/meminfo", "SwapTotal:")), number(counter(proc_root "/meminfo", "SwapFree:"))
    printf ",\"pressure\":{\"cpu\":%s,\"memory\":%s,\"io\":%s}}\n", pressure("cpu"), pressure("memory"), pressure("io")
    # Monitored budgets are configuration: "name=cgroup/path" entries separated
    # by semicolons, with %u standing for the effective UID. An unreadable group
    # is reported as unavailable instead of failing the sample.
    budget_count = split(budgets, definitions, ";")
    for (budget_index = 1; budget_index <= budget_count; budget_index++) {
        if (definitions[budget_index] == "") continue
        split(definitions[budget_index], definition, "=")
        if (definition[1] == "" || definition[2] == "") continue
        cgroup = cgroup_root definition[2]
        gsub(/%u/, uid, cgroup)
        group(definition[1], cgroup)
    }
    for (i = 1; i < ARGC; i++) process(ARGV[i])
    exit
}
