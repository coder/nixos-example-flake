# Coder workspace integration.
#
# This is the single file a configuration imports:
#
#   imports = [ ./modules/coder/index.nix ];
#
# Everything under this directory is self-contained and intended to be
# extracted verbatim into `github:coder/nixos-coder`, at which point the
# import becomes `inputs.coder.nixosModules.default`.
#
# Nothing here configures Nix itself, and nothing here needs values injected
# at evaluation time. `nix.settings`, garbage collection and the package set
# are the machine owner's business and live in configuration.nix.
{
  imports = [
    ./options.nix
    ./agent.nix
    ./user.nix
    ./stage-on-shutdown.nix
  ];
}
