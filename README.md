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
| `modules/coder/index.nix` | Coder | the single import that wires the agent in |
| `modules/coder/options.nix` | Coder | `options.coder.*` |
| `modules/coder/agent.nix` | Coder | the `coder-agent.service` unit and `coder` on PATH |
| `modules/coder/user.nix` | Coder | workspace user, sudo, `nix-ld` |
| `modules/coder/stage-on-shutdown.nix` | Coder | builds the next generation at shutdown |

`flake.nix` and `configuration.nix` contain no Coder-specific settings: the
integration is one import, and `configuration.nix` does not mention `coder.*`
at all. There are no injected evaluation inputs, so this flake builds
identically by hand and under the template. `modules/coder/` is self-contained
and is intended to move to its own flake (`github:coder/nixos-coder`). When it
does, adopting it in an existing configuration is a two-line change:

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

## Where the configuration lives on the workspace

The template checks this repository out at **`/etc/nixos`** and builds from
there, which means the conventional command works with no arguments:

```console
sudo nixos-rebuild switch
```

`nixos-rebuild` finds `/etc/nixos/flake.nix` by itself. The explicit form is
equivalent:

```console
sudo nixos-rebuild switch --flake /etc/nixos#workspace-x86_64
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

## Staging the next generation at shutdown

`modules/coder/stage-on-shutdown.nix` builds the next generation while the
workspace is powering off, so the next start boots it instead of building it.
`coder.stageOnShutdown.enable` turns it off; `timeoutSec` bounds it.

It is **best effort and never a correctness mechanism** — the boot path
rebuilds whenever the configuration changed, so the next boot lands on the
right generation regardless. Two things make it unusual, and both are
deliberate:

- The work is in `ExecStop` on a `RemainAfterExit` oneshot, not a unit started
  at shutdown. Every unit gets an implicit `Conflicts=shutdown.target`, so a
  unit *started* during shutdown is killed mid-run and `DefaultDependencies`
  does not save it. systemd does, however, block on `ExecStop`.
- It is ordered `after` `network.target` and `nix-daemon.service`. Units stop
  in reverse start order, so this stops *before* they do, while a rebuild can
  still fetch and build.
- It does not call `nixos-rebuild boot`. `nixos-rebuild` runs
  `switch-to-configuration` inside a transient `systemd-run` unit, and starting
  any unit once `shutdown.target` is queued is refused as a destructive
  transaction — the build would succeed and the generation would silently never
  become the boot default. The script therefore does the three steps `boot`
  means itself: build the toplevel, point the system profile at it, and run
  `switch-to-configuration boot` directly.

Coder itself cannot wait for anything at stop — its agent protocol has no
shutdown RPC, and the SIGTERM that would trigger a stop script only arrives
because the stop already happened. So this is a systemd mechanism, not a Coder
one. EC2 also does not document how long it tolerates a graceful shutdown, so
`timeoutSec` is an upper bound on our side rather than a promise. Measured on a
`t3.medium` in `eu-west-3`: a stop that staged a small generation took 93s end
to end, against 99s for a stop with nothing to do — the staging is lost in the
noise of the stop itself. When the checkout is clean, unchanged since the last
rebuild and already activated, the unit exits in milliseconds without touching
Nix at all, so an ordinary stop is never slower for it.

## Verifying a change before you push

A broken commit is a broken workspace. Evaluation catches essentially every
module and option error:

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

Note that a generation booted by hand (a GRUB entry, `--rollback` followed by
a reboot) comes up without an agent, because nothing but the workspace boot
script starts one. `sudo systemctl start coder-agent` is enough as long as
`/run/coder` was populated on that boot.

To see what happened on a boot you cannot reach, the AMI logs to the serial
console:

```console
aws ec2 get-console-output --instance-id i-0123456789abcdef0 --output text
```

