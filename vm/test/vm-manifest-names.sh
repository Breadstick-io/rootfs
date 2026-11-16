#!/bin/bash
# The VM bakes write their local manifests under the names the 4.0 app reads (4.0 round 10, critic M4): one name per
# distribution, <distro>/manifest-vm-<arch>.json (Android VmManifest.manifestName; AutoBuild deploy/vm-image.sh
# publishes it, tools/serve-test-images.sh serves it). Debian's bake-vm.sh keeps manifest-vm-<arch>.json, the name every
# released app reads. No Docker, no network, about a second.
#
#   vm/test/vm-manifest-names.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
pass=0 fail=0
ok()  { echo "  ok    $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $*"; fail=$((fail + 1)); }
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT

# 1. Where each bake writes its manifest (the line that writes it, read from the script).
nix_line=$(grep -n '> "\$MANIFEST_DIR/' "$HERE/bootstrap/bootstrap-nix.sh" | grep 'manifest-vm' || true)
case "$nix_line" in *'"$MANIFEST_DIR/nix/manifest-vm-$ARCH.json"'*) ok "bootstrap-nix.sh vm writes nix/manifest-vm-<arch>.json" ;; *) bad "bootstrap-nix.sh: $nix_line" ;; esac
[ -z "$(grep -n 'manifest-vm-nix-' "$HERE/bootstrap/bootstrap-nix.sh" | grep -v '^[0-9]*:#')" ] && ok "bootstrap-nix.sh writes no manifest-vm-nix-<arch>.json" || bad "bootstrap-nix.sh still writes manifest-vm-nix-"
distro_line=$(grep -n '> "\$OUT_DIR/\$DISTRO/manifest-vm-\$ARCH.json"' "$HERE/vm/bake-vm-distro.sh" || true)
[ -n "$distro_line" ] && ok "bake-vm-distro.sh writes <distro>/manifest-vm-<arch>.json" || bad "bake-vm-distro.sh's manifest name changed"
grep -q '> "\$OUT_DIR/manifest-vm-\$ARCH.json"' "$HERE/vm/bake-vm.sh" && ok "bake-vm.sh (Debian) keeps manifest-vm-<arch>.json" || bad "bake-vm.sh's Debian name changed"

# 2. The Nix bake's sed on an image.json shaped as it writes it: valid JSON, base vm/<name>/ right after the name.
NAME=nixos-26.05-arm64-vm-202611151240
cat > "$T/image.json" <<BSL_VMNAMES_JSON_4d2
{
  "format": 1,
  "name": "$NAME",
  "arch": "arm64",
  "distro": "nix",
  "files": {
    "kernel": { "name": "vmlinuz", "sha256": "$(printf '%064d' 0)", "size": 1 }
  }
}
BSL_VMNAMES_JSON_4d2
expr=$(sed -n 's/^ *sed "\(s|.*|\)" "\$VOUT\/image.json" > "\$MANIFEST_DIR\/nix\/manifest-vm-\$ARCH.json"$/\1/p' "$HERE/bootstrap/bootstrap-nix.sh")
[ -n "$expr" ] || bad "the sed expression was not found in bootstrap-nix.sh"
eval "sed \"$expr\"" < "$T/image.json" > "$T/manifest.json" 2>/dev/null
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
assert d["base"] == "vm/%s/" % sys.argv[2] and d["distro"] == "nix" and list(d)[:3] == ["format", "name", "base"], d' "$T/manifest.json" "$NAME" \
    && ok "the Nix VM manifest reads as JSON with base vm/<name>/ after the name" || bad "the Nix VM manifest: $(cat "$T/manifest.json")"
echo "vm-manifest-names: $pass passed, $fail failed"
[ $fail = 0 ]
