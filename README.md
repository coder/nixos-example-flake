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
| `hardware/ec2.nix` | platform | imports `amazon-image.nix` |
| `coder-modules` input | Coder | the agent unit, the workspace user, shutdown staging |

The Coder integration is not in this repository. It lives in
[coder/nixos-modules](https://github.com/coder/nixos-modules) and arrives as
one input and one import — which is all adopting it in a configuration of your
own takes:

```nix
inputs.coder-modules.url = "github:coder/nixos-modules";
# ...
modules = [ coder-modules.nixosModules.default ./configuration.nix ];
```

That repository's README documents every `coder.*` option, the agent handoff
and the shutdown hook. `flake.nix` and `configuration.nix` contain no
Coder-specific settings beyond the import and `coder.flakeAttr`, and there are
no injected evaluation inputs, so this flake builds identically by hand and
under the template.

One consequence worth knowing: a workspace resolves two flake inputs at boot
instead of one. Both are pinned in `flake.lock` and fetched exactly as nixpkgs
already was, but an instance behind a restrictive egress policy now needs
`github.com/coder/nixos-modules` reachable as well.

## Which configuration gets applied

The attribute after `#` in the flake reference selects it:

```console
nixos-rebuild switch --flake 'github:coder/nixos-example-flake#coder-workspace-x86_64'
```

This repository ships `coder-workspace-x86_64` and `coder-workspace-aarch64`. The template
derives the name from the chosen EC2 instance type, so the AMI architecture,
`coder_agent.arch` and the attribute always agree. Add your own entries to
`nixosConfigurations` and point the template's `flake_attr` variable at them —
it accepts an `$ARCH` placeholder (`coder-workspace-$ARCH`) if you keep the
per-architecture split, or a fixed name if you do not.

## Where the configuration lives on the workspace

The template checks this repository out at **`/etc/nixos`** and builds from
there, which means the conventional command works with no arguments:

```console
sudo nixos-rebuild switch
```

`nixos-rebuild` finds `/etc/nixos/flake.nix` by itself. The explicit form is
equivalent:

```console
sudo nixos-rebuild switch --flake /etc/nixos#coder-workspace-x86_64
```

There are no overrides, no `--impure` and no injected inputs, so what you get
by hand is exactly what the template applies.

The checkout is owned by the workspace user, so editing needs no `sudo`. On
every boot the template syncs it:

| state of `/etc/nixos` | what happens |
| --- | --- |
| missing | cloned at the configured ref |
| clean, on the tracking branch | fast-forwarded to the remote |
| dirty, or carrying local commits | **left alone**, and built as-is |

So it tracks upstream by default, and the moment you edit it the machine is
yours until you clean up. A workspace whose configuration silently reverted on
restart would be worse than one that drifts.

One caveat worth knowing: a flake built from a git checkout ignores
**untracked** files. If you add a new `.nix` file, `git add` it or the rebuild
will not see it — this is the single most confusing thing about editing a
flake in place.

## The workspace user

The agent runs as `coder.user.name` — `coder` by default — and the modules
declare the account, including `wheel` for passwordless `sudo nixos-rebuild`.
Set `coder.user.create = false` if the account is yours to declare instead;
see [coder/nixos-modules](https://github.com/coder/nixos-modules#the-workspace-user).

## Per-workspace values

Nothing is injected at evaluation time. Facts about the workspace are written
to **`/run/coder/workspace.json`** on every boot, for a configuration to read
at *runtime* if it wants them:

```json
{
  "workspace": "my-workspace",
  "owner": "jdoe",
  "owner_name": "J Doe",
  "owner_email": "jdoe@example.com",
  "access_url": "https://coder.example.com",
  "hostname": "my-workspace"
}
```

Runtime, not evaluation, because a flake cannot read an absolute path outside
itself in pure evaluation mode — consuming it at eval time would require
`--impure` and break the by-hand rebuild above. Read it from a systemd service
or a script instead.

> **Never put a secret there, or anywhere Nix can see.** Anything in the Nix
> store is world-readable to every process on the workspace and persists
> across generations. The agent token is passed through `/run/coder/agent.env`
> at mode 0600 for exactly this reason.

Git identity is not set by this flake: the template supplies it through the
registry's `git-config` module, which works against any configuration.

## Keeping the machine current

There is no timer. A workspace rebuilds from this flake when it boots, so
picking up a change means restarting the workspace — or running
`sudo nixos-rebuild switch` inside it.

If you want a schedule, `system.autoUpgrade` is upstream's and belongs in
`configuration.nix`, where the machine's owner can see it. Order it behind
whatever does the boot-time rebuild (`amazon-init.service` on EC2) and have it
sync `/etc/nixos` first: `--refresh` does nothing for a local path flake, so a
checkout that is behind its remote would rebuild unchanged forever.

## Staging the next generation at shutdown

A stop builds the next generation before it finishes, so the next start boots
it rather than building it — best effort, never a correctness mechanism, since
the boot path rebuilds whenever the configuration changed anyway.
`coder.stageOnShutdown.enable` turns it off. How it manages to run work during
shutdown at all is documented in
[coder/nixos-modules](https://github.com/coder/nixos-modules#staging-the-next-generation-at-shutdown).

## Verifying a change before you push

A broken commit is a broken workspace. Evaluation catches essentially every
module and option error:

```console
nix eval --raw .#nixosConfigurations.coder-workspace-x86_64.config.system.build.toplevel.drvPath
nix eval --raw .#nixosConfigurations.coder-workspace-aarch64.config.system.build.toplevel.drvPath
nix build .#toplevel            # builds the closure for your native arch
```

Evaluating both attributes is worth the few seconds: the aarch64 configuration
is otherwise only exercised the first time somebody picks a Graviton instance
type.

`flake.lock` is committed on purpose. Without it every workspace resolves
nixpkgs independently at boot, which is slow and not reproducible — and a lock
file that is merely untracked is invisible to a Git flake reference, because
Nix only sees committed files.

## nixos-facter: considered, not used

There is no facter report here on purpose. Facter replaces the driver and
kernel-module half of `hardware-configuration.nix` — it never generates
`fileSystems`, `swapDevices` or a bootloader device — and on EC2
`amazon-image.nix` already covers everything it would contribute: its initrd
modules are all in nixpkgs' defaults, microcode and firmware are gated on the
machine being bare metal, and its virtualisation detection reports `amazon`,
which the nixpkgs module does not match. The measured delta of adding a report
to this configuration was **zero initrd modules**, against the cost of a
per-architecture blob that has to be regenerated on a real instance.

The modules are upstream in nixpkgs as `hardware.facter.*`, so if you retarget
this configuration at hardware that is not EC2, all you need is
`hardware.facter.reportPath = ./facter.json`.

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
- **Removing the explicit `nixpkgs.hostPlatform`** and relying on
  `nixosSystem`'s `system` argument. Hardware-detection modules can outrank
  that argument with a `mkDefault` of their own, which silently builds the
  wrong architecture.
- **Adding `wantedBy = [ "multi-user.target" ]` to `coder-agent.service`.**
  The unit is started by the workspace boot script, after the rebuild that
  boot script drives has finished. Let systemd start it instead and, on every
  boot after the first, the agent connects and runs the workspace's startup
  scripts against the generation that is about to be replaced -- tools
  installed into a system with seconds to live, and a workspace reported
  ready minutes before it is.
- **Pinning `coder.user.uid`** without checking what else claims that UID. The EC2
  images enable `amazon-ssm-agent`, and its `ssm-user` takes the first free
  UID without regard for statically assigned ones -- so pinning the workspace
  user to 1000 yields two accounts sharing it, which silently gives an SSM
  session the workspace user's identity. `coder.user.uid` is null by default for
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

Note that a generation booted by hand (a GRUB entry, `--rollback` followed by
a reboot) comes up without an agent, because nothing but the workspace boot
script starts one. `sudo systemctl start coder-agent` is enough as long as
`/run/coder` was populated on that boot.

To see what happened on a boot you cannot reach, the AMI logs to the serial
console:

```console
aws ec2 get-console-output --instance-id i-0123456789abcdef0 --output text
```

