{
  description = "Example NixOS configuration for Coder workspaces on AWS EC2 and Incus";

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

      # Each platform's hardware module is the only thing that differs between
      # hosts; configuration.nix is shared.
      platforms = {
        ec2 = ./hardware/ec2.nix;
        incus = ./hardware/incus.nix;
      };

      # What the `#` in a flake reference selects, e.g.
      #   nixos-rebuild switch --flake /etc/nixos#coder-workspace-ec2-x86_64
      # One per platform and architecture, because a NixOS configuration is
      # built for a fixed platform.
      nameFor = platform: system: "coder-workspace-${platform}-${lib.head (lib.splitString "-" system)}";

      workspaceFor =
        platform: system:
        lib.nixosSystem {
          modules = [
            platforms.${platform}
            ./configuration.nix
            coder-modules.nixosModules.default
            {
              # Not nixosSystem's `system` argument, which a hardware module
              # can outrank with an mkDefault of its own.
              nixpkgs.hostPlatform = system;
              coder.flakeAttr = nameFor platform system;
            }
          ];
        };

      hosts = lib.cartesianProduct {
        platform = lib.attrNames platforms;
        system = systems;
      };

      toplevelFor = system: self.nixosConfigurations.${nameFor "ec2" system}.config.system.build.toplevel;
    in
    {
      nixosConfigurations = lib.listToAttrs (
        map (
          { platform, system }: lib.nameValuePair (nameFor platform system) (workspaceFor platform system)
        ) hosts
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
        incus = ./hardware/incus.nix;
      };
    };
}
