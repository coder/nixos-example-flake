# EC2 platform glue: one import, and it is the most load-bearing line here.
#
# `amazon-image.nix` declares the root filesystem, the bootloader, the
# Nitro/Xen initrd modules, the serial console, SSH and `amazon-init.service`.
# Without it `nixos-rebuild switch` succeeds and the instance never comes
# back, so do not drop it and do not override `fileSystems."/"`,
# `boot.loader.*` or `boot.initrd.availableKernelModules` anywhere in this
# repository.
{ modulesPath, ... }:
{
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];
}
