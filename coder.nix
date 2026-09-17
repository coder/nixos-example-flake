# Coder workspace integration.
#
# This is the single file a downstream configuration imports. Everything it
# pulls in lives under `coder/` and is intended to be extracted verbatim into
# `github:coder/nixos-coder`, at which point this file is replaced by
# `inputs.coder.nixosModules.default`.
{
  imports = [
    ./coder/options.nix
    ./coder/agent.nix
    ./coder/user.nix
  ];
}
