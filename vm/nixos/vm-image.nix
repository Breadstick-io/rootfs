# Breadstick-Nix's virtual machine image (4.0, plan 5.14 V4; round 9): the same configuration as the proot image
# (/etc/breadstick/nix/system.nix with local.json's "engine": "vm"), as a raw ext4 disk labeled bslroot with no
# partition table (crosvm boots the kernel and initrd beside it directly; the root is /dev/vda, grown at first boot),
# made by nixpkgs' make-disk-image. Built by vm/bake-vm-nix.sh in the nixos/nix container, never on a device.
#
#   nix-build vm-image.nix --argstr nixpkgs /nix/store/...-nixpkgs --argstr system aarch64-linux
{ nixpkgs, system, configuration ? /etc/nixos/configuration.nix, breadstickNix ? /etc/breadstick/nix }:
let
  # The store path itself, never a copy of it: a path value would be imported again under another name (round 9: the
  # disk then held <hash>-<hash>-nixpkgs-... and /etc/breadstick/nix/nixpkgs pointed at nothing).
  np = builtins.storePath nixpkgs;
  eval = import (np + "/nixos/lib/eval-config.nix") {
    inherit system;
    modules = [ configuration ];
  };
  inherit (eval) config pkgs;
  lib = pkgs.lib;
  image = import (np + "/nixos/lib/make-disk-image.nix") {
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
    additionalPaths = [ np ];
    # Breadstick's own files, as the proot image has them: the configuration, its sources and the page's list.
    contents = [
      # Writable by root, as on the proot image (bsl-nix edits packages.json and local.json): copied from the store,
      # every file would be read-only.
      { source = breadstickNix; target = "/etc/breadstick/nix"; mode = "u+w"; }
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
  echo ${np} > $out/nixpkgs
''
