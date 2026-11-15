# Breadstick-Nix: the packages the Nix packages page manages (Settings > Nix packages, in the app and in Linux
# Settings). The list is packages.json beside this file, which the page edits; this file only reads it. Your own
# packages and settings go in /etc/nixos/configuration.nix, which the page never touches.
{ lib, ... }:
let
  managed = builtins.fromJSON (builtins.readFile ./packages.json);
in
{
  breadstick.packages = managed.packages or [ ];
}
