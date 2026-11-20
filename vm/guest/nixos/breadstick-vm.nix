# The Breadstick VM guest as a NixOS module (plan 5.14 V5): what vm/guest/install.sh puts into a Debian, Fedora or
# Arch image, in NixOS's own terms. Written 2026-11-14; built into the Nix VM image (bootstrap-nix.sh vm) since round 9.
#
#   imports = [ ./breadstick-vm.nix ];
#   breadstick.vm.enable = true;
#
# The three programs are the same C sources as every other image's, built by Nix against its own libc (a static
# build is only needed where one binary serves several distributions). The agent finds NixOS by /etc/NIXOS and gives
# commands NixOS's PATH, and runs /run/current-system/sw/bin/systemctl for power (bsl-vmagent.c).
{ config, lib, pkgs, ... }:

let
  cfg = config.breadstick.vm;

  guest = pkgs.stdenv.mkDerivation {
    pname = "breadstick-vm-guest";
    version = "2";
    src = lib.cleanSource ./..;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      for p in bsl-vmagent bsl-vmnet bsl-x11-relay; do
        $CC -O2 -Wall -pthread -o $p $p.c
      done
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 -t $out/lib/breadstick-vm bsl-vmagent bsl-vmnet bsl-x11-relay files/vmnet-setup
      install -Dm644 files/vmnet.nft $out/lib/breadstick-vm/vmnet.nft
      install -Dm644 files/vmnet-containers.nft $out/lib/breadstick-vm/vmnet-containers.nft
      runHook postInstall
    '';
    meta.platforms = [ "aarch64-linux" "x86_64-linux" ];
  };

  bin = "${guest}/lib/breadstick-vm";
  # Never the out-of-memory killer's pick: a game running Linux out of memory must not cut the app off.
  keep = { Restart = "always"; RestartSec = 1; OOMScoreAdjust = -1000; };
  noTap = { ConditionKernelCommandLine = "!bsl.net=tap"; };
  # A switch never stops or restarts the guest's own units; a changed one takes over at the next boot. Round 9 review:
  # NixOS gives every unit systemd.globalEnvironment (LOCALE_ARCHIVE), so a language added or an Updates run that moved
  # nixpkgs changed all of them, and switch-to-configuration stopped the relay, the network and the agent. Stopping the
  # agent ends everything the app started in its unit, the switch itself included (bsl-nix now runs it in a unit of its
  # own as well), so nothing was started again and the app lost the VM until a hard reset. Stopped on purpose,
  # Restart=always does nothing.
  notOnSwitch = { restartIfChanged = false; stopIfChanged = false; };
in
{
  options.breadstick.vm.enable = lib.mkEnableOption "the Breadstick VM guest (agent on vsock 5000, networking through the app, display relay)";

  config = lib.mkIf cfg.enable {
    # files/modules.conf, and bake-vm.sh's initramfs modules.
    boot.kernelModules = [ "vmw_vsock_virtio_transport" "dummy" "nf_tables" "nft_redir" ];
    boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_console" "virtio_balloon" "vmw_vsock_virtio_transport" "ext4" ];

    # files/fstab: the app grows the disk file, systemd grows the file system at boot.
    fileSystems."/" = lib.mkDefault { device = "/dev/disk/by-label/bslroot"; fsType = "ext4"; options = [ "discard" ]; autoResize = true; };

    # files/bsl-vmagent.service. Every program the app starts runs in this unit: OOMPolicy=continue keeps one
    # program killed for memory from ending the desktop with it (Lenovo, 2026-10-07).
    systemd.services.bsl-vmagent = notOnSwitch // {
      description = "Breadstick VM agent (vsock 5000, host only)";
      unitConfig.DefaultDependencies = false;
      after = [ "systemd-modules-load.service" "local-fs.target" ];
      before = [ "sysinit.target" ];
      wantedBy = [ "sysinit.target" ];
      serviceConfig = keep // { ExecStart = "${bin}/bsl-vmagent 5000"; OOMPolicy = "continue"; };
    };

    # files/bsl-vmnet-setup.service: the dummy route and the nftables redirect, with the tools on its PATH.
    systemd.services.bsl-vmnet-setup = notOnSwitch // {
      description = "Breadstick VM network routes (dummy bsl0, nftables redirect)";
      unitConfig = noTap // { DefaultDependencies = false; };
      after = [ "systemd-modules-load.service" "systemd-tmpfiles-setup.service" ];
      before = [ "network.target" "bsl-vmnet.service" ];
      wantedBy = [ "multi-user.target" ];
      path = [ pkgs.iproute2 pkgs.nftables pkgs.coreutils ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = "${bin}/vmnet-setup"; };
    };

    systemd.services.bsl-vmnet = notOnSwitch // {
      description = "Breadstick VM networking through the app (vsock 5100)";
      unitConfig = noTap;
      after = [ "bsl-vmnet-setup.service" ];
      requires = [ "bsl-vmnet-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = keep // { ExecStart = "${bin}/bsl-vmnet 5100 15001 53"; };
    };

    systemd.services.bsl-x11-relay = notOnSwitch // {
      description = "Breadstick VM display relay (vsock 6000 <-> /tmp/.X11-unix/X0)";
      after = [ "local-fs.target" "systemd-tmpfiles-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = keep // { ExecStart = "${bin}/bsl-x11-relay 6000 /tmp/.X11-unix/X0"; };
    };

    # vmnet-setup writes /etc/resolv.conf (DNS through the app): nothing else may own it.
    networking.resolvconf.enable = lib.mkDefault false;
    networking.useDHCP = lib.mkDefault false;
    networking.firewall.enable = lib.mkDefault false;

    # files/zram-generator.conf, files/journald.conf.
    zramSwap = { enable = lib.mkDefault true; memoryPercent = 50; algorithm = "zstd"; priority = 100; };
    services.journald.extraConfig = ''
      SystemMaxUse=64M
      RuntimeMaxUse=32M
    '';

    # files/sudoers: wheel (where the VM's account step puts the app's user: VmCommands.userScript's useradd -G wheel;
    # the account is never a users.users entry, module.nix keeps it at every activation) runs anything without a
    # password, as in the Standard engine.
    security.sudo.wheelNeedsPassword = false;

    # files/profile.sh, for shells opened in the VM (Terminal tabs, SSH).
    environment.extraInit = ''
      [ -z "$DISPLAY" ] && export DISPLAY=:0
      export NO_AT_BRIDGE=1
      export LIBGL_KOPPER_DISABLE=1
      export MESA_VK_WSI_DEBUG=noshm
    '';
    # files/terminal.sh (V9: a Terminal tab gets the agent's runtime dir and bus back after Stop), after the Breadstick
    # module's breadstick-terminal.sh in /etc/bashrc, whose hook it wraps.
    environment.interactiveShellInit = lib.mkAfter (builtins.readFile ../files/terminal.sh);

    # The kernel and initrd come from the app (crosvm boots them directly, no bootloader), and NixOS's stage 1 needs
    # init= on the kernel line. The image's own pair boots with `init=/nix/var/nix/profiles/system/init` in its
    # manifest's cmdline (V4; round 9: NixOS 26.05's systemd stage 1 resolves that link to the newest generation, what
    # `nixos-rebuild boot` or `switch` made the next boot, and takes its folder as the closure; /sbin/init, which
    # initScript still writes for anything else that wants one, is a script, no closure to it). No root= beside it: stage
    # 1 mounts / from fileSystems below, and a root= is a second sysroot.mount. A
    # pair the app copied from the disk names its own generation's init (Android VmCommands.BOOT_PAIR_SCRIPT, the 7th
    # word), which the app puts in place of the manifest's (VmSizing.params), so kernel and generation always match.
    boot.loader.grub.enable = lib.mkDefault false;
    boot.loader.initScript.enable = lib.mkDefault true;

    # The agent hands commands to /bin/sh (NixOS keeps it: environment.binsh).
    systemd.services.systemd-networkd-wait-online.enable = lib.mkDefault false;
  };
}
