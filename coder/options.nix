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
        Fixed UID for the workspace user. Pinning it keeps file ownership
        stable if a home volume is ever detached and reattached to a new
        instance.
      '';
      type = lib.types.int;
      default = 1000;
    };

    extraGroups = lib.mkOption {
      description = ''
        Supplementary groups for the workspace user. `wheel` is required:
        `coder_script` runs as this user and needs `sudo nixos-rebuild`.
      '';
      type = lib.types.listOf lib.types.str;
      default = [ "wheel" ];
    };

    shell = lib.mkOption {
      description = "Login shell for the workspace user.";
      type = lib.types.nullOr lib.types.package;
      default = null;
    };

    trustUser = lib.mkOption {
      description = ''
        Whether the workspace user should be a Nix trusted user.

        Declared here so that the option surface is complete, but
        deliberately *not* acted on by this module: granting Nix trust
        effectively grants root, so it must be an explicit choice in the
        machine configuration rather than something importing the Coder
        module turns on silently.

        See `configuration.nix` for the `nix.settings.trusted-users` wiring.
      '';
      type = lib.types.bool;
      default = false;
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

    agent = {
      startTimeoutSec = lib.mkOption {
        description = ''
          How long `coder-agent.service` waits for the template's boot script
          to publish the token before giving up.

          On every boot but the first, systemd reaches `multi-user.target`
          (and therefore starts this unit) *before* `amazon-init` re-runs and
          rewrites the token, so some waiting is unavoidable by design.
        '';
        type = lib.types.int;
        default = 600;
      };

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

    # Values the Coder template injects per workspace. These are passed at
    # *evaluation* time via `--override-input`, so they end up in the Nix
    # store and are world-readable. Never put a token or any other secret
    # here; the agent token is handed over through `runtimeDir` at runtime
    # instead.
    workspace = {
      name = lib.mkOption {
        description = "Coder workspace name. Empty when built outside Coder.";
        type = lib.types.str;
        default = "";
      };

      owner = lib.mkOption {
        description = "Username of the workspace owner.";
        type = lib.types.str;
        default = "";
      };

      ownerName = lib.mkOption {
        description = "Full name of the workspace owner, used for git authorship.";
        type = lib.types.str;
        default = "";
      };

      ownerEmail = lib.mkOption {
        description = "Email of the workspace owner, used for git authorship.";
        type = lib.types.str;
        default = "";
      };

      accessUrl = lib.mkOption {
        description = "Base URL of the Coder deployment this workspace belongs to.";
        type = lib.types.str;
        default = "";
      };
    };
  };
}
