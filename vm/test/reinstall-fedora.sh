f=/var/lib/breadstick-vm/restore-left-out
[ -s "$f" ] || exit 0
n=
for p in $(awk '$1 == "rpm" { print ($3 != "" ? $3 : $2) }' "$f" | sort -u); do rpm -q "$p" >/dev/null 2>&1 || n="$n $p"; done
if [ -n "$n" ]; then
  echo "the VM's own packages the restore left out, installed again:$n"
  dnf -y install --setopt=install_weak_deps=False --skip-unavailable $n || exit $?
  m=
  for p in $n; do rpm -q "$p" >/dev/null 2>&1 || m="$m $p"; done
  if [ -n "$m" ]; then
    if ! dnf -q repoquery --available --qf '%{name}\n' bash 2>/dev/null | grep -qx bash; then
      awk -v m=" $m " '$1 == "rpm" { t = ($3 != "" ? $3 : $2); if (index(m, " " t " ") && !(t in s)) { s[t] = 1; print } }' "$f" > "$f.new"
      mv -f "$f.new" "$f"
      echo "the VM's own packages the restore left out, not installed yet (the repositories did not answer):$m"
      exit 75
    fi
    # An exact version (`rpm <NVRA>`: a second kernel beside the one the restore kept) in no repository: Fedora
    # keeps only the newest build, so the newest of its name goes in beside the others (dnf installs an
    # install-only package next to them). With nothing newer there either, the kernel of that version leaves
    # /boot when no package owns it, so the VM boots one a package owns from its next start (round 11 review).
    g=
    x=
    for p in $m; do
      a=${p##*.}; r=${p%.*}; v=${r%-*}; nm=${v%-*}
      case ${r#"$nm"-} in [0-9]*-*) ;; *) g="$g $p"; continue ;; esac
      if [ "$nm" = "$r" ] || ! awk -v p="$p" '$1 == "rpm" && $2 == p && $3 == "" { y = 1 } END { exit !y }' "$f"; then g="$g $p"; continue; fi
      x="$x $p"
    done
    if [ -n "$x" ]; then
      b=
      for p in $x; do r=${p%.*}; v=${r%-*}; b="$b ${v%-*}.${p##*.}"; done
      for q in $b; do printf '%s %s\n' "$q" "$(rpm -q "$q" 2>/dev/null | grep -c -v ' is not installed')"; done > "$f.was"
      dnf -y install --setopt=install_weak_deps=False $b || { r=$?; rm -f "$f.was"; exit "$r"; }
      for p in $x; do
        a=${p##*.}; r=${p%.*}; v=${r%-*}; nm=${v%-*}; k=${r#"$nm"-}.$a
        w=$(awk -v q="$nm.$a" '$1 == q { print $2; exit }' "$f.was")
        h=$(rpm -q "$nm.$a" 2>/dev/null | grep -v ' is not installed' | sort -V)
        if [ "$(printf '%s\n' "$h" | grep -c .)" -gt "${w:-0}" ]; then
          echo "the VM's own $p is in no repository; installed beside it: $(printf '%s\n' "$h" | tail -n 1)"
        elif [ -f "/boot/vmlinuz-$k" ] && ! rpm -qf "/boot/vmlinuz-$k" >/dev/null 2>&1 && ! rpm -qf "/usr/lib/modules/$k/vmlinuz" >/dev/null 2>&1; then
          rm -f "/boot/vmlinuz-$k" "/boot/initramfs-$k.img"
          echo "the VM's own $p is in no repository, nor anything newer: its kernel left /boot, the next start boots one a package owns"
        else
          g="$g $p"
        fi
      done
      rm -f "$f.was"
    fi
    y=
    for p in $m; do case " $g " in *" $p "*) y="$y $p" ;; esac; done
    [ -z "$y" ] || echo "the VM's own packages the restore left out, in no repository:$y"
  fi
fi
rm -f "$f"
