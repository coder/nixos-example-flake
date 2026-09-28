{
  description = "Example NixOS configuration for Coder workspaces on AWS EC2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # The agent, the workspace user and the shutdown hook. It has no inputs of
    # its own, so there is nothing to make `follows` nixpkgs.
    coder-modules.url = "github:coder/nixos-modules";
  };

  outputs =
    {
      self,
      nixpkgs,
      coder-modules,
    }:
    let
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      # What the `#` in a flake reference selects, e.g.
      #   nixos-rebuild switch --flake /etc/nixos#coder-workspace-ec2-x86_64
      # One per architecture, because a NixOS configuration is built for a
      # fixed platform; "ec2" because hardware/ec2.nix is in all of them.
      nameFor = system: "coder-workspace-ec2-${lib.head (lib.splitString "-" system)}";

      workspaceFor =
        system:
        lib.nixosSystem {
          modules = [
            ./hardware/ec2.nix
            ./configuration.nix
            coder-modules.nixosModules.default
            {
              # Not nixosSystem's `system` argument, which a hardware module
              # can outrank with an mkDefault of its own.
              nixpkgs.hostPlatform = system;
              coder.flakeAttr = nameFor system;
            }
          ];
        };

      toplevelFor = system: self.nixosConfigurations.${nameFor system}.config.system.build.toplevel;
    in
    {
      nixosConfigurations = lib.listToAttrs (
        map (system: lib.nameValuePair (nameFor system) (workspaceFor system)) systems
      );

      packages = lib.genAttrs systems (system: {
        toplevel = toplevelFor system;
        default = toplevelFor system;
      });

      # Re-exported so a configuration that started from this example keeps
      # working now that the modules live in their own flake.
      nixosModules = {
        inherit (coder-modules.nixosModules) coder default;
        ec2 = ./hardware/ec2.nix;
      };
    };
}
