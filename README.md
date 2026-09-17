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
| `flake.nix` | you | inputs and the per-architecture `nixosConfigurations` |
| `configuration.nix` | **you** | the environment: packages, `nix.*`, swap, timezone |
| `hardware/ec2.nix` | platform | imports `amazon-image.nix`; optional facter hook |
| `modules/coder/index.nix` | Coder | the single import that wires the agent in |
| `modules/coder/options.nix` | Coder | `options.coder.*` |
| `modules/coder/agent.nix` | Coder | the `coder-agent.service` unit and `coder` on PATH |
| `modules/coder/user.nix` | Coder | workspace user, sudo, `nix-ld` |
| `modules/coder/vars.nix` | Coder | maps injected values onto options |
| `vars/flake.nix` | Coder | per-workspace values, replaced at rebuild time |

`flake.nix` and `configuration.nix` contain no Coder-specific settings: the
integration is one import, and `configuration.nix` does not mention `coder.*`
at all. `modules/coder/` is self-contained and is intended to move to its own
flake (`github:coder/nixos-coder`). When it does, adopting it in an existing
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

The input's default is the absolute subflake URL
`github:coder/nixos-example-flake?dir=vars`, not `path:./vars`. That is
deliberate: a relative path input cannot always be resolved from a lock file
(`cannot fetch input 'path:./vars' because it uses a relative path`) and it
re-resolves on every evaluation, which makes Nix try to rewrite the lock of a
read-only remote flake on every single rebuild. If you fork this repository,
point that URL at your own fork -- or at any other trivial flake exposing a
`coderVars` attribute.

The default is never fetched when the template overrides it, so it only
affects evaluating this flake by hand.

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

To check how a configuration behaves with particular workspace values, point
`coder-vars` at a local copy:

```console
nix eval --json .#nixosConfigurations.workspace-x86_64.config \
  --override-input coder-vars path:./vars --no-write-lock-file \
  --apply 'c: { user = c.coder.user; host = c.networking.hostName; }'
```

Evaluating both attributes is worth the few seconds: the aarch64 configuration
is otherwise only exercised the first time somebody picks a Graviton instance
type.

`flake.lock` is committed on purpose. Without it every workspace resolves
nixpkgs independently at boot, which is slow and not reproducible — and a lock
file that is merely untracked is invisible to a Git flake reference, because
Nix only sees committed files.

## nixos-facter

The facter modules are upstream in nixpkgs as `hardware.facter.*`, so there is
no input to add and nothing to enable — `hardware.facter.enable` derives from
whether a report exists. `hardware/ec2.nix` picks one up automatically if you
drop it next to that file:

```console
sudo nix-shell -p nixos-facter --run 'nixos-facter -o hardware/facter.json'
```

No report is shipped, because on EC2 it measurably changes nothing. Facter
replaces the driver and kernel-module half of `hardware-configuration.nix` —
it never generates `fileSystems`, `swapDevices` or a bootloader device — and
`amazon-image.nix` already covers everything it would contribute here: its
initrd modules are all in nixpkgs' defaults, microcode and firmware are gated
on the machine being bare metal, and its virtualisation detection reports
`amazon`, which the nixpkgs module does not match. The measured delta is zero
initrd modules.

It is wired up anyway because it costs nothing when absent and is the right
tool the moment this configuration targets hardware that is not EC2.

One consequence is reflected in `flake.nix`: a report sets
`nixpkgs.hostPlatform` with `mkDefault`, which outranks the value derived from
`nixosSystem`'s `system` argument. So the platform is pinned explicitly per
configuration rather than relying on that argument — otherwise an x86_64
report would silently build an x86_64 closure for the aarch64 attribute.

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
- **Pinning `nixpkgs.hostPlatform` to the wrong value**, or removing it and
  relying on `nixosSystem`'s `system` argument while a facter report is
  present. See above.
- **Pinning `coder.uid`** without checking what else claims that UID. The EC2
  images enable `amazon-ssm-agent`, and its `ssm-user` takes the first free
  UID without regard for statically assigned ones -- so pinning the workspace
  user to 1000 yields two accounts sharing it, which silently gives an SSM
  session the workspace user's identity. `coder.uid` is null by default for
  this reason.

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
