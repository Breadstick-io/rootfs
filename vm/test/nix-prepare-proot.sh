set -eu
export NIX_PATH="nixpkgs=/etc/breadstick/nix/nixpkgs:nixos-config=/etc/nixos/configuration.nix"
export PATH="/run/current-system/sw/bin:$PATH"
rm -f /nix/var/nix/gcroots/breadstick-engine-proot
cfg=$(mktemp /tmp/bsl-engine-proot.XXXXXX)
mv "$cfg" "$cfg.nix"; cfg="$cfg.nix"
printf '%s\n' '{ lib, ... }: { imports = [ /etc/nixos/configuration.nix ]; breadstick.engine = lib.mkForce "proot"; }' > "$cfg"
sys=$(nix-build '<nixpkgs/nixos>' -A system --arg configuration "$cfg" --no-out-link 2>/var/log/breadstick-engine-proot.log) || {
  rm -f "$cfg"; echo "the proot generation did not build:"; tail -n 5 /var/log/breadstick-engine-proot.log; exit 4; }
rm -f "$cfg"
[ -e "$sys/activate" ] && [ ! -e "$sys/kernel" ] || { echo "not a proot generation: $sys"; exit 4; }
ln -sfn "$sys" /nix/var/nix/gcroots/breadstick-engine-proot
sync
echo "BSL_ENGINE_READY $sys"
