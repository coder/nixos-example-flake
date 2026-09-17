# Per-workspace values, injected at evaluation time.
#
# This is a deliberately trivial flake with no inputs. It exists so that the
# Coder template can replace it wholesale at rebuild time:
#
#   nixos-rebuild switch --flake 'git+https://.../nixos-example-flake#workspace-x86_64' \
#     --override-input coder-vars path:/etc/coder/vars \
#     --no-write-lock-file
#
# The template writes /etc/coder/vars/flake.nix with the same shape and the
# real workspace values. Because `--override-input` is an ordinary, *pure*
# flake mechanism, none of this requires `--impure`, and the admin's flake
# needs no knowledge of the instance it is being built on.
#
# The values below are the defaults used when the flake is built outside
# Coder (`nix build`, CI, `nixos-rebuild` by hand).
#
# NEVER put a secret here. Everything in this file is copied into the Nix
# store and is world-readable to every process on the workspace. The agent
# token is handed over at runtime through /run/coder instead.
{
  outputs = _: {
    coderVars = {
      # Workspace user. Must match whatever owns /home in your image.
      user = "coder";

      # Instance hostname. Left empty means "leave EC2's metadata-derived
      # hostname alone".
      hostname = "";

      # Coder workspace identity, used for git authorship and shell env.
      workspaceName = "";
      owner = "";
      ownerName = "";
      ownerEmail = "";
      accessUrl = "";
    };
  };
}
