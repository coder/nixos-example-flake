# The workspace user and the bits of the environment that Coder's own
# tooling depends on. Deliberately does not touch `nix.*` (see coder/options.nix).
{ config, lib, ... }:
let
  cfg = config.coder;
  ws = cfg.workspace;
in
lib.mkIf cfg.enable {
  users.groups.${cfg.user} = {
    gid = lib.mkDefault cfg.uid;
  };

  users.users.${cfg.user} = {
    description = "Coder workspace user";
    isNormalUser = true;
    uid = cfg.uid;
    group = cfg.user;
    home = "/home/${cfg.user}";
    createHome = true;
    extraGroups = cfg.extraGroups;
    shell = lib.mkIf (cfg.shell != null) cfg.shell;
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
  ];

  # Pre-seed git authorship from the workspace owner so the first commit in a
  # fresh workspace is not attributed to "root@ip-10-0-0-1". Written as
  # system-level config rather than into the user's home so that it never
  # fights a dotfiles module: /etc/gitconfig is the lowest-precedence layer.
  environment.etc."gitconfig" = lib.mkIf (ws.ownerEmail != "") {
    text = ''
      [user]
      	name = ${if ws.ownerName != "" then ws.ownerName else ws.owner}
      	email = ${ws.ownerEmail}
      [init]
      	defaultBranch = main
      [safe]
      	directory = *
    '';
  };

  environment.sessionVariables = lib.mkMerge [
    (lib.mkIf (ws.accessUrl != "") { CODER_URL = ws.accessUrl; })
    (lib.mkIf (ws.name != "") { CODER_WORKSPACE_NAME = ws.name; })
  ];
}
