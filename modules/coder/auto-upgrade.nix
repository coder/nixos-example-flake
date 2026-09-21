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
  # The upgrade writes to the journal, which nobody using a Coder workspace is
  # going to read. This follows it and pushes the lines to the workspace UI,
  # through the same log source and the same byte budget the boot path uses.
  #
  # Everything it needs is published by whatever bootstrapped the machine:
  # the token in agent.env (0600), the library and the facts file in
  # runtimeDir. On a machine with no Coder runtime the unit is skipped by
  # ConditionPathExists and the upgrade runs exactly as it would have.
  stream = pkgs.writeShellScript "coder-stream-nixos-upgrade-logs" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.systemd
        pkgs.curl
      ]
    }:$PATH

    facts=${lib.escapeShellArg "${cfg.runtimeDir}/workspace.json"}

    CODER_ACCESS_URL=$(jq -r '.access_url // empty' "$facts")
    CODER_LOG_SOURCE_ID=$(jq -r '.log_source_id // empty' "$facts")
    CODER_LOG_STATE_DIR=${lib.escapeShellArg cfg.runtimeDir}
    export CODER_ACCESS_URL CODER_LOG_SOURCE_ID CODER_LOG_STATE_DIR

    [ -n "$CODER_ACCESS_URL" ] && [ -n "$CODER_LOG_SOURCE_ID" ] || {
      echo "coder: no log source in $facts; not streaming" >&2
      exit 0
    }

    # shellcheck source=/dev/null
    . ${lib.escapeShellArg "${cfg.runtimeDir}/log.sh"}

    # A repeat POST of a known id is a no-op server-side, so this is just how
    # a fresh process marks itself ready to log.
    coder_log_init "NixOS" "/icon/nix.svg" || exit 0

    # A oneshot is `activating` while it runs, and `systemctl is-active`
    # reports that as *not* active -- so a naive `while is-active` loop exits
    # instantly. This one waits for the unit to start (we are ordered ahead of
    # it, so it has not yet) and then for it to leave.
    upgrade_running() {
      case "$(systemctl show nixos-upgrade.service -p ActiveState --value 2>/dev/null)" in
        activating | active | reloading) return 0 ;;
        *) return 1 ;;
      esac
    }

    # Stopping on our own terms rather than waiting to be killed: `bindsTo`
    # would SIGTERM this the moment the upgrade finishes, and anything still
    # in the batch would go with it. Letting journalctl end closes the pipe,
    # which flushes.
    {
      # stdbuf, because journalctl block-buffers into a pipe: without it the
      # last partial block -- which is exactly the "Done. The new
      # configuration is ..." line people want -- dies with the process.
      stdbuf -oL journalctl --unit=nixos-upgrade.service --follow --lines=0 --output=cat &
      follower=$!

      deadline=$(( $(date +%s) + 120 ))
      while ! upgrade_running; do
        [ "$(date +%s)" -lt "$deadline" ] || break
        sleep 1
      done
      while upgrade_running; do sleep 2; done

      # The last lines are written as the unit is going down.
      sleep 3

      kill "$follower" 2>/dev/null || true
      wait "$follower" 2>/dev/null || true
    } | grep --line-buffered -v -E 'Consumed [0-9].* CPU time|: Deactivated successfully\.$' \
      | coder_log_pipe info
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

  systemd.services.coder-stream-nixos-upgrade-logs = {
    description = "Stream NixOS upgrade output to the Coder workspace log";

    # Pulled in by the upgrade rather than by a target, and ordered ahead of
    # it so the follower is attached before there is anything to miss.
    #
    # Deliberately *not* `bindsTo`: systemd would SIGTERM this the instant the
    # oneshot went inactive, which is exactly when the last and most
    # interesting lines are still working their way through the pipe. The
    # script watches the unit and ends on its own a moment later, so the
    # stream drains; RuntimeMaxSec is the backstop if the upgrade never ends.
    wantedBy = [ "nixos-upgrade.service" ];
    before = [ "nixos-upgrade.service" ];

    unitConfig.ConditionPathExists = [
      "${cfg.runtimeDir}/log.sh"
      "${cfg.runtimeDir}/workspace.json"
    ];

    serviceConfig = {
      Type = "simple";
      # The token, and only the token. Everything else is world-readable in
      # workspace.json. `-` because a machine may have neither.
      EnvironmentFile = [ "-${cfg.runtimeDir}/agent.env" ];
      ExecStart = stream;
      RuntimeMaxSec = 7200;
      # Short enough that a slow build still feels live in the UI.
      Environment = [ "CODER_LOG_FLUSH_SECS=2" ];
      # Logging is never a reason for anything to fail.
      SuccessExitStatus = "0 1";
    };
  };
}
