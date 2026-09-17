# Maps the values the Coder template injects onto module options.
#
# `coderVars` arrives through `specialArgs`, sourced from the `coder-vars`
# flake input. The template replaces that input at rebuild time with
# `--override-input coder-vars path:/etc/coder/vars`, which is an ordinary
# pure flake mechanism -- no `--impure`, and the configuration needs no
# knowledge of the instance it runs on.
#
# Keeping the translation here rather than in flake.nix is what lets the rest
# of the flake stay agnostic: flake.nix passes an attrset through, and only
# this file knows what the keys mean.
{ lib, coderVars, ... }:
{
  coder = {
    user = lib.mkDefault coderVars.user;
    workspace = {
      name = coderVars.workspaceName;
      owner = coderVars.owner;
      ownerName = coderVars.ownerName;
      ownerEmail = coderVars.ownerEmail;
      accessUrl = coderVars.accessUrl;
    };
  };

  # Empty means "leave the hostname the platform derived from instance
  # metadata alone".
  networking.hostName = lib.mkIf (coderVars.hostname != "") coderVars.hostname;
}
