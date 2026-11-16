nft -f - <<'BSL_NFT_HOSTPORTS'
table ip breadstick_vm_host
delete table ip breadstick_vm_host
table ip breadstick_vm_host {
  chain output {
    type nat hook output priority -100; policy accept;
    ip daddr 127.0.0.1 tcp dport { 18766 } redirect to :15001
  }
}
BSL_NFT_HOSTPORTS
