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
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];

  # The running kernel comes from this flake's nixpkgs pin, not the AMI, and
  # only changes on reboot. `boot.kernelModules` is for runtime additions;
  # `availableKernelModules` is the platform's business.
  boot.kernelModules = [ ];
}
