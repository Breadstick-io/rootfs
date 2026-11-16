set -e
s=/var/lib/breadstick-vm/restore
w=/var/lib/breadstick-vm/restore.work
[ -d "$s/usr" ] && [ -d "$s/etc" ] || { echo "no system in $s"; exit 3; }
LC_ALL=C
export LC_ALL
nl='
'
rm -rf "$w"
mkdir -p "$w"
chmod 0700 "$w"
find / -xdev -name "*$nl*" -prune -o \( -path /var/lib/breadstick-vm -o -path /home -o -path /tmp -o -path /var/tmp \) -prune -o ! -type d \( ! -uid 0 -o ! -gid 0 \) -printf '%u:%g\t%p\n' > "$w/owners"
if [ -f /var/lib/dpkg/status ]; then cp -p /var/lib/dpkg/status "$w/dpkg-status"; fi
if command -v rpm >/dev/null 2>&1; then
  d=$(rpm -E %_dbpath 2>/dev/null) || d=
  if [ "${d#/}" != "$d" ] && [ -d "$d" ]; then cp -a "$d" "$w/rpmdb"; fi
fi
awk '$5 != "/" { print "." $5 }' /proc/self/mountinfo | sort -u > "$w/mounts"
cd "$s"
tar --create --file=- --format=posix --numeric-owner --xattrs --xattrs-include='*' --exclude-from="$w/mounts" --exclude='./usr/lib/breadstick-vm' --exclude='./etc/systemd/system/bsl-*' --exclude='./etc/systemd/system/*.wants/bsl-*' --exclude='./etc/fstab' --exclude='./etc/modules-load.d/breadstick-vm.conf' --exclude='./etc/systemd/journald.conf.d/breadstick-vm.conf' --exclude='./etc/systemd/zram-generator.conf' --exclude='./etc/profile.d/breadstick-vm.sh' --exclude='./etc/sudoers.d/breadstick-vm' --exclude='./etc/hostname' --exclude='./etc/hosts' --exclude='./etc/resolv.conf' --exclude='./etc/machine-id' . \
  | tar --extract --file=- --directory=/ --numeric-owner --same-permissions --xattrs --xattrs-include='*' --keep-directory-symlink --no-overwrite-dir
cd /
if [ -x /usr/bin/systemd-sysusers ] && [ "$(head -c 4 /usr/bin/systemd-sysusers)" = "$(printf '\177ELF')" ]; then
  /usr/bin/systemd-sysusers >>/var/log/breadstick-vm-restore.log 2>&1 || echo "systemd-sysusers: exit $?"
fi
t=$(printf '\t')
while IFS="$t" read -r o p; do
  [ -e "$s$p" ] || [ -L "$s$p" ] || continue
  if [ -L "$p" ]; then chown -h "$o" "$p" 2>/dev/null || true
  elif [ -e "$p" ]; then m=$(stat -c %a "$p") && chown "$o" "$p" 2>/dev/null && chmod "$m" "$p" || true
  fi
done < "$w/owners"
find / -xdev -name "*$nl*" -prune -o \( -path /usr/lib/breadstick-vm -o -path /var/lib/breadstick-vm -o -path /boot -o -path /usr/lib/modules -o -path /lib/modules -o -path /tmp -o -path /var/tmp -o -path /lost+found -o -path /var/cache/apt/archives -o -path /var/cache/pacman/pkg -o -path /var/cache/libdnf5 -o -path /var/cache/dnf \) -prune -o -print > "$w/all"
while IFS= read -r p; do
  if [ -e "$s$p" ] || [ -L "$s$p" ]; then continue; fi
  case "$p" in /|/usr/lib/breadstick-vm|/etc/systemd/system/bsl-*|/etc/systemd/system/*.wants/bsl-*|/etc/fstab|/etc/modules-load.d/breadstick-vm.conf|/etc/systemd/journald.conf.d/breadstick-vm.conf|/etc/systemd/zram-generator.conf|/etc/profile.d/breadstick-vm.sh|/etc/sudoers.d/breadstick-vm|/etc/hostname|/etc/hosts|/etc/resolv.conf|/etc/machine-id|/var/log/breadstick-vm-*) continue ;; esac
  printf '%s\n' "$p"
done < "$w/all" > "$w/gone"
l=/var/lib/breadstick-vm/image-files.gz
if [ -s "$l" ] && gzip -dc "$l" > "$w/image"; then
  grep -vxF -f "$w/image" "$w/gone" > "$w/gone.1" || true
  mv -f "$w/gone.1" "$w/gone"
else
  : > "$w/gone"
fi
sort -r "$w/gone" | while IFS= read -r p; do
  if [ -d "$p" ] && [ ! -L "$p" ]; then rmdir "$p" 2>/dev/null || true; else rm -f "$p" || true; fi
done
echo "taken away: $(wc -l < "$w/gone")"
if [ -s "$w/dpkg-status" ] && [ -f /var/lib/dpkg/status ]; then
  set +e
  ( set -e
    : > "$w/dpkg-add"
    awk -v info=/var/lib/dpkg/info -v out="$w/dpkg-add" '
      function flush() {
        if (f == 1 && n != "") have[n ":" a] = 1
        if (f == 2 && n != "" && st == "install ok installed" && !((n ":" a) in have) && !((n ":all") in have)) {
          l1 = info "/" n ".list"; l2 = info "/" n ":" a ".list"
          if ((getline x < l1) > 0 || (getline x < l2) > 0) { printf "%s\n", buf > out; k++ }
          close(l1); close(l2)
        }
        n = ""; a = ""; st = ""; buf = ""
      }
      FNR == 1 { flush(); f++ }
      /^$/ { flush(); next }
      { buf = buf $0 "\n" }
      /^Package: / { n = $2 }
      /^Architecture: / { a = $2 }
      /^Status: / { st = substr($0, 9) }
      END { flush(); print k + 0 }' /var/lib/dpkg/status "$w/dpkg-status" > "$w/dpkg-n"
    bsl_count() { awk '/^Package: / { k++ } END { print k + 0 }' "$1"; }
    bsl_check() {
      apt-get check -q -o Dir::State::status="$1" -o Dir::State::lists="$w/apt-lists" -o Dir::Cache::pkgcache= \
        -o Dir::Cache::srcpkgcache= -o Debug::NoLocking=1 > "$2" 2>&1
    }
    o=0
    bsl_out() { awk '/^Package: / { print "left out (dpkg): " $2 }' "$1" >>/var/log/breadstick-vm-restore.log; }
    if [ -s "$w/dpkg-add" ] && ! command -v apt-get >/dev/null 2>&1; then
      o=$(bsl_count "$w/dpkg-add")
      bsl_out "$w/dpkg-add"
      : > "$w/dpkg-add"
    fi
    mkdir -p "$w/apt-lists/partial"
    i=0
    while [ -s "$w/dpkg-add" ]; do
      { cat /var/lib/dpkg/status; [ -z "$(tail -c 1 /var/lib/dpkg/status)" ] || echo; echo; cat "$w/dpkg-add"; } > "$w/dpkg-try"
      if bsl_check "$w/dpkg-try" "$w/dpkg-check"; then break; fi
      : > "$w/dpkg-bad"
      awk -v out="$w/dpkg-bad" '
        FNR == 1 { f++ }
        f == 1 { if ($0 ~ /^Package: /) add[$2] = 1; next }
        {
          l = $0
          if (l ~ /^ [^ ]+ : /) { p = substr(l, 2, index(l, " : ") - 2); sub(/:.*/, "", p); l = substr(l, index(l, " : ") + 3) }
          else if (l ~ /^  /) sub(/^ +/, "", l)
          else { p = ""; next }
          if (p == "") next
          t = ""
          if (l ~ /^(Pre-Depends|Depends|Breaks|Conflicts): /) { t = l; sub(/^[^ ]+ /, "", t); sub(/[ (].*/, "", t); sub(/:.*/, "", t) }
          if (p in add) bad[p] = 1
          else if (t in add) bad[t] = 1
        }
        END { for (b in bad) print b > out }' "$w/dpkg-add" "$w/dpkg-check"
      if [ ! -s "$w/dpkg-bad" ]; then
        bsl_check /var/lib/dpkg/status "$w/dpkg-check0" || true
        grep '^ ' "$w/dpkg-check0" > "$w/dpkg-c0" || true
        grep '^ ' "$w/dpkg-check" > "$w/dpkg-c1" || true
        grep -vxF -f "$w/dpkg-c0" "$w/dpkg-c1" > "$w/dpkg-c2" || true
        if [ -s "$w/dpkg-c1" ] && [ ! -s "$w/dpkg-c2" ]; then break; fi
        i=50
      fi
      i=$((i + 1))
      if [ "$i" -gt 50 ]; then
        o=$((o + $(bsl_count "$w/dpkg-add")))
        bsl_out "$w/dpkg-add"
        : > "$w/dpkg-add"
        break
      fi
      awk -v bad="$w/dpkg-bad" '
        BEGIN { while ((getline x < bad) > 0) b[x] = 1; RS = ""; ORS = "\n\n" }
        { n = ""; c = split($0, L, "\n"); for (j = 1; j <= c; j++) if (L[j] ~ /^Package: /) n = substr(L[j], 10); if (!(n in b)) print }' \
        "$w/dpkg-add" > "$w/dpkg-add.1"
      o=$((o + $(bsl_count "$w/dpkg-add") - $(bsl_count "$w/dpkg-add.1")))
      sed 's/^/left out (dpkg): /' "$w/dpkg-bad" >>/var/log/breadstick-vm-restore.log
      mv -f "$w/dpkg-add.1" "$w/dpkg-add"
    done
    if [ -s "$w/dpkg-add" ]; then
      { cat /var/lib/dpkg/status; [ -z "$(tail -c 1 /var/lib/dpkg/status)" ] || echo; echo; cat "$w/dpkg-add"; } > /var/lib/dpkg/status.bsl-new
      chmod 0644 /var/lib/dpkg/status.bsl-new
      mv -f /var/lib/dpkg/status.bsl-new /var/lib/dpkg/status
    fi
    echo "package database (dpkg): the VM's own packages put back: $(bsl_count "$w/dpkg-add"), left out: $o"
  )
  r=$?
  set -e
  [ "$r" = 0 ] || echo "package database (dpkg): not put back (exit $r)"
fi
if [ -d "$w/rpmdb" ] && command -v rpm >/dev/null 2>&1; then
  set +e
  ( set -e
    rpm -qa --qf '%{NAME}.%{ARCH}\n' 2>/dev/null | sort -u > "$w/rpm-have"
    rpm --dbpath "$w/rpmdb" -qa --qf '%{NAME}.%{ARCH}\t%{NAME}-%{VERSION}-%{RELEASE}%|ARCH?{.%{ARCH}}:{}|\n' 2>/dev/null | sort -u > "$w/rpm-vm"
    : > "$w/rpm-add"
    cut -f 1 "$w/rpm-vm" | grep -v '^gpg-pubkey[.]' | sort -u | comm -13 "$w/rpm-have" - | while IFS= read -r pk; do
      rpm --dbpath "$w/rpmdb" -q --qf '[%{FILESTATES:fstate} f%{FILEFLAGS:fflags} %{FILENAMES}\n]' "$pk" > "$w/rpm-files" 2>/dev/null || continue
      fs=
      while read -r fs ff fp; do
        [ "$fs" = normal ] || continue
        case "$ff" in *g*|*m*) continue ;; esac
        [ -e "$fp" ] || [ -L "$fp" ] || { fs=missing; break; }
      done < "$w/rpm-files"
      [ "$fs" = missing ] || printf '%s\n' "$pk" >> "$w/rpm-add"
    done
    o=0
    if [ -s "$w/rpm-add" ]; then
      rpm -Va --nofiles --nodigest --nosignature --noscripts > "$w/rpm-v0" 2>&1 || true
      awk -F '\t' 'FILENAME == ARGV[1] { add[$0] = 1; next } !($1 in add) { print $2 }' "$w/rpm-add" "$w/rpm-vm" > "$w/rpm-drop"
      [ ! -s "$w/rpm-drop" ] || xargs rpm --dbpath "$w/rpmdb" -e --justdb --nodeps --noscripts --notriggers --allmatches < "$w/rpm-drop" 2>>/var/log/breadstick-vm-restore.log
      rpmdb --dbpath "$w/rpmdb" --exportdb | rpmdb --importdb
      i=0
      while [ -s "$w/rpm-add" ]; do
        if rpm -Va --nofiles --nodigest --nosignature --noscripts > "$w/rpm-v" 2>&1; then break; fi
        grep -vxF -f "$w/rpm-v0" "$w/rpm-v" > "$w/rpm-v1" || true
        [ -s "$w/rpm-v1" ] || break
        awk -F '\t' 'FILENAME == ARGV[1] { add[$0] = 1; next }
          FILENAME == ARGV[2] { if ($1 in add) key[$2] = $1; next }
          /^Unsatisfied dependencies for .*:$/ { x = substr($0, 30, length($0) - 30); sub(/-[0-9]+:/, "-", x); if (x in key) print key[x] }' \
          "$w/rpm-add" "$w/rpm-vm" "$w/rpm-v1" | sort -u > "$w/rpm-bad"
        i=$((i + 1))
        if [ ! -s "$w/rpm-bad" ] || [ "$i" -gt 50 ]; then cp "$w/rpm-add" "$w/rpm-bad"; fi
        awk -F '\t' 'FILENAME == ARGV[1] { b[$0] = 1; next } ($1 in b) { print $2 }' "$w/rpm-bad" "$w/rpm-vm" \
          | xargs rpm -e --justdb --nodeps --noscripts --notriggers --allmatches 2>>/var/log/breadstick-vm-restore.log
        grep -vxF -f "$w/rpm-bad" "$w/rpm-add" > "$w/rpm-add.1" || true
        sed 's/^/left out (rpm): /' "$w/rpm-bad" >>/var/log/breadstick-vm-restore.log
        o=$((o + $(wc -l < "$w/rpm-bad")))
        mv -f "$w/rpm-add.1" "$w/rpm-add"
      done
    fi
    echo "package database (rpm): the VM's own packages put back: $(wc -l < "$w/rpm-add"), left out: $o"
  )
  r=$?
  set -e
  [ "$r" = 0 ] || echo "package database (rpm): not put back (exit $r)"
fi
if [ -d /var/lib/pacman/local ] && [ -d "$s/var/lib/pacman/local" ]; then
  set +e
  ( set -e
    for e in "$s"/var/lib/pacman/local/*/desc; do
      [ ! -f "$e" ] || awk '/^%NAME%$/ { getline; print; exit }' "$e"
    done | sort -u > "$w/pac-have"
    : > "$w/pac-kept"
    for d in /var/lib/pacman/local/*/; do
      d=${d%/}
      [ -f "$d/desc" ] && [ ! -e "$s$d" ] || continue
      pn=$(awk '/^%NAME%$/ { getline; print; exit }' "$d/desc")
      if [ -n "$pn" ] && grep -qxF -e "$pn" "$w/pac-have"; then rm -rf "$d"; else printf '%s\t%s\n' "$pn" "$d" >> "$w/pac-kept"; fi
    done
    o=0
    if [ -s "$w/pac-kept" ]; then
      mkdir -p "$w/pacdb0" "$w/pac-out"
      cp -a /var/lib/pacman/local "$w/pacdb0/local"
      cut -f 2 "$w/pac-kept" | while IFS= read -r d; do rm -rf "$w/pacdb0/local/${d##*/}"; done
      pacman -Dk --dbpath "$w/pacdb0" > "$w/pac-c0" 2>&1 || true
      i=0
      while [ -s "$w/pac-kept" ]; do
        if pacman -Dk > "$w/pac-c" 2>&1; then break; fi
        grep -vxF -f "$w/pac-c0" "$w/pac-c" > "$w/pac-c1" || true
        [ -s "$w/pac-c1" ] || break
        awk -F '\t' 'FILENAME == ARGV[1] { kept[$1] = $0; next }
          { split($0, q, "\047") }
          / dependency for \047/ { if (q[4] in kept) bad[q[4]] = 1 }
          / conflicts with \047/ { if (q[2] in kept) bad[q[2]] = 1; if (q[4] in kept) bad[q[4]] = 1 }
          END { for (b in bad) print kept[b] }' "$w/pac-kept" "$w/pac-c1" > "$w/pac-bad"
        i=$((i + 1))
        if [ ! -s "$w/pac-bad" ] || [ "$i" -gt 50 ]; then cp "$w/pac-kept" "$w/pac-bad"; fi
        cut -f 2 "$w/pac-bad" | while IFS= read -r d; do mv "$d" "$w/pac-out/"; done
        cut -f 1 "$w/pac-bad" | sed 's/^/left out (pacman): /' >>/var/log/breadstick-vm-restore.log
        awk -F '\t' 'FILENAME == ARGV[1] { b[$1] = 1; next } !($1 in b)' "$w/pac-bad" "$w/pac-kept" > "$w/pac-kept.1"
        o=$((o + $(wc -l < "$w/pac-bad")))
        mv -f "$w/pac-kept.1" "$w/pac-kept"
      done
    fi
    echo "package database (pacman): the VM's own packages kept: $(wc -l < "$w/pac-kept"), left out: $o"
  )
  r=$?
  set -e
  [ "$r" = 0 ] || echo "package database (pacman): not checked (exit $r)"
fi
rm -rf "$s" "$w"
sync
echo restored
