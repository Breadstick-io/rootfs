# Breadstick-Nix's virtual machine image (4.0, plan 5.14 V4; round 9): the same configuration as the proot image
# (/etc/breadstick/nix/system.nix with local.json's "engine": "vm"), as a raw ext4 disk labeled bslroot with no
# partition table (crosvm boots the kernel and initrd beside it directly; the root is /dev/vda, grown at first boot),
# made by nixpkgs' make-disk-image. Built by vm/bake-vm-nix.sh in the nixos/nix container, never on a device.
#
#   nix-build vm-image.nix --arg nixpkgs /nix/store/...-nixpkgs --argstr system aarch64-linux
{ nixpkgs, system, configuration ? /etc/nixos/configuration.nix, breadstickNix ? /etc/breadstick/nix }:
let
  eval = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [ configuration ];
  };
  inherit (eval) config pkgs;
  lib = pkgs.lib;
  image = import (nixpkgs + "/nixos/lib/make-disk-image.nix") {
    inherit config pkgs lib;
    name = "breadstick-nix-vm";
    format = "raw";
    partitionTableType = "none";
    label = "bslroot";
    fsType = "ext4";
    diskSize = "auto";
    additionalSpace = "1024M";
    copyChannel = false;
    # /sbin/init (boot.loader.initScript): the kernel line's init= runs the newest generation.
    installBootLoader = true;
    # nixpkgs itself, so the first apply in the VM evaluates without a download (as in the proot image).
    additionalPaths = [ nixpkgs ];
    # Breadstick's own files, as the proot image has them: the configuration, its sources and the page's list.
    contents = [
      { source = breadstickNix; target = "/etc/breadstick/nix"; }
      { source = configuration; target = "/etc/nixos/configuration.nix"; }
    ];
  };
in
pkgs.runCommand "breadstick-nix-vm-files" { } ''
  mkdir -p $out
  ln -s ${image}/nixos.img $out/root.img
  ln -s ${config.system.build.kernel}/${config.system.boot.loader.kernelFile} $out/vmlinuz
  ln -s ${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile} $out/initrd.img
  echo ${config.system.build.toplevel} > $out/toplevel
  echo ${config.boot.kernelPackages.kernel.modDirVersion} > $out/kernel-version
  echo ${nixpkgs} > $out/nixpkgs
''
