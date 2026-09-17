# The Coder agent systemd unit, and nothing else.
#
# Why the agent has to be declared in Nix at all
# ----------------------------------------------
# On NixOS `/etc/systemd/system` is regenerated from the active generation, so
# a unit written there by a boot script does not survive `nixos-rebuild`. It
# also could not pin its own dependencies: `path` below fixes exact store
# paths that stay alive through garbage collection.
#
# The imperative/declarative boundary
# -----------------------------------
# This module names three paths and nothing more. The agent token, the
# deployment URL and the agent init script are per-start, per-deployment state
# written by the template's boot script:
#
#   ${runtimeDir}/agent.env   0600   CODER_AGENT_TOKEN, CODER_AGENT_URL
#   ${runtimeDir}/init.sh     0755   coder_agent.init_script, verbatim
#   ${runtimeDir}/ready       0644   marker, written last
#
# The token must never be passed into Nix - not as a flake input, `--argstr`,
# `specialArgs` or `builtins.getEnv`. It would be baked into a derivation,
# land world-readable in /nix/store, persist across generations and past
# rotation, and invalidate the evaluation cache on every workspace start.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.coder;

  # A wrapper rather than `EnvironmentFile` + `Restart=always`.
  #
  # `runtimeDir` is a tmpfs, so on every boot this unit starts before
  # `amazon-init` has re-run and republished the token. With
  # `EnvironmentFile` systemd would fail the unit outright for a missing
  # file and we would rely on restart churn to recover; blocking on the
  # marker turns that race into a short, silent wait.
  #
  # Do NOT try to remove the wait by ordering this unit
  # `After = amazon-init.service`. `nixos-rebuild switch` starts new units
  # synchronously, `amazon-init` cannot become active until its script
  # exits, and on first boot that script is the one driving the switch.
  # That is a boot-time deadlock.
  startScript = pkgs.writeShellScript "coder-agent-start" ''
    set -eu

    ready=${lib.escapeShellArg "${cfg.runtimeDir}/ready"}
    env_file=${lib.escapeShellArg "${cfg.runtimeDir}/agent.env"}
    init_script=${lib.escapeShellArg "${cfg.runtimeDir}/init.sh"}

    deadline=$(( $(date +%s) + ${toString cfg.agent.startTimeoutSec} ))
    while [ ! -f "$ready" ]; do
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "coder-agent: $ready did not appear within ${toString cfg.agent.startTimeoutSec}s." >&2
        echo "coder-agent: the workspace boot script writes it; check 'journalctl -u amazon-init'." >&2
        exit 1
      fi
      sleep 1
    done

    for f in "$env_file" "$init_script"; do
      if [ ! -f "$f" ]; then
        echo "coder-agent: $ready exists but $f is missing; refusing to start." >&2
        exit 1
      fi
    done

    set -a
    . "$env_file"
    set +a

    exec "$init_script"
  '';
in
lib.mkIf cfg.enable {
  systemd.services.coder-agent = {
    description = "Coder Agent";
    documentation = [ "https://coder.com/docs" ];
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # A `nixos-rebuild switch` triggered by the template's periodic update
    # must not restart the agent: the rebuild is usually being driven by a
    # `coder_script` that the agent itself is running, and restarting the
    # agent mid-rebuild kills the script and the log stream with it. A
    # changed unit definition therefore takes effect on the next reboot.
    restartIfChanged = false;
    stopIfChanged = false;

    path =
      with pkgs;
      [
        bash
        coreutils
        curl
        findutils
        git
        gnugrep
        gnused
        gnutar
        gzip
        procps
        shadow
        sudo
        util-linux
      ]
      ++ lib.optional config.nix.enable config.nix.package
      ++ cfg.agent.extraPackages;

    serviceConfig = {
      Type = "simple";
      User = cfg.user;
      Group = cfg.user;
      ExecStart = startScript;
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 90;
      # The agent forks helpers (SSH sessions, port forwards) that must not be
      # torn down when the main process is signalled.
      KillMode = "process";
      OOMScoreAdjust = -900;
      SyslogIdentifier = "coder-agent";
    };
  };
}
