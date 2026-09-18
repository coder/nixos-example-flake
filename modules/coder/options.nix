# Option declarations for the Coder workspace integration.
#
# This directory (`coder/`) is intended to be extracted into a standalone
# flake (`github:coder/nixos-coder`) so that downstream users only have to add
# one input and one import to their own configuration. Keep it free of
# anything specific to this example repository.
#
# In particular: no `nix.*` settings belong here. Nix configuration is the
# machine owner's business and lives in `configuration.nix`.
{ lib, ... }:
{
  options.coder = {
    enable = lib.mkOption {
      description = "Whether to declare the Coder agent and workspace user.";
      type = lib.types.bool;
      default = true;
    };

    user = lib.mkOption {
      description = ''
        Username of the workspace user. The Coder agent runs as this user and
        it owns the home directory that editors and terminals land in.
      '';
      type = lib.types.str;
      default = "coder";
    };

    uid = lib.mkOption {
      description = ''
        UID for the workspace user, or null to let NixOS allocate one.

        Null by default because a pinned UID collides in practice: the EC2
        images enable `amazon-ssm-agent`, whose `ssm-user` is allocated the
        first free UID (1000) without regard for statically assigned ones,
        so pinning the workspace user to 1000 produces two accounts sharing
        it -- which silently gives an SSM session the workspace user's
        identity.

        Worth setting if you attach a home volume that has to keep stable
        file ownership across instances. In that case make sure nothing else
        on the machine claims the same UID.
      '';
      type = lib.types.nullOr lib.types.int;
      default = null;
    };

    extraGroups = lib.mkOption {
      description = ''
        Supplementary groups for the workspace user. `wheel` is required:
        `coder_script` runs as this user and needs `sudo nixos-rebuild`.
      '';
      type = lib.types.listOf lib.types.str;
      default = [ "wheel" ];
    };



    runtimeDir = lib.mkOption {
      description = ''
        Directory where the Coder template's boot script drops the agent
        token and init script. Must be on a tmpfs so that nothing survives a
        reboot: the token is rotated on every workspace start, and a stale
        copy on disk is a liability rather than a convenience.
      '';
      type = lib.types.path;
      default = "/run/coder";
    };

    logDir = lib.mkOption {
      description = ''
        Directory for `nixos-rebuild` transcripts. Coder caps agent logs at
        1 MiB per agent, so the workspace UI only ever sees a digest; this is
        where the full output is kept.
      '';
      type = lib.types.path;
      default = "/var/log/coder-nixos";
    };

    stateDir = lib.mkOption {
      description = "Directory for rebuild bookkeeping (flake revision marker, lock file).";
      type = lib.types.path;
      default = "/var/lib/coder-nixos";
    };

    flakeDir = lib.mkOption {
      description = ''
        Where the workspace's NixOS configuration is checked out. The template
        syncs it and builds from it, which is what makes a bare
        `sudo nixos-rebuild switch` work: nixos-rebuild looks for
        /etc/nixos/flake.nix on its own.
      '';
      type = lib.types.path;
      default = "/etc/nixos";
    };

    flakeAttr = lib.mkOption {
      description = ''
        The `nixosConfigurations` attribute this machine is built from, used
        by the shutdown staging hook. Must match what the template applies.
      '';
      type = lib.types.str;
      default = "workspace-x86_64";
    };

    stageOnShutdown = {
      enable = lib.mkOption {
        description = ''
          Build the next generation during shutdown so the next start boots it
          rather than building it.

          Best effort, and never a correctness mechanism: the boot path
          rebuilds whenever the configuration changed. Set false if you would
          rather no stop was ever delayed.
        '';
        type = lib.types.bool;
        default = true;
      };

      timeoutSec = lib.mkOption {
        description = ''
          How long systemd waits for the staging build. EC2 does not document
          how long it tolerates a graceful shutdown, so this is an upper bound
          on our side, not a guarantee.
        '';
        type = lib.types.int;
        default = 300;
      };
    };

    agent = {
      extraPackages = lib.mkOption {
        description = ''
          Extra packages to place on the agent's `PATH`. Anything a
          `coder_script` or a terminal session needs should go here or in
          `environment.systemPackages`.
        '';
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
    };
  };
}
