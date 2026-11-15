# Breadstick-Nix: what /etc/nixos/configuration.nix imports (4.0, plan 5.9). Breadstick's file, written by the
# image's bake and by Breadstick's updates; never edited by hand (put your own settings in configuration.nix).
#
#   local.json      this system's own settings (the engine, the Linux account, the NixOS release it started on, the
#                   user's languages), written by the bake, `bsl-nix account` and `bsl-nix languages`. The engine is the
#                   bake's: a system does not move between engines yet (a backup restores only on its own engine)
#   breadstick.nix  the packages the Nix packages page manages (packages.json), in Settings and Linux Settings
#   module/         Breadstick's NixOS module and package overlay (packages' breadstick-nix/nix)
#   src/            Breadstick's package sources the overlay builds (no binary cache serves them yet)
#   vm-guest/       the virtual machine guest (rootfs vm/guest), used when the engine is "vm"
#   nixpkgs         the nixpkgs this system evaluates (a link into the store, pinned; `bsl-nix update` moves it)
{ lib, ... }:
let
  local = builtins.fromJSON (builtins.readFile ./local.json);
in
{
  imports = [ ./module/module.nix ./vm-guest/nixos/breadstick-vm.nix ./breadstick.nix ];
  breadstick.engine = local.engine or "proot";
  breadstick.user = local.user or "";
  breadstick.desktop = local.desktop or true;
  breadstick.imageTrim = local.imageTrim or false;
  breadstick.locales = local.locales or [ ];
  system.stateVersion = local.stateVersion;
}
