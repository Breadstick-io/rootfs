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
    # keeps only the newest build, so the newest build of its name in the repositories goes in beside the
    # others, by its own NVRA (dnf5 does nothing for `install <name>` while any of that name is installed, and
    # installs an install-only package next to them). Only when the repositories have nothing newer than the
    # newest installed does the kernel of that version leave /boot, when no package owns it, so the VM boots
    # one a package owns from its next start (round 11 review; the second review: by its NVRA).
    g=
    for p in $m; do
      a=${p##*.}; r=${p%.*}; v=${r%-*}; nm=${v%-*}
      case ${r#"$nm"-} in [0-9]*-*) ;; *) g="$g $p"; continue ;; esac
      if [ "$nm" = "$r" ] || ! awk -v p="$p" '$1 == "rpm" && $2 == p && $3 == "" { y = 1 } END { exit !y }' "$f"; then g="$g $p"; continue; fi
      k=${r#"$nm"-}.$a; q=$nm.$a
      t=
      if rpm -q "$q" >/dev/null 2>&1; then
        for e in $(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$q" 2>/dev/null); do
          if [ -z "$t" ] || [ "$(rpm --eval "%{lua:print(rpm.vercmp('$e','$t'))}")" = 1 ]; then t=$e; fi
        done
      fi
      o=$(dnf -q repoquery --available --latest-limit 1 --qf '%{version}-%{release}\n' "$q" 2>/dev/null) || { g="$g $p"; continue; }
      l=$(printf '%s\n' "$o" | grep . | tail -n 1)
      if [ -n "$l" ] && { [ -z "$t" ] || [ "$(rpm --eval "%{lua:print(rpm.vercmp('$l','$t'))}")" = 1 ]; }; then
        dnf -y install --setopt=install_weak_deps=False "$nm-$l.$a" || exit $?
        if rpm -q "$nm-$l.$a" >/dev/null 2>&1; then
          echo "the VM's own $p is in no repository; installed beside it: $nm-$l.$a"
        else
          g="$g $p"
        fi
      elif [ -f "/boot/vmlinuz-$k" ] && ! rpm -qf "/boot/vmlinuz-$k" >/dev/null 2>&1 && ! rpm -qf "/usr/lib/modules/$k/vmlinuz" >/dev/null 2>&1; then
        rm -f "/boot/vmlinuz-$k" "/boot/initramfs-$k.img"
        echo "the VM's own $p is in no repository, nor anything newer: its kernel left /boot, the next start boots one a package owns"
      else
        g="$g $p"
      fi
    done
    y=
    for p in $m; do case " $g " in *" $p "*) y="$y $p" ;; esac; done
    [ -z "$y" ] || echo "the VM's own packages the restore left out, in no repository:$y"
  fi
fi
rm -f "$f"
