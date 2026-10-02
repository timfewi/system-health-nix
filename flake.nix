{
  description = "Interval system health, process attribution and private hourly history";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7a0f122f5090cf4c2ade2a13a0e229d4e19ba71f";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      forPackages =
        function:
        forAllSystems (
          system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          function { inherit lib pkgs system; }
        );
      systemHealth = pkgs: import ./nix/package.nix { inherit lib pkgs; };
    in
    {
      packages = forPackages (
        { pkgs, ... }:
        let
          system-health = systemHealth pkgs;
        in
        {
          inherit system-health;
          default = system-health;
        }
      );

      # Sampling budgets, the agent slice name and the sampler account stay with
      # the deployment; this module owns the package and the unit shape.
      nixosModules.default =
        {
          pkgs,
          ...
        }:
        import ./nix/module.nix {
          inherit pkgs;
          systemHealth = systemHealth pkgs;
        };

      devShells = forPackages (
        { pkgs, ... }:
        {
          default = pkgs.mkShellNoCC {
            packages = [
              pkgs.bash
              pkgs.coreutils
              pkgs.deadnix
              pkgs.gawk
              pkgs.gnused
              pkgs.jq
              pkgs.nix
              pkgs.nixfmt-tree
              pkgs.ripgrep
              pkgs.shellcheck
              pkgs.statix
              pkgs.sysstat
              pkgs.util-linux
            ];
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./tests { inherit nixpkgs pkgs system; }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
