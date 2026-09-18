{
  description = "Example NixOS configuration for Coder workspaces on AWS EC2";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # The attribute name is what the `#` in a flake reference selects:
      #   nixos-rebuild switch --flake /etc/nixos#workspace-x86_64
      attrFor = system: "workspace-${nixpkgs.lib.head (nixpkgs.lib.splitString "-" system)}";

      mkWorkspace =
        system:
        nixpkgs.lib.nixosSystem {
          modules = [
            ./hardware/ec2.nix
            ./configuration.nix
            ./modules/coder/index.nix
            {
              # Set here rather than through nixosSystem's `system` argument,
              # which some hardware-detection modules can outrank with a
              # mkDefault of their own.
              nixpkgs.hostPlatform = system;
              # So the shutdown staging hook rebuilds the same attribute this
              # machine was built from, without the template telling it.
              coder.flakeAttr = attrFor system;
            }
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
