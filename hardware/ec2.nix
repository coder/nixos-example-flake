# EC2 platform glue.
#
# Importing `amazon-image.nix` is mandatory and is the single most
# load-bearing line in this repository. It declares:
#
#   * fileSystems."/"                  label `nixos`, autoResize = true
#   * boot.growPartition               so a resized EBS volume is picked up
#   * the bootloader                   GRUB: BIOS /dev/xvda on x86_64,
#                                      EFI nodev on aarch64
#   * boot.initrd.availableKernelModules for both Xen and Nitro (ENA, NVMe)
#   * console=ttyS0                    so `aws ec2 get-console-output` works
#   * amazon-init.service              reads /etc/ec2-metadata/user-data and,
#                                      when it starts with `#!`, execs it as a
#                                      shell script - after multi-user.target,
#                                      on every boot
#   * ec2-data.nix                     installs the EC2 key pair for root and
#                                      derives the hostname from metadata
#   * amazon-ssm-agent                 a rescue path needing no inbound rules
#
# Drop the import and `nixos-rebuild switch` produces a generation with no
# root filesystem and no bootloader: the switch succeeds, and the next reboot
# never comes back.
#
# Three things must NOT be overridden anywhere in this repository:
#
#   * fileSystems."/"                  conflicts with the platform module
#   * boot.loader.*                    a conflict yields a switch that
#                                      *succeeds* and a reboot that fails an
#                                      hour later, when a workspace restarts
#   * boot.initrd.availableKernelModules
#                                      replacing (rather than extending) it
#                                      drops EBS support on one of Xen/Nitro
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];

  # The running kernel comes from this flake's nixpkgs pin, not from the AMI,
  # and only changes on reboot. `boot.kernelModules` is the right knob for
  # runtime additions; `availableKernelModules` is the platform's business.
  boot.kernelModules = [ ];
}
