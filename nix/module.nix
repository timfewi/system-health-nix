# NixOS integration: the packaged CLI plus an optional user-level sampling
# timer for the private hourly history. Enabling the module installs the
# command; the sampler is opt-in through `systemHealth.sampler.enable`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.systemHealth) sampler;
  cfg = config.systemHealth;
in
{
  options.systemHealth = {
    enable = lib.mkEnableOption "the system-health monitor";

    package = lib.mkOption {
      type = lib.types.package;
      default = import ./package.nix {
        inherit lib pkgs;
        inherit (cfg) budgets agentSlice filesystems;
      };
      defaultText = lib.literalExpression "import ./package.nix { inherit pkgs; … }";
      description = "The `system-health` command. Override to build a variant.";
    };

    # Which cgroups the budgets section watches. Deployment policy decides the
    # names; an absent cgroup is reported as unavailable rather than omitted.
    budgets = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              example = "agents";
              description = "Label shown in the budgets section.";
            };
            cgroup = lib.mkOption {
              type = lib.types.str;
              example = "/system.slice/nix-daemon.service";
              description = ''
                Absolute cgroup path. The token `%u` expands to the effective
                UID of the caller, which selects the matching user slice.
              '';
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          name = "nix-daemon";
          cgroup = "/system.slice/nix-daemon.service";
        }
      ];
      description = "Monitored cgroup budgets.";
    };

    # Which mounts appear in the filesystems section. Unreadable or relative
    # entries are skipped; a missing mount is simply not reported.
    filesystems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "/"
      ];
      example = [
        "/"
        "/var/lib/data"
      ];
      description = "Mount points whose usage is reported and threshold-checked.";
    };

    # Processes inside this slice are marked as running inside an agent budget.
    agentSlice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "app-agents.slice";
      description = ''
        Slice name whose processes count as budgeted agent workloads. `null`
        marks no process as budgeted.
      '';
    };

    sampler = {
      enable = lib.mkEnableOption "the private hourly history sampler" // {
        default = true;
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "operator";
        description = ''
          Account whose user manager samples. An empty name lets every user
          session sample on its own; a name also restricts both units to it.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        environment.systemPackages = [ cfg.package ];

        assertions = [
          {
            assertion = lib.all (
              budget: lib.hasPrefix "/" budget.cgroup && !(lib.hasPrefix "/" budget.name)
            ) cfg.budgets;
            message = "systemHealth.budgets entries need a plain name and an absolute cgroup path.";
          }
          {
            assertion = cfg.filesystems != [ ] && lib.all (mount: lib.hasPrefix "/" mount) cfg.filesystems;
            message = "systemHealth.filesystems needs at least one absolute mount point.";
          }
        ];
      }
      (lib.mkIf sampler.enable {
        systemd.packages = [
          # A packaged base unit plus a named drop-in takes precedence over
          # service.d's general application limits; a plain generated fragment
          # would not.
          (pkgs.writeTextFile {
            name = "system-health-base-unit";
            destination = "/share/systemd/user/system-health-sample.service";
            text = ''
              [Unit]
              Description=Private aggregate system health history
              [Service]
              Type=oneshot
            '';
          })
        ];
        systemd.user = {
          services.system-health-sample = {
            overrideStrategy = "asDropin";
            description = "Private aggregate system health history";
            unitConfig = lib.optionalAttrs (sampler.user != "") {
              ConditionUser = sampler.user;
            };
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${cfg.package}/bin/system-health --record";
              UMask = "0077";
              Nice = 10;
              CPUQuota = "10%";
              MemoryHigh = "64M";
              MemoryMax = "128M";
              MemorySwapMax = 0;
              OOMPolicy = "kill";
              TasksMax = 32;
              TimeoutStartSec = "20s";
              NoNewPrivileges = true;
              RestrictAddressFamilies = [ "AF_UNIX" ];
            };
            # Fix the sampler's path independently of interactive XDG overrides.
            environment.XDG_STATE_HOME = "%h/.local/state";
          };
          timers.system-health-sample = {
            description = "Sample system health once per minute";
            unitConfig = lib.optionalAttrs (sampler.user != "") {
              ConditionUser = sampler.user;
            };
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnStartupSec = "1min";
              OnUnitActiveSec = "1min";
              AccuracySec = "10s";
            };
          };
        };
      })
    ]
  );
}
