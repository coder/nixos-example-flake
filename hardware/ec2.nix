# EC2 platform glue.
#
# Importing `amazon-image.nix` is mandatory and is the most load-bearing line
# in this repository. It declares the root filesystem (label `nixos`, with
# `autoResize`), `boot.growPartition`, the bootloader (GRUB: BIOS on x86_64,
# EFI on aarch64), the Nitro/Xen initrd modules, `console=ttyS0`, OpenSSH,
# `amazon-ssm-agent`, and `amazon-init.service` -- which reads
# /etc/ec2-metadata/user-data and execs it when it starts with `#!`.
#
# Drop the import and `nixos-rebuild switch` produces a generation with no
# root filesystem and no bootloader: the switch succeeds, and the instance
# never comes back.
#
# Do not override any of these anywhere in this repository:
#   * fileSystems."/"                        conflicts with the platform module
#   * boot.loader.*                          a conflict gives a switch that
#                                            succeeds and a reboot that fails
#   * boot.initrd.availableKernelModules     replacing rather than extending it
#                                            drops EBS on one of Xen/Nitro
{ lib, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
  ]
  # nixos-facter, optional and absent by default.
  #
  # The modules are upstream in nixpkgs (`hardware.facter.*`, in
  # module-list.nix), so there is no input to add and nothing to enable:
  # `hardware.facter.enable` derives from whether a report exists. Drop a
  # report here to turn it on:
  #
  #   sudo nix-shell -p nixos-facter --run 'nixos-facter -o facter.json'
  #
  # It is deliberately not shipped, because on EC2 it measurably does nothing.
  # Facter replaces the driver/kernel-module half of hardware-configuration.nix
  # -- it never generates `fileSystems`, `swapDevices` or a bootloader device
  # -- and every module it would contribute here is already covered:
  #
  #   * its disk/keyboard initrd modules (ahci, nvme, xhci_pci) are all in
  #     nixpkgs' default initrd list, and amazon-image.nix adds nvme itself;
  #   * microcode and redistributable firmware are gated on the machine being
  #     bare metal, and a guest cannot load microcode anyway;
  #   * its virtualisation detection reports `amazon`/`xen`, which the nixpkgs
  #     facter module does not match, so it is inert.
  #
  # Measured delta of adding a report to this configuration: zero initrd
  # modules. Against that it costs a ~175 KB per-architecture blob that must
  # be regenerated on a real instance, and a per-instance report would give
  # every workspace a unique system derivation, destroying binary-cache reuse.
  #
  # Worth having wired up for non-EC2 targets, where it earns its keep.
  ++ lib.optional (builtins.pathExists ./facter.json) {
    hardware.facter.reportPath = ./facter.json;
  };

  # The running kernel comes from this flake's nixpkgs pin, not the AMI, and
  # only changes on reboot. `boot.kernelModules` is for runtime additions;
  # `availableKernelModules` is the platform's business.
  boot.kernelModules = [ ];
}
