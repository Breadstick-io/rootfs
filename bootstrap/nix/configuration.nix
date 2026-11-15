# Your NixOS configuration. Breadstick's own settings and the packages from the Nix packages page come in
# through /etc/breadstick/nix/system.nix; add your own below, then apply them from Settings > Nix packages
# (or run `sudo bsl-nix apply`). See configuration.nix(5) and https://nixos.org/manual/nixos/stable/.
{ config, pkgs, ... }:
{
  imports = [ /etc/breadstick/nix/system.nix ];

  # environment.systemPackages = with pkgs; [ ];
}
