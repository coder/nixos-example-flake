{
  description = "Example NixOS configuration for Coder workspaces on AWS EC2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Per-workspace values. The Coder template replaces this at rebuild time
    # with `--override-input coder-vars path:/etc/coder/vars`; the default
    # below is what you get evaluating this flake by hand. Only
    # modules/coder/vars.nix knows what the keys mean.
    #
    # An absolute subflake URL rather than `path:./vars`: relative path inputs
    # cannot always be resolved from a lock file and re-resolve on every
    # evaluation, which makes Nix try to rewrite the lock of a read-only
    # remote flake on every rebuild. Point this at your own fork.
    coder-vars = {
      url = "github:coder/nixos-example-flake?dir=vars";
      flake = true;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      coder-vars,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # Attribute names are what the `#` in a flake reference selects, e.g.
      #   nixos-rebuild switch --flake '<this repo>#workspace-x86_64'
      attrFor = system: "workspace-${nixpkgs.lib.head (nixpkgs.lib.splitString "-" system)}";

      mkWorkspace =
        system:
        nixpkgs.lib.nixosSystem {
          specialArgs = { inherit (coder-vars) coderVars; };
          modules = [
            ./hardware/ec2.nix
            ./configuration.nix
            ./modules/coder/index.nix
            # Set explicitly rather than through nixosSystem's `system`
            # argument: a nixos-facter report sets `nixpkgs.hostPlatform` with
            # mkDefault, which outranks the value derived from that argument
            # and would silently build the wrong architecture.
            { nixpkgs.hostPlatform = system; }
          ];
        };
    in
    {
      nixosConfigurations = nixpkgs.lib.listToAttrs (
        map (system: {
          name = attrFor system;
          value = mkWorkspace system;
        }) systems
      );

      # `nix build .#toplevel` builds the closure for the machine you are on.
      # The other architecture is verified by evaluation instead, which catches
      # module and option errors without needing a cross builder:
      #
      #   nix eval --raw \
      #     .#nixosConfigurations.workspace-aarch64.config.system.build.toplevel.drvPath
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          toplevel = self.nixosConfigurations.${attrFor system}.config.system.build.toplevel;
        in
        {
          inherit toplevel;
          default = toplevel;
        }
      );

      nixosModules = {
        coder = ./modules/coder/index.nix;
        ec2 = ./hardware/ec2.nix;
        default = ./modules/coder/index.nix;
      };
    };
}
