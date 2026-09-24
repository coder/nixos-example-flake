# Keep the machine current, on a timer, using NixOS's own `system.autoUpgrade`.
#
# Two things upstream does not do, which this module adds:
#
#   1. It never syncs anything. `--refresh` busts nix's evaluation cache for
#      *remote* references; for a local path flake like /etc/nixos it does
#      nothing at all, so a checkout that is behind its remote would be
#      rebuilt unchanged forever. ExecStartPre fast-forwards it first.
#   2. It takes no lock. `Type=oneshot` prevents a second copy of the same
#      unit and nothing else -- not a boot-time rebuild, not a human at a
#      terminal. The sync below takes the same lock the rest of this system
#      uses, and `afterUnits` lets a platform module order the timer behind
#      its own boot job.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.coder;

  lock = "${cfg.stateDir}/rebuild.lock";

  # Same policy as any other rebuild path here: fast-forward a clean checkout,
  # and otherwise build exactly what is on disk. Someone with local changes is
  # working on them; 04:40 is not the time to find out they were discarded.
  #
  # Always exits 0. Being unable to reach the remote is not a reason to skip
  # rebuilding what is already checked out, and ExecStartPre failing would
  # fail the unit.
  sync = pkgs.writeShellScript "coder-upgrade-sync" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.git
        pkgs.util-linux
      ]
    }:$PATH

    flake=${lib.escapeShellArg cfg.flakeDir}
    [ -e "$flake/.git" ] || exit 0

    exec 9>${lib.escapeShellArg lock}
    if ! flock -w 300 9; then
      echo "coder: another rebuild holds the lock; building the checkout as it is"
      exit 0
    fi

    if [ -n "$(git -C "$flake" status --porcelain 2>/dev/null | head -1)" ]; then
      echo "coder: $flake has local changes; building those"
      exit 0
    fi

    branch=$(git -C "$flake" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [ -n "$branch" ] && [ "$branch" != "HEAD" ] || exit 0

    if ! git -C "$flake" fetch --quiet origin "$branch" 2>/dev/null; then
      echo "coder: could not reach the remote; building the checkout as it is"
      exit 0
    fi

    local_rev=$(git -C "$flake" rev-parse HEAD)
    upstream_rev=$(git -C "$flake" rev-parse FETCH_HEAD 2>/dev/null || true)
    [ -n "$upstream_rev" ] && [ "$local_rev" != "$upstream_rev" ] || exit 0

    if git -C "$flake" merge-base --is-ancestor "$local_rev" "$upstream_rev" 2>/dev/null; then
      echo "coder: updating $flake to ''${upstream_rev:0:12}"
      git -C "$flake" reset --hard --quiet "$upstream_rev"
      # Fetching as root writes into .git; keep the tree owned by whoever owns
      # the directory, or the user's next git command fails on index.lock.
      chown -R "$(stat -c %U "$flake")" "$flake" 2>/dev/null || true
    else
      echo "coder: $flake has local commits; building those"
    fi
  '';
in
lib.mkIf (cfg.enable && cfg.autoUpgrade.enable) {
  system.autoUpgrade = {
    enable = true;
    flake = "${cfg.flakeDir}#${cfg.flakeAttr}";
    operation = cfg.autoUpgrade.operation;
    dates = cfg.autoUpgrade.dates;
    randomizedDelaySec = cfg.autoUpgrade.randomizedDelaySec;

    # The boot path already rebuilds from the checkout, so a timer missed
    # while the workspace was stopped has nothing left to do: with
    # `persistent` it would fire again minutes after boot and rebuild what was
    # just built.
    persistent = false;

    # There are no channels here. In flake mode `--upgrade` does nothing but
    # log that it does nothing.
    upgrade = false;

    # Careful: upstream *defines* `flags` in its own config section, so this
    # concatenates with `[ "--refresh" "--flake <uri>" ]` rather than
    # replacing it. Setting `--flake` here would pass it twice.
    flags = lib.optional cfg.autoUpgrade.printBuildLogs "--print-build-logs";
  };

  systemd.services.nixos-upgrade = {
    after = cfg.autoUpgrade.afterUnits;
    serviceConfig.ExecStartPre = [ "${sync}" ];
  };
}
