bsl_m=; if [ -r /usr/lib/breadstick/bsl-os.sh ] && . /usr/lib/breadstick/bsl-os.sh && command -v bsl_pkg_mark >/dev/null 2>&1 && command -v bsl_pkg_also >/dev/null 2>&1 && bsl_pkg_mark install; then bsl_m=1; fi
( [ -z "$bsl_m" ] || bsl_pkg_also $$
set -e
if [ "$(cat /proc/1/comm 2>/dev/null)" != systemd ] || [ ! -d /usr/lib/breadstick-vm ]; then echo 'Docker needs the virtual machine engine. Nothing was installed.'; exit 1; fi
echo '[1/3] Installing Docker...'
true
{ if [ -r /usr/lib/breadstick/bsl-os.sh ]; then n=$(. /usr/lib/breadstick/bsl-os.sh && bsl_pkg_names docker docker-compose docker-buildx | tr '\n' ' ') || n='docker docker-compose docker-buildx'; else n='docker docker-compose docker-buildx'; fi; s=0; T=; if [ -z "${n# }" ]; then s=1; echo '[BSL] This Linux instance has no package for this; nothing was installed.' >&2; elif [ -e /var/lib/pacman/db.lck ]; then s=1; echo '[BSL] Another package operation is running or was interrupted; nothing was installed or upgraded.' >&2; elif ! { T=$(mktemp -d) && chmod 755 "$T" && mkdir -p "$T/db/sync" && ln -s /var/lib/pacman/local "$T/db/local"; }; then s=1; else cp -p /var/lib/pacman/sync/*.db* "$T/db/sync/" 2>/dev/null || true; if ! pacman -Sy --dbpath "$T/db" --logfile /dev/null >/dev/null; then s=1; echo '[BSL] The package databases could not be refreshed; nothing was installed or upgraded.' >&2; elif ! pacman -Sup --needed --dbpath "$T/db" --logfile /dev/null $n >/dev/null; then s=1; echo '[BSL] pacman cannot install this from the repositories of this Linux instance; nothing was installed or upgraded.' >&2; else c=0; for f in "$T"/db/sync/*.db*; do if [ -f "$f" ]; then cp -p "$f" /var/lib/pacman/sync/ || c=1; fi; done; if [ $c = 0 ]; then if [ -r /usr/lib/breadstick/bsl-os.sh ] && (. /usr/lib/breadstick/bsl-os.sh && command -v bsl_pkg_run >/dev/null 2>&1); then (. /usr/lib/breadstick/bsl-os.sh && bsl_pkg_run install pacman -Su --needed --noconfirm $n); else pacman -Su --needed --noconfirm $n; fi || s=$?; else s=1; fi; fi; fi; if [ -n "$T" ]; then rm -f "$T/db/local" "$T/db/db.lck" "$T"/db/sync/*; rmdir "$T/db/sync" "$T/db" "$T" 2>/dev/null || true; fi; (exit $s); }
echo '[2/3] Setting up the network for containers...'
if ! grep -qw 'bsl.net=tap' /proc/cmdline 2>/dev/null && [ ! -f /usr/lib/breadstick-vm/vmnet-containers.nft ]; then
mkdir -p /etc/breadstick-vm
cat > /etc/breadstick-vm/vmnet-containers.nft <<'BSL_NFT_CONTAINERS'
# Breadstick VM: containers reach the network through bsl-vmnet too (Docker's and Podman's bridges, 4.0).
# Their packets are FORWARDED, never "output" (vmnet.nft), and the dummy interface would swallow them. What a
# container sends to an address this machine would route to bsl0 goes to bsl-vmnet: TCP to its port, DNS to its
# resolver (Docker gives containers 8.8.8.8 when the host's resolver is a loopback address, and UDP other than DNS is
# not carried). IPv4 only, as the VM is. bsl-vmnet listens on 127.0.0.1, which a packet from another interface reaches
# only with route_localnet (vmnet-setup sets it); "guard" keeps that from opening this machine's own loopback
# services to a container that sends to 127.0.0.0/8 itself.
# A table of its own, loaded after vmnet.nft: a kernel that cannot take these rules still has its network.
# Android's copy (Containers.NETWORK_RULES) must stay this text: the app loads it where an image has none.
table inet breadstick_vm_containers
delete table inet breadstick_vm_containers
table inet breadstick_vm_containers {
  chain guard {
    type filter hook prerouting priority raw; policy accept;
    iifname != "lo" ip daddr 127.0.0.0/8 drop
  }
  chain forwarded {
    type nat hook prerouting priority -110; policy accept;
    iifname != "lo" fib daddr oifname "bsl0" meta nfproto ipv4 meta l4proto tcp dnat ip to 127.0.0.1:15001
    iifname != "lo" fib daddr oifname "bsl0" meta nfproto ipv4 udp dport 53 dnat ip to 127.0.0.1:53
  }
}
BSL_NFT_CONTAINERS
cat > /etc/systemd/system/bsl-vmnet-containers.service <<'BSL_UNIT_CONTAINERS'
[Unit]
Description=Breadstick VM network for containers (an image from before 4.0)
After=bsl-vmnet-setup.service
Before=docker.service
ConditionKernelCommandLine=!bsl.net=tap

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'nft -f /etc/breadstick-vm/vmnet-containers.nft && echo 1 > /proc/sys/net/ipv4/conf/all/route_localnet'

[Install]
WantedBy=multi-user.target
BSL_UNIT_CONTAINERS
systemctl daemon-reload
systemctl enable bsl-vmnet-containers.service >/dev/null 2>&1
systemctl restart bsl-vmnet-containers.service
fi
echo '[3/3] Starting Docker...'
getent group docker >/dev/null 2>&1 || groupadd -r docker
for u in $(awk -F: '$3 >= 1000 && $3 < 60000 { print $1 }' /etc/passwd); do usermod -aG docker "$u" || true; done
systemctl enable --now docker.service >/dev/null 2>&1 || systemctl start docker.service
docker info >/dev/null
echo 'Docker is ready.'
); bsl_rc=$?; [ -z "$bsl_m" ] || bsl_pkg_unmark $bsl_rc; exit $bsl_rc
