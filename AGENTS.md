# AGENTS.md

A reference NixOS configuration for Coder workspaces on AWS EC2, consumed by the
[`aws-nixos`](https://registry.coder.com/templates/coder/aws-nixos) template.

The template treats this repository as **foreign code**. It clones it to `/etc/nixos` and runs a
plain `nixos-rebuild switch --flake /etc/nixos#coder-workspace-ec2-<arch>` — no `--override-input`, no
`--impure`, no injected inputs, no evaluation-time knowledge of the workspace. Anything that would
break that contract belongs in the template or in a runtime file, not here.

`README.md` explains the design for people using this flake. This file is the working agreement for
changing it.

## Layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | Two configurations, `coder-workspace-ec2-x86_64` and `coder-workspace-ec2-aarch64`. Inputs: nixpkgs and `coder-modules`. |
| `configuration.nix` | The machine. Ordinary NixOS, zero `coder.*` references. This is the file a user edits. |
| `hardware/ec2.nix` | Imports `amazon-image.nix`, and nothing else. |

The Coder integration — the agent unit, the workspace user, the shutdown hook
and every `coder.*` option — is not here. It is
[coder/nixos-modules](https://github.com/coder/nixos-modules), and its own
`AGENTS.md` holds the invariants that belong to it. Change it there and relock
here; do not vendor it back.

## Verifying a change

A broken commit on `main` is a broken workspace: every workspace rebuilds from this branch at boot.
Evaluate **both** architectures before pushing — this catches essentially every module and option
error without needing a builder for the other arch:

```console
nix eval --raw .#nixosConfigurations.coder-workspace-ec2-x86_64.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.coder-workspace-ec2-aarch64.config.system.build.toplevel.drvPath
```

Both must be silent. A `warning: Git tree is dirty` is fine locally; a lock-file warning is not —
it means an input changed and `flake.lock` was not committed with it.

To evaluate against an unpushed change to the modules, point the input at a local checkout:

```console
nix eval --override-input coder-modules /path/to/nixos-modules \
  --raw .#nixosConfigurations.coder-workspace-ec2-x86_64.config.system.build.toplevel.drvPath
```

If there is no Nix on the machine you are working from, copy the tree to a running NixOS workspace
over `coder ssh` and evaluate there. Do not push and find out.

## Invariants

These are not style preferences. Each one is a bug that has already happened. The ones about the
agent, the user and the shutdown hook live in
[coder/nixos-modules](https://github.com/coder/nixos-modules/blob/main/AGENTS.md).

1. **No relative paths in `inputs`, and no injected evaluation inputs.** `path:./vars` fails with
   `cannot fetch input ... because it uses a relative path` and rewrites the lock on every build.
   The template passes nothing at evaluation time; per-workspace facts are runtime data in
   `/run/coder/workspace.json`, read by a service.
2. **Keep the `amazon-image.nix` import, keep `nixpkgs.hostPlatform` explicit, and do not set
   `boot.loader.*`.** Each produces a switch that succeeds and a machine that never boots again.
3. **Do not add `/bin/bash`.** NixOS has `/bin/sh` only. Scripts that assume otherwise get fixed at
   the source; a compatibility symlink here hides the problem from everyone else.
4. **`system.stateVersion` tracks the AMI's release**, not the newest one. It is a compatibility
   marker, not a version to keep current.

## Debugging on a workspace

The journal is not persistent, so anything that has to survive a reboot is written to a file:

| What | Where |
| --- | --- |
| Rebuild transcripts | `/var/log/coder-nixos/rebuild-*.log`, plus `rebuild-latest.log` |
| Shutdown staging | `/var/lib/coder-nixos/stage-on-shutdown.log`, result in `staged-at-shutdown` |
| Rev the running system was built from | `/var/lib/coder-nixos/flake.rev` |
| Boot script | `journalctl -u amazon-init`, script at `/run/coder/bootstrap.sh` |
| A boot you cannot reach | `aws ec2 get-console-output --instance-id i-...` |

`/run/current-system` is the *activated* system; `/run/booted-system` is what the kernel booted and
still points at the previous generation after a switch. Comparing the wrong one marks every fresh
workspace as needing a restart.

## Style

- Format with `nixfmt-rfc-style`.
- Comments explain *why*. Many of them encode a failure that took hours to find — do not delete one
  without reproducing the behaviour it describes.
- Conventional commits (`fix(agent): ...`, `docs: ...`). Say what breaks, not just what changed.
- Options go in `options.nix` with a description that explains the tradeoff, not the type.
