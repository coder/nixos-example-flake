# NixOS configuration for Coder workspaces on AWS EC2

This is the reference NixOS configuration used by the [`aws-nixos`](https://github.com/coder/registry/tree/main/registry/coder/templates/aws-nixos)
Coder template. It targets the official NixOS EC2 AMIs and declares the Coder
agent as a systemd unit, so the agent survives `nixos-rebuild`.

It is meant to be forked. The template points at a flake reference and an
attribute name; everything about the machine — packages, services, users, Nix
settings — is decided here, not in the template.

## Layout

| Path | Owner | Contents |
| --- | --- | --- |
| `flake.nix` | you | inputs, the per-architecture `nixosConfigurations` |
| `configuration.nix` | **you** | the environment: packages, `nix.*`, swap, timezone |
| `hardware/ec2.nix` | platform | imports `amazon-image.nix`; do not fight it |
| `coder.nix` | Coder | the single import that wires the agent in |
| `coder/options.nix` | Coder | `options.coder.*` |
| `coder/agent.nix` | Coder | the `coder-agent.service` unit |
| `coder/user.nix` | Coder | workspace user, sudo, `nix-ld` |
| `vars/flake.nix` | Coder | per-workspace values, replaced at rebuild time |

`coder/` is self-contained and is intended to move to its own flake
(`github:coder/nixos-coder`). When it does, adopting it in an existing
configuration is a two-line change:

```nix
inputs.coder.url = "github:coder/nixos-coder";
# ...
modules = [ inputs.coder.nixosModules.default ./configuration.nix ];
```

## Which configuration gets applied

The attribute after `#` in the flake reference selects it:

```console
nixos-rebuild switch --flake 'github:coder/nixos-example-flake#workspace-x86_64'
```

This repository ships `workspace-x86_64` and `workspace-aarch64`. The template
derives the name from the chosen EC2 instance type, so the AMI architecture,
`coder_agent.arch` and the attribute always agree. Add your own entries to
`nixosConfigurations` and point the template's `flake_attr` variable at them —
it accepts an `$ARCH` placeholder (`workspace-$ARCH`) if you keep the
per-architecture split, or a fixed name if you do not.

## Per-workspace values

Values that differ between workspaces — the workspace name, its owner, the
deployment URL — are injected at evaluation time by overriding the `coder-vars`
input:

```console
nixos-rebuild switch \
  --flake 'github:coder/nixos-example-flake#workspace-x86_64' \
  --override-input coder-vars path:/etc/coder/vars \
  --no-write-lock-file
```

`/etc/coder/vars/flake.nix` is written by the template and has the same shape
as [`vars/flake.nix`](vars/flake.nix). This is an ordinary, pure flake
mechanism: no `--impure`, and no knowledge of the instance leaks into the
configuration.

> **Never add a secret to `coder-vars`.** Its contents are copied into
> `/nix/store`, which is world-readable to every process on the workspace and
> persists across generations. The agent token is passed at runtime through
> `/run/coder` (tmpfs, mode 0600) precisely so that it never reaches Nix.

## Verifying a change before you push

The template rebuilds from a Git reference, so a broken commit is a broken
workspace. Evaluation catches essentially every module and option error:

```console
nix eval --raw .#nixosConfigurations.workspace-x86_64.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.workspace-aarch64.config.system.build.toplevel.drvPath
nix build .#toplevel            # builds the closure for your native arch
```

Evaluating both attributes is worth the few seconds: the aarch64 configuration
is otherwise only exercised the first time somebody picks a Graviton instance
type.

`flake.lock` is committed on purpose. Without it every workspace resolves
nixpkgs independently at boot, which is slow and not reproducible — and a lock
file that is merely untracked is invisible to a Git flake reference, because
Nix only sees committed files.

## Things that will break the machine

- **Removing the `amazon-image.nix` import.** It declares the root filesystem,
  `boot.growPartition`, the bootloader and the Nitro/Xen initrd modules. Without
  it the switch succeeds and the instance never boots again.
- **Setting `boot.loader.*`.** A conflict with the platform module produces a
  switch that *succeeds* and a reboot that fails, which you discover when a
  workspace is restarted hours later.
- **Redeclaring `fileSystems."/"`** or replacing (rather than extending)
  `boot.initrd.availableKernelModules`.
- **Setting `nix.package = pkgs.lix`.** NixOS guards the entire `nix-daemon`
  module on the package not being Lix, so the unit semantics the Coder module
  relies on stop applying.
- **Bumping `system.stateVersion`** to something newer than the AMI. It is a
  compatibility marker, not a version to keep current.

## Recovery

`nixos-rebuild switch` builds before it activates, so a configuration that
fails to build never touches the running system — the previous generation keeps
running. If a configuration builds but misbehaves:

```console
sudo nixos-rebuild switch --rollback
```

There is deliberately no automatic rollback in the template: on a fresh
instance the previous generation is the bare AMI, which has no Coder agent at
all, so an automatic rollback would trade a visible failure for an
unreachable workspace.

To see what happened on a boot you cannot reach, the AMI logs to the serial
console:

```console
aws ec2 get-console-output --instance-id i-0123456789abcdef0 --output text
```
