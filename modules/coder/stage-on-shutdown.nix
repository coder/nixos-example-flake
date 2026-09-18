# Build the next generation while the workspace is shutting down, so the next
# start boots it instead of building it.
#
# Why it is shaped like this
# --------------------------
# Coder cannot wait for anything at stop. Its agent protocol has no
# shutdown RPC -- `run_on_stop` fires from the agent's SIGTERM handler, and
# that SIGTERM only arrives because the machine is already powering off,
# which only happens because the stop apply already ran. So the provisioner
# calls StopInstances concurrently and a rebuild started there is killed
# partway, silently.
#
# systemd, on the other hand, does block on `ExecStop`. The trick is that a
# unit *started* during shutdown is doomed -- every unit gets an implicit
# `Conflicts=shutdown.target`, and `DefaultDependencies=false` does not save
# it. So this unit starts trivially at boot and does its work on stop.
#
# `after` is load-bearing: units stop in reverse start order, so ordering
# after network.target and nix-daemon.service means this stops *before* they
# do, while a rebuild can still fetch and build.
#
# None of this is a correctness mechanism. The boot path rebuilds whenever the
# configuration changed, so the next boot lands on the right generation
# regardless. This only makes that boot fast. It is best effort by
# construction: EC2 does not document how long it tolerates a graceful
# shutdown, so treat the timeout as a hope, not a contract.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.coder;

  stage = pkgs.writeShellScript "coder-stage-generation" ''
    set -eu
    export PATH=/run/current-system/sw/bin:$PATH

    flake=${lib.escapeShellArg cfg.flakeDir}
    marker=${lib.escapeShellArg "${cfg.stateDir}/staged-at-shutdown"}
    log=${lib.escapeShellArg "${cfg.stateDir}/stage-on-shutdown.log"}

    # Everything below is also written to a file, because the journal is not
    # persistent by default and this runs while the machine is going away --
    # so on the next boot the journal for this run is gone and a failure here
    # would be undiagnosable.
    exec > >(tee -a "$log") 2>&1
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) shutdown staging ==="

    [ -e "$flake/flake.nix" ] || exit 0

    # Nothing to do when the boot default already is the running system and
    # the checkout has not moved since we built it. This is the common case,
    # and it has to cost milliseconds or every stop gets slower.
    booted_rev=$(cat ${lib.escapeShellArg "${cfg.stateDir}/flake.rev"} 2>/dev/null || echo "")
    head_rev=$(git -C "$flake" rev-parse HEAD 2>/dev/null || echo "")
    dirty=$(git -C "$flake" status --porcelain 2>/dev/null | head -1)

    if [ -z "$dirty" ] && [ -n "$head_rev" ] && [ "$head_rev" = "$booted_rev" ] &&
      [ "$(readlink -f /run/current-system)" = "$(readlink -f /nix/var/nix/profiles/system)" ]; then
      exit 0
    fi

    echo "coder: staging the next generation from $flake#${cfg.flakeAttr}"

    # Deliberately not `nixos-rebuild boot`. nixos-rebuild runs
    # switch-to-configuration inside a transient `systemd-run` unit, and
    # starting any unit during shutdown is refused:
    #
    #   Transaction for nixos-rebuild-switch-to-configuration.service/start
    #   is destructive (shutdown.target has 'start' job queued ...)
    #
    # so the build would succeed and the generation would never become the
    # boot default. The three steps below are what `boot` means -- build the
    # closure, point the system profile at it, write the bootloader entry --
    # with the last one invoked directly, which needs no new unit.
    stage_generation() {
      local toplevel
      toplevel=$(nix build --no-link --print-out-paths --print-build-logs \
        "$flake#nixosConfigurations.${cfg.flakeAttr}.config.system.build.toplevel") || return 1
      nix-env --profile /nix/var/nix/profiles/system --set "$toplevel" || return 1
      "$toplevel"/bin/switch-to-configuration boot || return 1
    }

    if stage_generation; then
      printf 'ok %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker"
      echo "coder: staged; the next boot will use it"
    else
      printf 'failed %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker"
      echo "coder: staging failed; the next boot will build instead" >&2
    fi
  '';
in
lib.mkIf (cfg.enable && cfg.stageOnShutdown.enable) {
  systemd.services.coder-stage-generation = {
    description = "Stage the next NixOS generation before shutdown";
    wantedBy = [ "multi-user.target" ];
    after = [
      "multi-user.target"
      "network.target"
      "nix-daemon.service"
    ];

    # Changing this unit must not run the staging script as a side effect of
    # a switch: stopping it *is* the work.
    restartIfChanged = false;
    stopIfChanged = false;

    path = with pkgs; [
      coreutils
      git
      gnugrep
      nix
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      ExecStop = stage;
      TimeoutStopSec = cfg.stageOnShutdown.timeoutSec;
    };
  };
}
