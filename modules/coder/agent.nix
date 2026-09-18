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
# It also pins where the agent unpacks its own CLI, so that `coder` can be
# put on PATH declaratively -- see binDir below.
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

  # A wrapper rather than `EnvironmentFile`, because the files it reads are
  # published by the boot script and this unit should say so plainly when
  # they are missing instead of failing with systemd's generic error.
  startScript = pkgs.writeShellScript "coder-agent-start" ''
    set -eu

    ready=${lib.escapeShellArg "${cfg.runtimeDir}/ready"}
    env_file=${lib.escapeShellArg "${cfg.runtimeDir}/agent.env"}
    init_script=${lib.escapeShellArg "${cfg.runtimeDir}/init.sh"}

    for f in "$ready" "$env_file" "$init_script"; do
      if [ ! -f "$f" ]; then
        echo "coder-agent: $f is missing; refusing to start." >&2
        echo "coder-agent: the workspace boot script publishes it and then starts" >&2
        echo "coder-agent: this unit; check 'journalctl -u amazon-init'." >&2
        exit 1
      fi
    done

    # Coder's init script does `cd "$BINARY_DIR"` without creating it.
    mkdir -p ${binDir}

    set -a
    . "$env_file"
    set +a

    exec "$init_script"
  '';

  # Coder's init script honours BINARY_DIR and otherwise unpacks the CLI into
  # a fresh mktemp directory. Pinning it gives the wrapper below something
  # stable to point at.
  binDir = "${cfg.runtimeDir}/bin";
in
lib.mkIf cfg.enable {
  # `coder stat`, which the template'"'"'s metadata scripts call, has to be
  # reachable from an ordinary login shell.
  #
  # The agent prepends its own directory to the PATH it hands to scripts, but
  # on NixOS those scripts run through a login shell and /etc/profile rebuilds
  # PATH from the system environment, dropping it again. The result is a
  # workspace whose CPU/memory/disk metrics all read "coder: command not
  # found". A wrapper in systemPackages lands in /run/current-system/sw/bin,
  # which every shell has.
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "coder" ''
      if [ ! -x ${binDir}/coder ]; then
        echo "coder: the agent CLI is not available yet (${binDir}/coder)" >&2
        exit 127
      fi
      exec ${binDir}/coder "$@"
    '')
  ];

  systemd.services.coder-agent = {
    description = "Coder Agent";
    documentation = [ "https://coder.com/docs" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Deliberately not `wantedBy = [ "multi-user.target" ]`. The workspace
    # boot script starts this unit, and only once the rebuild it drives has
    # finished.
    #
    # Left to systemd, the agent would come up as soon as multi-user.target
    # is reached -- on the second and later boots that is *before*
    # `amazon-init` has re-run, fetched the new commit and switched. The
    # agent would connect, report the workspace ready and run its startup
    # scripts against the outgoing generation, which then gets swapped out
    # from under them: tools installed into a system that is about to be
    # replaced, scripts whose interpreters vanish mid-run, and a workspace
    # that looks ready minutes before it is.
    #
    # Do NOT instead order this unit `After = amazon-init.service`.
    # `nixos-rebuild switch` starts new units synchronously, `amazon-init`
    # cannot become active until its script exits, and on the first boot that
    # script is the one driving the switch. That is a boot-time deadlock.
    # Being started explicitly has neither problem.
    #
    # `Restart = always` still applies once started, so a crashing agent
    # recovers on its own; it just never starts unattended.

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

    environment.BINARY_DIR = binDir;

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
