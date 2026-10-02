# Build the CLI with its jq and awk filters. Monitored budgets, the agent
# slice and the watched filesystems are deployment configuration, so they
# are baked in as overridable defaults instead of being hard-coded.
{
  lib,
  pkgs,
  agentSlice ? null,
  budgets ? [ ],
  filesystems ? [ "/" ],
}:

let
  budgetDefinitions = lib.concatMapStringsSep ";" (budget: "${budget.name}=${budget.cgroup}") budgets;
  metadata = pkgs.writeText "system-health-metadata.awk" (builtins.readFile ../src/metadata.awk);
  snapshot = pkgs.writeText "system-health-snapshot.jq" (builtins.readFile ../src/snapshot.jq);
  health = pkgs.writeText "system-health-alerts.jq" (builtins.readFile ../src/health.jq);
  history = pkgs.writeText "system-health-history.jq" (builtins.readFile ../src/history.jq);
  render = pkgs.writeText "system-health-render.jq" (builtins.readFile ../src/render.jq);
in
pkgs.writeShellApplication {
  name = "system-health";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gawk
    pkgs.glibc.bin
    pkgs.jq
    pkgs.lm_sensors
    pkgs.sysstat
    pkgs.systemd
    pkgs.util-linux
  ];
  text = ''
    # ``:-$default`` keeps a caller's environment authoritative while the
    # packaged deployment still reports its own budgets.
    SYSTEM_HEALTH_BUDGETS="''${SYSTEM_HEALTH_BUDGETS:-${lib.escapeShellArg budgetDefinitions}}"
    SYSTEM_HEALTH_AGENT_SLICE="''${SYSTEM_HEALTH_AGENT_SLICE:-${
      lib.escapeShellArg (if agentSlice == null then "" else agentSlice)
    }}"
    SYSTEM_HEALTH_FILESYSTEMS="''${SYSTEM_HEALTH_FILESYSTEMS:-${lib.escapeShellArg (lib.concatStringsSep " " filesystems)}}"
    export SYSTEM_HEALTH_BUDGETS SYSTEM_HEALTH_AGENT_SLICE SYSTEM_HEALTH_FILESYSTEMS
    metadata=${metadata}
    snapshot_filter=${snapshot}
    enrich_filter=${health}
    history_filter=${history}
    render_filter=${render}
  ''
  + builtins.readFile ../src/system-health.sh;
}
