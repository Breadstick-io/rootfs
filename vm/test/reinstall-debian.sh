f=/var/lib/breadstick-vm/restore-left-out
[ -s "$f" ] || exit 0
export DEBIAN_FRONTEND=noninteractive
n=$(awk '$1 == "dpkg" { printf "%s ", $2 }' "$f")
[ -n "$n" ] || { rm -f "$f"; exit 0; }
# Without package lists every name would look gone (a restored backup's lists are its own, often none).
if ! ls "/var/lib/apt/lists" 2>/dev/null | grep -q '_Packages'; then
  echo "the VM's own packages the restore left out, not installed yet (no package lists):$n"
  exit 75
fi
p=$(LC_ALL=C apt-cache policy $n 2>/dev/null | awk -v want="$n" '
  BEGIN { c = split(want, W, " "); for (j = 1; j <= c; j++) if (W[j] != "") w[W[j]] = 1 }
  /^[^ ].*:$/ { k = substr($0, 1, length($0) - 1); next }
  /^  Installed: / { inst[k] = ($2 != "(none)") }
  /^  Candidate: / { cand[k] = ($2 != "(none)") }
  END { for (x in w) if (!inst[x]) print (cand[x] ? "add " : "gone ") x }') || exit 1
gone=$(printf '%s\n' "$p" | awk '$1 == "gone" { printf " %s", $2 }')
add=$(printf '%s\n' "$p" | awk '$1 == "add" { printf " %s", $2 }')
[ -z "$gone" ] || echo "the VM's own packages the restore left out, no longer in the package lists:$gone"
if [ -n "$add" ]; then
  echo "the VM's own packages the restore left out, installed again:$add"
  apt-get install -y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $add || exit $?
fi
rm -f "$f"
