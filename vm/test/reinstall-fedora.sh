f=/var/lib/breadstick-vm/restore-left-out
[ -s "$f" ] || exit 0
n=
for p in $(awk '$1 == "rpm" { print $2 }' "$f"); do rpm -q "$p" >/dev/null 2>&1 || n="$n $p"; done
if [ -n "$n" ]; then
  echo "the VM's own packages the restore left out, installed again:$n"
  dnf -y install --setopt=install_weak_deps=False --skip-unavailable $n || exit $?
  m=
  for p in $n; do rpm -q "$p" >/dev/null 2>&1 || m="$m $p"; done
  if [ -n "$m" ]; then
    if dnf -q repoquery --available --qf '%{name}\n' bash 2>/dev/null | grep -qx bash; then
      echo "the VM's own packages the restore left out, in no repository:$m"
    else
      printf 'rpm %s\n' $m > "$f"
      echo "the VM's own packages the restore left out, not installed yet (the repositories did not answer):$m"
      exit 75
    fi
  fi
fi
rm -f "$f"
