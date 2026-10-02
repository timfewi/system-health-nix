# Flake checks.
#
# `cli` runs the source regression against synthetic /proc and cgroup fixtures.
# `package` exercises the installed command, including its private history
# round-trip, and checks that deployment defaults reach the packaged script.
# `module` evaluates the NixOS integration. No check reads or writes host state.
{
  nixpkgs,
  pkgs,
  system,
  ...
}:
let
  inherit (nixpkgs) lib;
  system-health = import ../nix/package.nix { inherit lib pkgs; };
  budgeted = import ../nix/package.nix {
    inherit lib pkgs;
    agentSlice = "app-agents.slice";
    budgets = [
      {
        name = "nix-daemon";
        cgroup = "/system.slice/nix-daemon.service";
      }
    ];
  };
  configured = import ../nix/package.nix {
    inherit lib pkgs;
    filesystems = [
      "/"
      "/var/lib/data"
    ];
  };
in
{
  cli =
    pkgs.runCommand "system-health-cli"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.gawk
          pkgs.glibc.bin
          pkgs.jq
          pkgs.ripgrep
          pkgs.sysstat
          pkgs.util-linux
        ];
      }
      ''
        cp -R -- ${../.} ./tree
        chmod -R u+w ./tree
        cd ./tree
        bash tests/system-health.sh
        touch $out
      '';

  package =
    pkgs.runCommand "system-health-package"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
          system-health
        ];
      }
      ''
        export XDG_STATE_HOME="$TMPDIR/state"
        system-health --record
        today=$(date -u +%F)
        test "$(stat -c %a "$XDG_STATE_HOME/system-health")" = 700
        test "$(stat -c %a "$XDG_STATE_HOME/system-health/$today.jsonl")" = 600
        # Aggregate-only records: no process names, PIDs, scopes or temperatures.
        jq -e 'has("processes") == false and has("scopes") == false
          and has("temperatures") == false and .schema == 2' \
          "$XDG_STATE_HOME/system-health/$today.jsonl"
        system-health --history --json | jq -e '.schema == 2 and .samples == 1'
        touch $out
      '';

  # Without configuration the packaged command reports no budget and no slice.
  defaults =
    pkgs.runCommand "system-health-defaults"
      {
        nativeBuildInputs = [
          pkgs.bash
          pkgs.gnugrep
          system-health
        ];
      }
      ''
        grep -q 'SYSTEM_HEALTH_BUDGETS:-' ${system-health}/bin/system-health
        grep -q 'SYSTEM_HEALTH_AGENT_SLICE:-' ${system-health}/bin/system-health
        grep -q 'SYSTEM_HEALTH_FILESYSTEMS:-/' ${system-health}/bin/system-health
        # Configured defaults reach the script, and every setting keeps its
        # overridable ``:-`` form for a single invocation.
        grep -q 'nix-daemon=/system.slice/nix-daemon.service' ${budgeted}/bin/system-health
        grep -q 'app-agents.slice' ${budgeted}/bin/system-health
        grep -q '/var/lib/data' ${configured}/bin/system-health
        for variable in BUDGETS AGENT_SLICE FILESYSTEMS; do
          grep -q "SYSTEM_HEALTH_$variable:-" ${configured}/bin/system-health
        done
        touch $out
      '';

  module =
    let
      evaluated = import (nixpkgs + "/nixos/lib/eval-config.nix") {
        inherit system;
        modules = [
          ../nix/module.nix
          {
            nixpkgs.hostPlatform = system;
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "none";
              fsType = "tmpfs";
            };
            system.stateVersion = "25.11";
            systemHealth = {
              enable = true;
              agentSlice = "app-agents.slice";
              sampler.user = "operator";
              budgets = [
                {
                  name = "nix-daemon";
                  cgroup = "/system.slice/nix-daemon.service";
                }
              ];
            };
          }
        ];
      };
      inherit (evaluated) config;
      sampler = config.systemd.user.services.system-health-sample;
      timer = config.systemd.user.timers.system-health-sample;
    in
    assert config.systemHealth.enable;
    assert config.systemHealth.agentSlice == "app-agents.slice";
    assert lib.length config.systemHealth.budgets == 1;
    assert config.systemHealth.filesystems == [ "/" ];
    assert lib.any (
      package: (package.meta.mainProgram or "") == "system-health"
    ) config.environment.systemPackages;
    assert sampler.overrideStrategy == "asDropin";
    assert sampler.unitConfig.ConditionUser == "operator";
    assert sampler.serviceConfig.Type == "oneshot";
    assert sampler.serviceConfig.UMask == "0077";
    assert sampler.serviceConfig.CPUQuota == "10%";
    assert sampler.serviceConfig.MemoryMax == "128M";
    assert sampler.serviceConfig.TasksMax == 32;
    assert sampler.serviceConfig.NoNewPrivileges;
    assert timer.unitConfig.ConditionUser == sampler.unitConfig.ConditionUser;
    assert timer.timerConfig.OnUnitActiveSec == "1min";
    assert lib.elem "timers.target" timer.wantedBy;
    # The module's own validation accepts the declared budget shape.
    assert lib.all (assertion: assertion.assertion) config.assertions;
    pkgs.runCommand "system-health-module" { } "touch $out";
}
