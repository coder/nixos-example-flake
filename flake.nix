{
  description = "Example NixOS configuration for Coder workspaces on AWS EC2";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # Per-workspace values, replaced at rebuild time by the Coder template
    # with `--override-input coder-vars path:/etc/coder/vars`. See vars/flake.nix.
    #
    # Declaring the input is what makes the override possible: Nix will only
    # override an input a flake already has. The default provides the values
    # used when this flake is evaluated outside Coder (CI, `nix build`), and
    # is never fetched when the template overrides it.
    #
    # Referenced as an absolute subflake URL rather than `path:./vars`.
    # Relative path inputs cannot always be resolved from a lock file --
    # "cannot fetch input 'path:./vars' because it uses a relative path" --
    # and they re-resolve on every evaluation, which makes Nix want to
    # rewrite the lock of a read-only remote flake on every rebuild.
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
      v = coder-vars.coderVars;

      attrFor = system: if system == "aarch64-linux" then "workspace-aarch64" else "workspace-x86_64";

      # Translate the injected values into module options. This is the only
      # place the two vocabularies meet.
      varsModule = {
        coder = {
          user = v.user;
          workspace = {
            name = v.workspaceName;
            owner = v.owner;
            ownerName = v.ownerName;
            ownerEmail = v.ownerEmail;
            accessUrl = v.accessUrl;
          };
        };

        # Left empty by default, in which case the AMI's metadata-derived
        # hostname is kept.
        networking.hostName = nixpkgs.lib.mkIf (v.hostname != "") v.hostname;
      };

      mkWorkspace =
        system:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            ./hardware/ec2.nix
            ./coder.nix
            ./configuration.nix
            varsModule
          ];
        };
    in
    {
      # The attribute name after `#` in the flake reference selects which of
      # these is applied, e.g.
      #
      #   nixos-rebuild switch --flake '<this repo>#workspace-x86_64'
      #
      # The Coder template derives the name from the instance type, so the
      # AMI architecture, `coder_agent.arch` and the attribute below can never
      # disagree. Add your own entries here and point the template's
      # `flake_attr` variable at them.
      nixosConfigurations = {
        workspace-x86_64 = mkWorkspace "x86_64-linux";
        workspace-aarch64 = mkWorkspace "aarch64-linux";
      };

      # What a downstream configuration imports. Once `coder/` is extracted
      # into its own flake this is the output that survives.
      nixosModules = {
        default = ./coder.nix;
        coder = ./coder.nix;
        ec2 = ./hardware/ec2.nix;
      };

      # `nix build .#toplevel` builds the system closure for the machine you
      # are on. Note this only covers the native architecture; the aarch64
      # configuration is verified by evaluation instead:
      #
      #   nix eval --raw \
      #     .#nixosConfigurations.workspace-aarch64.config.system.build.toplevel.drvPath
      #
      # Pure evaluation catches module and option errors, which is the class
      # of mistake that actually breaks a workspace, without needing an
      # aarch64 builder.
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: {
        toplevel = self.nixosConfigurations.${attrFor system}.config.system.build.toplevel;
        default = self.nixosConfigurations.${attrFor system}.config.system.build.toplevel;
      });
    };
}
