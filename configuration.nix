# The machine: an ordinary NixOS configuration with no knowledge of Coder.
# This is the file to edit. `nix.*` lives here rather than in the Coder
# modules, because how a machine uses Nix is its owner's business.
{ pkgs, ... }:
{
  # Tracks the release the AMI was built from, not the newest one.
  system.stateVersion = "26.05";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # `--delete-older-than` rather than `-d`: every system generation is a GC
  # root, so a bare collection reclaims almost nothing, and `-d` would remove
  # every generation but the current one -- taking every rollback target with
  # it. Fourteen days keeps `nixos-rebuild switch --rollback` useful.
  nix.gc = {
    automatic = true;
    dates = "03:15";
    randomizedDelaySec = "1800";
    options = "--delete-older-than 14d";
  };

  # Cheaper than `auto-optimise-store`, which does the same work inline on
  # every build.
  nix.optimise.automatic = true;

  # Lets wheel add binary caches and import unsigned paths, which effectively
  # grants root: fine on a single-tenant development machine, not elsewhere.
  # Declaring caches in `nix.settings.substituters` needs no client trust.
  nix.settings.trusted-users = [ "@wheel" ];

  # The AMI configures no swap at all, and a rebuild that has to compile
  # anything will exhaust a small instance. Cheap insurance; the real fix is
  # not to pick a 1-2 GiB instance type.
  zramSwap.enable = true;
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 4096;
    }
  ];

  # Schedules above are evaluated against local time.
  time.timeZone = "UTC";

  environment.systemPackages = with pkgs; [
    curl
    direnv
    fd
    gh
    git
    gnumake
    bat
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

  users.defaultUserShell = pkgs.bashInteractive;
}
