# The workspace user and the bits of the environment that Coder's own
# tooling depends on. Deliberately does not touch `nix.*` (see coder/options.nix).
{ config, lib, ... }:
let
  cfg = config.coder;
  user = cfg.user.name;

  # Asked of the merged configuration rather than assumed to be the username.
  # With `create = true` this module sets both and they agree; with it false
  # the account is someone else's declaration, and NixOS's own default for a
  # user who does not name a group is `users`. Getting this wrong is not an
  # evaluation error -- it is a tmpfiles rule that fails at activation with an
  # unknown group, which leaves /etc/nixos owned by root.
  group = config.users.users.${user}.group or user;
in
lib.mkIf cfg.enable {
  # The group has to exist because the user references it; only the numeric id
  # is conditional.
  users.groups = lib.mkIf cfg.user.create {
    ${user}.gid = lib.mkIf (cfg.user.uid != null) (lib.mkDefault cfg.user.uid);
  };

  users.users = lib.mkIf cfg.user.create {
    ${user} = {
      description = "Coder workspace user";
      isNormalUser = true;
      uid = lib.mkIf (cfg.user.uid != null) cfg.user.uid;
      group = user;
      home = "/home/${user}";
      createHome = true;
      extraGroups = cfg.user.extraGroups;
    };
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
    "d /home/${user} 0700 ${user} ${group} -"
    # Owned by the workspace user so the configuration can be edited without
    # sudo; rebuilding it still needs sudo.
    "d ${cfg.flakeDir} 0755 ${user} ${group} -"
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
