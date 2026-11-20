bsl_m=; if [ -r /usr/lib/breadstick/bsl-os.sh ] && . /usr/lib/breadstick/bsl-os.sh && command -v bsl_pkg_mark >/dev/null 2>&1 && command -v bsl_pkg_also >/dev/null 2>&1 && bsl_pkg_mark install; then bsl_m=1; fi
( [ -z "$bsl_m" ] || bsl_pkg_also $$
set -e
if [ "$(cat /proc/1/comm 2>/dev/null)" != systemd ] || [ ! -d /usr/lib/breadstick-vm ]; then echo 'Docker needs the VM engine. Nothing was installed.'; exit 1; fi
echo '[1/3] Installing Docker...'
{ B=; grep -qs '^\[breadstick' /etc/yum.repos.d/*.repo /etc/distro.repos.d/*.repo /usr/share/dnf5/repos.d/*.repo && B='breadstick*.'; dnf -y makecache --refresh "--setopt=${B}skip_if_unavailable=True"; }
{ if [ -r /usr/lib/breadstick/bsl-os.sh ]; then n=$(. /usr/lib/breadstick/bsl-os.sh && bsl_pkg_names moby-engine docker-cli docker-compose docker-buildx | tr '\n' ' ') || n='moby-engine docker-cli docker-compose docker-buildx'; else n='moby-engine docker-cli docker-compose docker-buildx'; fi; if [ -z "${n# }" ]; then echo '[BSL] This Linux instance has no package for this; nothing was installed.' >&2; (exit 1); else . /usr/lib/breadstick/bsl-os.sh && bsl_pkg_install moby-engine docker-cli docker-compose docker-buildx; fi; }
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
