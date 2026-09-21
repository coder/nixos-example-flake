# The workspace user and the bits of the environment that Coder's own
# tooling depends on. Deliberately does not touch `nix.*` (see coder/options.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.coder;
in
lib.mkIf cfg.enable {
  # The group always has to exist, since the user references it; only the
  # numeric id is conditional.
  users.groups.${cfg.user} = {
    gid = lib.mkIf (cfg.uid != null) (lib.mkDefault cfg.uid);
  };

  users.users.${cfg.user} = {
    description = "Coder workspace user";
    isNormalUser = true;
    uid = lib.mkIf (cfg.uid != null) cfg.uid;
    group = cfg.user;
    home = "/home/${cfg.user}";
    createHome = true;
    extraGroups = cfg.extraGroups;
  };

  # `coder_script` bodies run as the workspace user through its login shell
  # and there is no `run_as` argument, so anything privileged - including
  # `nixos-rebuild` - has to go through sudo without a password prompt.
  security.sudo.wheelNeedsPassword = false;

  # VS Code Remote, JetBrains Gateway and Cursor all push dynamically linked
  # binaries into the workspace and exec them directly. Without nix-ld they
  # fail with a bare "No such file or directory" that looks nothing like a
  # missing loader.
  programs.nix-ld.enable = true;

  systemd.tmpfiles.rules = [
    "d ${cfg.logDir}   0755 root       root      -"
    "d ${cfg.stateDir} 0755 root       root      -"
    "d /home/${cfg.user} 0700 ${cfg.user} ${cfg.user} -"
    # Owned by the workspace user so the configuration can be edited without
    # sudo; rebuilding it still needs sudo.
    "d ${cfg.flakeDir} 0755 ${cfg.user} ${cfg.user} -"

    # nix-ld above answers "where is the loader?" for foreign binaries; this
    # answers "where is the interpreter?" for foreign scripts.
    #
    # Coder's registry modules are written for FHS distributions and most of
    # them begin with `#!/bin/bash`. On NixOS /bin contains only `sh`, so the
    # kernel fails the exec and the agent reports exit 255 with an empty log
    # -- there is no output because nothing ever ran. Any workspace that uses
    # a registry module needs this, so it is not optional here.
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
  ];

  # Git identity is not set here. It is per-user, per-workspace state that
  # this module has no pure way to learn -- the template supplies it through
  # the registry's git-config module, which works against any flake. The
  # runtime facts about the workspace are in /run/coder/workspace.json if a
  # configuration wants them.
  #
  # `safe.directory` is set though, because /etc/nixos is a git checkout owned
  # by the workspace user that root also operates on during a rebuild.
  environment.etc."gitconfig".text = ''
    [safe]
    	directory = ${cfg.flakeDir}
  '';
}
