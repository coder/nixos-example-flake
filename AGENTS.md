# AGENTS.md

A reference NixOS configuration for Coder workspaces on AWS EC2, consumed by the
[`aws-nixos`](https://registry.coder.com/templates/coder/aws-nixos) template.

The template treats this repository as **foreign code**. It clones it to `/etc/nixos` and runs a
plain `nixos-rebuild switch --flake /etc/nixos#workspace-<arch>` — no `--override-input`, no
`--impure`, no injected inputs, no evaluation-time knowledge of the workspace. Anything that would
break that contract belongs in the template or in a runtime file, not here.

`README.md` explains the design for people using this flake. This file is the working agreement for
changing it.

## Layout

| Path | Purpose |
| --- | --- |
| `flake.nix` | Two configurations, `workspace-x86_64` and `workspace-aarch64`. Only input is nixpkgs. |
| `configuration.nix` | The machine. Ordinary NixOS, zero `coder.*` references. This is the file a user edits. |
| `hardware/ec2.nix` | Imports `amazon-image.nix`, and nothing else. |
| `modules/coder/options.nix` | Every `coder.*` option. |
| `modules/coder/agent.nix` | `coder-agent.service` and the `coder` CLI wrapper. |
| `modules/coder/user.nix` | Workspace user, sudo, nix-ld, tmpfiles, `/etc/gitconfig`. |
| `modules/coder/stage-on-shutdown.nix` | Builds the next generation during shutdown. |

## Verifying a change

A broken commit on `main` is a broken workspace: every workspace rebuilds from this branch at boot.
Evaluate **both** architectures before pushing — this catches essentially every module and option
error without needing a builder for the other arch:

```console
nix eval --raw .#nixosConfigurations.workspace-x86_64.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.workspace-aarch64.config.system.build.toplevel.drvPath
```

Both must be silent. A `warning: Git tree is dirty` is fine locally; a lock-file warning is not —
it means an input changed and `flake.lock` was not committed with it.

If there is no Nix on the machine you are working from, copy the tree to a running NixOS workspace
over `coder ssh` and evaluate there. Do not push and find out.

## Invariants

These are not style preferences. Each one is a bug that has already happened.

1. **`coder-agent.service` has no `wantedBy`.** The workspace boot script starts it, after the
   rebuild it drives has finished. Add `wantedBy = [ "multi-user.target" ]` and the agent runs the
   workspace's startup scripts against the generation that is about to be replaced. Ordering it
   `after = [ "amazon-init.service" ]` instead is a boot-time deadlock.
2. **The agent token never enters Nix.** Not as an input, `--argstr`, `specialArgs` or
   `builtins.getEnv`. It would be world-readable in `/nix/store`, persist across generations and
   past rotation, and invalidate the eval cache on every start. The handoff is
   `/run/coder/{agent.env,init.sh,ready}`, written by the template.
3. **No injected evaluation inputs, and no relative paths in `inputs`.** `path:./vars` fails with
   `cannot fetch input ... because it uses a relative path` and rewrites the lock on every build.
4. **Per-workspace facts are runtime data.** `/run/coder/workspace.json`, read by a service. Pure
   evaluation cannot read an absolute path outside the flake, so consuming it at eval time would
   require `--impure` and break reproducibility.
5. **`coder.uid` stays `null`.** `amazon-ssm-agent` creates `ssm-user` at the first free UID, so
   pinning 1000 yields two accounts sharing it and an SSM session with the workspace user's
   identity.
6. **Shutdown staging lives in `ExecStop` of a `RemainAfterExit` oneshot.** A unit *started* during
   shutdown is killed by the implicit `Conflicts=shutdown.target`; systemd does block on `ExecStop`.
   It must not call `nixos-rebuild boot`, which wraps `switch-to-configuration` in `systemd-run` —
   starting a unit is refused once `shutdown.target` is queued, and the generation silently never
   becomes the boot default.
7. **`restartIfChanged` and `stopIfChanged` are `false` on `coder-agent`.** A periodic rebuild is
   usually driven by a `coder_script` the agent is running; restarting it mid-rebuild kills the
   script and its log stream.
8. **Keep the `amazon-image.nix` import, keep `nixpkgs.hostPlatform` explicit, and do not set
   `boot.loader.*`.** Each produces a switch that succeeds and a machine that never boots again.
9. **Do not add `/bin/bash`.** NixOS has `/bin/sh` only. Scripts that assume otherwise get fixed at
   the source; a compatibility symlink here hides the problem from everyone else.
10. **`system.stateVersion` tracks the AMI's release**, not the newest one. It is a compatibility
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
