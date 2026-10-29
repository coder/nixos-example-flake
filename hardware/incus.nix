# Incus VM platform glue, mirroring what the `images:nixos/*` VM images ship.
#
# `incus-virtual-machine.nix` declares the root filesystem, the bootloader and
# the Incus agent. The template runs every workspace start through that agent,
# so without it `nixos-rebuild switch` succeeds and the next start never
# reaches the machine. Do not drop it, and do not override `fileSystems."/"`,
# `boot.loader.*` or `virtualisation.incus.agent.enable` anywhere here.
#
# The image configures networking through systemd-networkd rather than the
# NixOS default of dhcpcd; keep it so a rebuild does not drop the address the
# running agent connected over.
{ lib, modulesPath, ... }:
{
  imports = [ "${modulesPath}/virtualisation/incus-virtual-machine.nix" ];

  networking = {
    # Empty, as on EC2: the template sets the workspace name at boot, and a
    # static name here would overwrite it on every rebuild.
    hostName = lib.mkDefault "";
    dhcpcd.enable = false;
    useDHCP = false;
    useHostResolvConf = false;
  };

  systemd.network = {
    enable = true;
    networks."50-enp5s0" = {
      matchConfig.Name = "enp5s0";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };
}
