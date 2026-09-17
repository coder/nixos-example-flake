# The machine configuration: this is the file you edit.
#
# Everything Coder needs is in `coder.nix`; this file is the environment you
# actually want. All `nix.*` settings live here deliberately - Nix
# configuration is the machine owner's business, and the Coder module never
# touches it.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  # Must track the NixOS release the AMI was built from, not "whatever is
  # newest". It is a compatibility marker for stateful defaults, so bumping it
  # on a live machine changes behaviour rather than upgrading anything.
  system.stateVersion = "26.05";

  # ---------------------------------------------------------------------------
  # Nix
  # ---------------------------------------------------------------------------

  # The nix daemon is already enabled on NixOS (`nix.daemon.enable` defaults to
  # `nix.enable`, which is true) and `/etc/nix/nix.conf` is read by both the
  # daemon and every client, so this makes flakes work for the workspace user
  # too. `nixos-rebuild --flake` does not depend on it: it passes
  # `--extra-experimental-features "nix-command flakes"` itself.
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # A bare `nix-collect-garbage` - which is what `nix.gc.automatic` runs when
  # `options` is left at its default empty string - deletes only *unreachable*
  # paths. Every old system generation is a GC root, so on a machine that
  # rebuilds regularly it reclaims almost nothing.
  #
  # `--delete-older-than` rather than `-d` on purpose: `-d` removes every
  # generation but the current one, which also destroys every rollback target.
  # A 14-day window keeps `nixos-rebuild switch --rollback` useful. Note this
  # never deletes a generation built by `nixos-rebuild boot` but not yet
  # booted - the boot entry roots it.
  nix.gc = {
    automatic = true;
    dates = "03:15";
    randomizedDelaySec = "1800";
    options = "--delete-older-than 14d";
  };

  # Hardlink identical files in the store. Cheaper than `auto-optimise-store`,
  # which does the same work inline on every build.
  nix.optimise.automatic = true;

  # The Nix store lives on the root volume and generations are not free.
  boot.loader.grub.configurationLimit = 20;

  # Granting the workspace user Nix trust lets project flakes bring their own
  # binary caches (`extra-substituters` + `--accept-flake-config`) instead of
  # silently building from source. It also effectively grants root, since a
  # trusted user can have arbitrary unsigned paths imported and activated.
  #
  # That is an acceptable trade for a single-tenant dev workspace, which is
  # what a Coder workspace is. If you would rather not, set it to false and
  # declare the caches system-wide in `nix.settings.substituters` +
  # `nix.settings.trusted-public-keys`, which needs no client trust at all.
  coder.trustUser = true;
  nix.settings.trusted-users = [
    "root"
  ] ++ lib.optional config.coder.trustUser config.coder.user;

  # ---------------------------------------------------------------------------
  # Memory
  # ---------------------------------------------------------------------------

  # The NixOS AMI configures no swap whatsoever, and a `nixos-rebuild` that
  # has to compile anything will happily exhaust a small instance. Both of
  # these are cheap insurance; the real fix is not to use a 1-2 GiB instance
  # type, which is why the template's smallest option is t3.medium.
  zramSwap.enable = true;
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 4096;
    }
  ];

  # ---------------------------------------------------------------------------
  # Environment
  # ---------------------------------------------------------------------------

  # `coder_script` cron expressions are evaluated agent-side against the
  # host's local time, so pinning the zone is what makes a schedule written in
  # the template mean what its author intended.
  time.timeZone = "UTC";

  environment.systemPackages = with pkgs; [
    curl
    direnv
    fd
    gh
    git
    gnumake
    htop
    jq
    nix-output-monitor
    ripgrep
    tree
    unzip
    vim
    wget
  ];

  programs.bash.completion.enable = true;
  programs.git.enable = true;

  coder.shell = pkgs.bashInteractive;
}
