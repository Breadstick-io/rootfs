set -e
s=/var/lib/breadstick-vm/restore
w=/var/lib/breadstick-vm/restore.work
[ -d "$s/usr" ] && [ -d "$s/etc" ] || { echo "no system in $s"; exit 3; }
LC_ALL=C
export LC_ALL
nl='
'
rm -rf "$w"
rm -f /var/lib/breadstick-vm/restore-left-out
mkdir -p "$w"
chmod 0700 "$w"
find / -xdev -name "*$nl*" -prune -o \( -path /var/lib/breadstick-vm -o -path /home -o -path /tmp -o -path /var/tmp \) -prune -o ! -type d \( ! -uid 0 -o ! -gid 0 \) -printf '%u:%g\t%p\n' > "$w/owners"
if [ -f /var/lib/dpkg/status ]; then cp -p /var/lib/dpkg/status "$w/dpkg-status"; fi
if [ -d /var/lib/dpkg/info ]; then cp -a /var/lib/dpkg/info "$w/dpkg-info"; fi
if command -v rpm >/dev/null 2>&1; then
  d=$(rpm -E %_dbpath 2>/dev/null) || d=
  if [ "${d#/}" != "$d" ] && [ -d "$d" ]; then cp -a "$d" "$w/rpmdb"; fi
fi
if [ -d /var/lib/pacman/local ]; then mkdir -p "$w/pacdb" && cp -a /var/lib/pacman/local "$w/pacdb/local"; fi
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
    : > "$w/dpkg-cand"
    : > "$w/dpkg-nolist"
    na=$(dpkg --print-architecture 2>/dev/null) || na=
    awk -v info=/var/lib/dpkg/info -v saved="$w/dpkg-info" -v out="$w/dpkg-add" -v cand="$w/dpkg-cand" -v nolist="$w/dpkg-nolist" -v na="$na" '
      function try(d, b, s) {
        l = d "/" b ".list"
        if ((getline x < l) > 0) { close(l); printf "%s\n", buf > out; printf "%s:%s\t%s\t%s\t%s\t%s\n", n, a, l, id, b, s > cand; k++; return 1 }
        close(l); return 0
      }
      function flush() {
        if (f == 1 && n != "") have[n ":" a] = 1
        if (f == 2 && n != "" && st == "install ok installed" && !((n ":" a) in have) && !((n ":all") in have)) {
          id = n; if (a != na && a != "all" && a != "") id = n ":" a
          if (!try(info, n, 0) && !try(info, n ":" a, 0) && !try(saved, n, 1) && !try(saved, n ":" a, 1)) printf "%s\n", id > nolist
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
    bsl_out() {
      awk -v na="$na" 'function p() { if (n != "") { if (a != na && a != "all" && a != "") n = n ":" a; print n } n = ""; a = "" }
        /^Package: / { p(); n = $2 } /^Architecture: / { a = $2 } END { p() }' "$1" | bsl_left
    }
    bsl_left() { tee -a "$w/left-dpkg" | sed 's/^/left out (dpkg): /' >>/var/log/breadstick-vm-restore.log; }
    # Each one judged by its own file list (round 11, H3), the one the restore took away from the copy kept before it:
    # all its paths there, put back; none of its files kept, taken away with the rest that came after the image (a
    # restore replaces the system); some kept and some gone (the kernel the VM updated to), left out and named.
    t=$(printf '\t')
    : > "$w/dpkg-miss"
    : > "$w/dpkg-gone"
    while IFS="$t" read -r pa lp id b sv; do
      m=0
      h=0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        if [ -e "$p" ] || [ -L "$p" ]; then { [ -d "$p" ] && [ ! -L "$p" ]; } || h=$((h + 1)); else m=$((m + 1)); fi
      done < "$lp"
      if [ "$m" = 0 ]; then continue; fi
      if [ "$h" = 0 ]; then printf '%s\t%s\n' "$pa" "$id" >> "$w/dpkg-gone"; else printf '%s\t%s\n' "$pa" "$id" >> "$w/dpkg-miss"; fi
    done < "$w/dpkg-cand"
    if [ -s "$w/dpkg-miss" ] || [ -s "$w/dpkg-gone" ]; then
      cat "$w/dpkg-miss" "$w/dpkg-gone" > "$w/dpkg-out"
      awk -v miss="$w/dpkg-out" '
        BEGIN { while ((getline x < miss) > 0) { sub(/\t.*/, "", x); b[x] = 1 } RS = ""; ORS = "\n\n" }
        { n = ""; a = ""; c = split($0, L, "\n")
          for (j = 1; j <= c; j++) { if (L[j] ~ /^Package: /) n = substr(L[j], 10); if (L[j] ~ /^Architecture: /) a = substr(L[j], 15) }
          if (!((n ":" a) in b)) print }' "$w/dpkg-add" > "$w/dpkg-add.1"
      mv -f "$w/dpkg-add.1" "$w/dpkg-add"
      cut -f 2 "$w/dpkg-miss" | bsl_left
      o=$((o + $(wc -l < "$w/dpkg-miss")))
      cut -f 2 "$w/dpkg-gone" | sed 's/^/taken away (dpkg): /' >>/var/log/breadstick-vm-restore.log
    fi
    if [ -s "$w/dpkg-nolist" ]; then
      bsl_left < "$w/dpkg-nolist"
      o=$((o + $(wc -l < "$w/dpkg-nolist")))
    fi
    if [ -s "$w/dpkg-add" ] && ! command -v apt-get >/dev/null 2>&1; then
      o=$((o + $(bsl_count "$w/dpkg-add")))
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
          if (l ~ /^(PreDepends|Pre-Depends|Depends|Breaks|Conflicts): /) { t = l; sub(/^[^ ]+ /, "", t); sub(/[ (].*/, "", t); sub(/:.*/, "", t) }
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
      bsl_left < "$w/dpkg-bad"
      mv -f "$w/dpkg-add.1" "$w/dpkg-add"
    done
    if [ -s "$w/dpkg-add" ]; then
      # A package put back from the copy gets its info files back (its list, sums, scripts), only its own.
      awk '/^Package: / { n = $2 } /^Architecture: / { print n ":" $2 }' "$w/dpkg-add" > "$w/dpkg-final"
      while IFS="$t" read -r pa lp id b sv; do
        [ "$sv" = 1 ] && grep -qxF -e "$pa" "$w/dpkg-final" || continue
        for e in list md5sums conffiles preinst postinst prerm postrm config templates triggers shlibs symbols; do
          [ ! -f "$w/dpkg-info/$b.$e" ] || cp -p "$w/dpkg-info/$b.$e" "/var/lib/dpkg/info/$b.$e"
        done
      done < "$w/dpkg-cand"
      { cat /var/lib/dpkg/status; [ -z "$(tail -c 1 /var/lib/dpkg/status)" ] || echo; echo; cat "$w/dpkg-add"; } > /var/lib/dpkg/status.bsl-new
      chmod 0644 /var/lib/dpkg/status.bsl-new
      mv -f /var/lib/dpkg/status.bsl-new /var/lib/dpkg/status
    fi
    [ ! -s "$w/left-dpkg" ] || sort -u "$w/left-dpkg" | sed 's/^/dpkg /' >> /var/lib/breadstick-vm/restore-left-out
    echo "package database (dpkg): the VM's own packages put back: $(bsl_count "$w/dpkg-add"), left out: $o, taken away with the restore: $(wc -l < "$w/dpkg-gone")"
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
    : > "$w/rpm-miss"
    : > "$w/rpm-gone"
    : > "$w/rpm-nofile"
    # Each installed package of a name the restored database lacks, by its own NVRA (round 11, H3): a VM that updated
    # keeps two kernels (installonly_limit), and the one installed after the image lost files the restore took away;
    # the other is whole and stays. None of its files kept: taken away with the rest that came after the image.
    awk -F '\t' 'FILENAME == ARGV[1] { have[$0] = 1; next } !($1 in have) && $1 !~ /^gpg-pubkey[.]/ { print $2 }' "$w/rpm-have" "$w/rpm-vm" \
      | while IFS= read -r pv; do
      if ! rpm --dbpath "$w/rpmdb" -q --qf '[%{FILESTATES:fstate} f%{FILEFLAGS:fflags} %{FILEMODES:perms} %{FILENAMES}\n]' "$pv" > "$w/rpm-files" 2>/dev/null; then
        printf '%s\n' "$pv" >> "$w/rpm-miss"
        continue
      fi
      m=0
      h=0
      while read -r fs ff fm fp; do
        [ "$fs" = normal ] || continue
        case "$ff" in *g*|*m*) continue ;; esac
        if [ -e "$fp" ] || [ -L "$fp" ]; then case "$fm" in d*) ;; *) h=$((h + 1)) ;; esac; else m=$((m + 1)); fi
      done < "$w/rpm-files"
      if [ "$m" = 0 ] && [ "$h" = 0 ]; then printf '%s\n' "$pv" >> "$w/rpm-nofile"
      elif [ "$m" = 0 ]; then printf '%s\n' "$pv" >> "$w/rpm-add"
      elif [ "$h" = 0 ]; then printf '%s\n' "$pv" >> "$w/rpm-gone"
      else printf '%s\n' "$pv" >> "$w/rpm-miss"; fi
    done
    # A package with no file of its own (Fedora's kernel meta-package, a group's) is judged by what it needs (round
    # 11 review): one need met only by a package left out, left out with it (kernel-7.3.4 beside kernel-core-7.3.4,
    # whose kernel-core-uname-r the kept kernel-core provides at another version); one met only by packages taken
    # away, taken away; else put back. Again until a pass decides none (one such package needing another), three
    # times at most. A need nothing in the VM's database meets (rpmlib's, the system's own) says nothing.
    j=0
    while [ -s "$w/rpm-nofile" ] && [ "$j" -lt 3 ]; do
      j=$((j + 1))
      : > "$w/rpm-nofile.1"
      while IFS= read -r pv; do
        r=add
        { rpm --dbpath "$w/rpmdb" -q --requires "$pv" 2>/dev/null || true; } | grep -v '^rpmlib(' | sort -u > "$w/rpm-req" || true
        while IFS= read -r c; do
          # By the capability's name (rpm -q --whatprovides takes no version): every package that has it taken
          # away, taken away; one left out having it, left out, for a need without a version. A versioned one
          # (`kernel-core-uname-r = 7.3.4-300.fc45`) the check below judges, where such a package gets no
          # "version apart" either.
          cn=${c%% [<>=]*}
          rpm --dbpath "$w/rpmdb" -q --whatprovides "$cn" --qf '%{NAME}-%{VERSION}-%{RELEASE}%|ARCH?{.%{ARCH}}:{}|\n' > "$w/rpm-prov" 2>/dev/null || continue
          # The restored system having it itself: it says nothing either.
          ! rpm -q --whatprovides "$cn" >/dev/null 2>&1 || continue
          if [ "$cn" = "$c" ] && grep -qxF -f "$w/rpm-prov" "$w/rpm-miss"; then r=miss; break; fi
          grep -vxF -f "$w/rpm-gone" "$w/rpm-prov" | grep -q . || r=gone
        done < "$w/rpm-req"
        case $r in
          miss) printf '%s\n' "$pv" >> "$w/rpm-miss" ;;
          gone) printf '%s\n' "$pv" >> "$w/rpm-gone" ;;
          *) printf '%s\n' "$pv" >> "$w/rpm-nofile.1" ;;
        esac
      done < "$w/rpm-nofile"
      if [ "$(wc -l < "$w/rpm-nofile")" = "$(wc -l < "$w/rpm-nofile.1")" ]; then break; fi
      mv -f "$w/rpm-nofile.1" "$w/rpm-nofile"
    done
    cat "$w/rpm-nofile" >> "$w/rpm-add"
    mv -f "$w/rpm-nofile" "$w/rpm-bare"
    o=0
    if [ -s "$w/rpm-miss" ]; then
      tee -a "$w/left-rpm" < "$w/rpm-miss" | sed 's/^/left out (rpm): /' >>/var/log/breadstick-vm-restore.log
      o=$(wc -l < "$w/rpm-miss")
    fi
    sed 's/^/taken away (rpm): /' "$w/rpm-gone" >>/var/log/breadstick-vm-restore.log
    if [ -s "$w/rpm-add" ]; then
      rpm -Va --nofiles --nodigest --nosignature --noscripts > "$w/rpm-v0" 2>&1 || true
      awk -F '\t' 'FILENAME == ARGV[1] { add[$0] = 1; next } !($2 in add) { print $2 }' "$w/rpm-add" "$w/rpm-vm" > "$w/rpm-drop"
      [ ! -s "$w/rpm-drop" ] || xargs rpm --dbpath "$w/rpmdb" -e --justdb --nodeps --noscripts --notriggers --allmatches < "$w/rpm-drop" 2>>/var/log/breadstick-vm-restore.log
      rpmdb --dbpath "$w/rpmdb" --exportdb | rpmdb --importdb
      i=0
      : > "$w/rpm-apart"
      while [ -s "$w/rpm-add" ]; do
        if rpm -Va --nofiles --nodigest --nosignature --noscripts > "$w/rpm-v" 2>&1; then break; fi
        # A versioned need whose capability the system has (at another version) is a version apart, not a
        # missing package: the VM's systemd pins systemd-libs = its own version, the backup's is newer.
        awk '/^\t.* [<>=]+ [^ ]+ is needed by / { c = substr($0, 2); sub(/ [<>=]+ [^ ]+ is needed by .*$/, "", c); print c }' \
          "$w/rpm-v" | sort -u > "$w/rpm-vcaps"
        : > "$w/rpm-caps"
        while IFS= read -r c; do
          if rpm -q --whatprovides "$c" >/dev/null 2>&1; then printf '%s\n' "$c" >> "$w/rpm-caps"; fi
        done < "$w/rpm-vcaps"
        awk -F '\t' 'FILENAME == ARGV[1] { add[$0] = 1; next }
          FILENAME == ARGV[2] { if ($2 in add) key[$2] = $2; next }
          FILENAME == ARGV[3] { cap[$0] = 1; next }
          FILENAME == ARGV[4] { if ($0 ~ /^Unsatisfied dependencies for .*:$/) h = $0; else old[h "\n" $0] = 1; next }
          FILENAME == ARGV[5] { bare[$0] = 1; next }
          /^Unsatisfied dependencies for .*:$/ { h = $0; x = substr($0, 30, length($0) - 30); sub(/-[0-9]+:/, "-", x); k = (x in key) ? key[x] : ""; next }
          ((h "\n" $0) in old) { next }
          {
            c = substr($0, 2); v = c
            if (k != "" && !(k in bare) && sub(/ [<>=]+ [^ ]+ is needed by .*$/, "", c) && (c in cap)) { print "apart\t" k "\t" substr(v, 1, index(v, " is needed by ") - 1); next }
            print (k != "" ? "bad\t" k : "other")
          }' "$w/rpm-add" "$w/rpm-vm" "$w/rpm-caps" "$w/rpm-v0" "$w/rpm-bare" "$w/rpm-v" > "$w/rpm-why"
        awk -F '\t' '$1 == "bad" { print $2 }' "$w/rpm-why" | sort -u > "$w/rpm-bad"
        i=$((i + 1))
        if [ ! -s "$w/rpm-bad" ]; then
          if ! grep -q '^other' "$w/rpm-why"; then grep '^apart' "$w/rpm-why" | sort -u > "$w/rpm-apart" || true; break; fi
          cp "$w/rpm-add" "$w/rpm-bad"
        elif [ "$i" -gt 50 ]; then cp "$w/rpm-add" "$w/rpm-bad"; fi
        xargs rpm -e --justdb --nodeps --noscripts --notriggers --allmatches < "$w/rpm-bad" 2>>/var/log/breadstick-vm-restore.log
        grep -vxF -f "$w/rpm-bad" "$w/rpm-add" > "$w/rpm-add.1" || true
        tee -a "$w/left-rpm" < "$w/rpm-bad" | sed 's/^/left out (rpm): /' >>/var/log/breadstick-vm-restore.log
        o=$((o + $(wc -l < "$w/rpm-bad")))
        mv -f "$w/rpm-add.1" "$w/rpm-add"
      done
    fi
    # The record: `rpm <NVRA> <NAME.ARCH>`, installed again by name; only `rpm <NVRA>` when another version of that
    # name stays (a kernel's second version: that one again, never a downgrade of the kept one).
    if [ -s "$w/left-rpm" ]; then
      sort -u "$w/left-rpm" > "$w/left-rpm.1"
      awk -F '\t' 'FILENAME == ARGV[1] { na[$2] = $1; next } FILENAME == ARGV[2] { k[na[$0]] = 1; next }
        { if (($0 in na) && !(na[$0] in k)) print "rpm " $0 " " na[$0]; else print "rpm " $0 }' \
        "$w/rpm-vm" "$w/rpm-add" "$w/left-rpm.1" >> /var/lib/breadstick-vm/restore-left-out
    fi
    echo "package database (rpm): the VM's own packages put back: $(wc -l < "$w/rpm-add"), left out: $o, taken away with the restore: $(wc -l < "$w/rpm-gone")"
    if [ -s "$w/rpm-apart" ]; then
      cut -f 2,3 "$w/rpm-apart" | sed 's/\t/ needs /; s/^/a version apart (rpm): /' >>/var/log/breadstick-vm-restore.log
      echo "package database (rpm): a version apart from the system's (the next full upgrade levels them): $(cut -f 2 "$w/rpm-apart" | sort -u | wc -l)"
    fi
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
    t=$(printf '\t')
    bsl_pac_id() { awk '/^%NAME%$/ { getline; n = $0 } /^%VERSION%$/ { getline; v = $0 } /^%ARCH%$/ { getline; a = $0 }
      END { printf "%s\t%s-%s-%s\n", n, n, v, a }' "$1"; }
    : > "$w/pac-kept"
    for d in /var/lib/pacman/local/*/; do
      d=${d%/}
      [ -f "$d/desc" ] && [ ! -e "$s$d" ] || continue
      id=$(bsl_pac_id "$d/desc")
      pn=${id%%"$t"*}
      if [ -n "$pn" ] && grep -qxF -e "$pn" "$w/pac-have"; then rm -rf "$d"; else printf '%s\t%s\t%s\n' "$pn" "$d" "${id#*"$t"}" >> "$w/pac-kept"; fi
    done
    o=0
    # The VM's entries the restore took away with the files it took (round 11, H3: a kernel installed after the image),
    # from the copy kept before it, each by its own name, version and processor: put back when every file it lists is
    # there; taken away with the rest that came after the image when none of its files was kept; else left out and named.
    : > "$w/pac-miss"
    : > "$w/pac-gone"
    if [ -d "$w/pacdb/local" ]; then
      for e in "$w"/pacdb/local/*/; do
        e=${e%/}
        b=${e##*/}
        [ -f "$e/desc" ] || continue
        [ ! -e "/var/lib/pacman/local/$b" ] && [ ! -e "$s/var/lib/pacman/local/$b" ] || continue
        id=$(bsl_pac_id "$e/desc")
        pn=${id%%"$t"*}
        [ -n "$pn" ] || continue
        if grep -qxF -e "$pn" "$w/pac-have" || cut -f 1 "$w/pac-kept" | grep -qxF -e "$pn"; then continue; fi
        m=0
        h=0
        if [ -f "$e/files" ]; then
          awk '/^%FILES%$/ { on = 1; next } /^$/ { on = 0 } on' "$e/files" > "$w/pac-files"
          while IFS= read -r p; do
            [ -n "$p" ] || continue
            if [ -e "/$p" ] || [ -L "/$p" ]; then case "$p" in */) ;; *) h=$((h + 1)) ;; esac; else m=$((m + 1)); fi
          done < "$w/pac-files"
        fi
        if [ "$m" != 0 ] && [ "$h" = 0 ]; then
          printf '%s\n' "${id#*"$t"}" >> "$w/pac-gone"
        elif [ "$m" != 0 ]; then
          printf '%s\n' "${id#*"$t"}" >> "$w/pac-miss"
        else
          cp -a "$e" "/var/lib/pacman/local/$b"
          printf '%s\t%s\t%s\n' "$pn" "/var/lib/pacman/local/$b" "${id#*"$t"}" >> "$w/pac-kept"
        fi
      done
    fi
    if [ -s "$w/pac-miss" ]; then
      tee -a "$w/left-pac" < "$w/pac-miss" | sed 's/^/left out (pacman): /' >>/var/log/breadstick-vm-restore.log
      o=$(wc -l < "$w/pac-miss")
    fi
    sed 's/^/taken away (pacman): /' "$w/pac-gone" >>/var/log/breadstick-vm-restore.log
    : > "$w/pac-apart"
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
        # A versioned dependency whose name the system has (at another version) is a version apart, which pacman
        # itself leaves alone (an already broken dependency is ignored) and -Syu levels; never a reason to leave out.
        awk -F "\047" '/ dependency for \047/ { d = $2; if (sub(/[<>=].*$/, "", d)) print d }' "$w/pac-c1" | sort -u > "$w/pac-vdeps"
        : > "$w/pac-sat"
        while IFS= read -r d; do
          if pacman -T "$d" >/dev/null 2>&1; then printf '%s\n' "$d" >> "$w/pac-sat"; fi
        done < "$w/pac-vdeps"
        awk -F '\t' 'FILENAME == ARGV[1] { kept[$1] = 1; next }
          FILENAME == ARGV[2] { sat[$0] = 1; next }
          { split($0, q, "\047"); d = q[2] }
          / dependency for \047/ {
            if (!(q[4] in kept)) print "other"
            else if (sub(/[<>=].*$/, "", d) && (d in sat)) print "apart\t" q[4] "\t" q[2]
            else print "bad\t" q[4]
            next
          }
          / conflicts with \047/ { m = 0; if (q[2] in kept) { print "bad\t" q[2]; m = 1 } if (q[4] in kept) { print "bad\t" q[4]; m = 1 } if (!m) print "other"; next }
          { print "other" }' "$w/pac-kept" "$w/pac-sat" "$w/pac-c1" > "$w/pac-why"
        awk -F '\t' 'FILENAME == ARGV[1] { kept[$1] = $0; next } $1 == "bad" { b[$2] = 1 } END { for (x in b) print kept[x] }' \
          "$w/pac-kept" "$w/pac-why" > "$w/pac-bad"
        i=$((i + 1))
        if [ ! -s "$w/pac-bad" ]; then
          if ! grep -q '^other' "$w/pac-why"; then grep '^apart' "$w/pac-why" | sort -u > "$w/pac-apart" || true; break; fi
          cp "$w/pac-kept" "$w/pac-bad"
        elif [ "$i" -gt 50 ]; then cp "$w/pac-kept" "$w/pac-bad"; fi
        cut -f 2 "$w/pac-bad" | while IFS= read -r d; do mv "$d" "$w/pac-out/"; done
        cut -f 3 "$w/pac-bad" | tee -a "$w/left-pac" | sed 's/^/left out (pacman): /' >>/var/log/breadstick-vm-restore.log
        awk -F '\t' 'FILENAME == ARGV[1] { b[$1] = 1; next } !($1 in b)' "$w/pac-bad" "$w/pac-kept" > "$w/pac-kept.1"
        o=$((o + $(wc -l < "$w/pac-bad")))
        mv -f "$w/pac-kept.1" "$w/pac-kept"
      done
    fi
    # Recorded like dpkg's and rpm's (`pacman <name>-<version>-<processor>`); Arch never syncs by itself, so nothing
    # installs them but the user's own update.
    [ ! -s "$w/left-pac" ] || sort -u "$w/left-pac" | sed 's/^/pacman /' >> /var/lib/breadstick-vm/restore-left-out
    echo "package database (pacman): the VM's own packages kept: $(wc -l < "$w/pac-kept"), left out: $o, taken away with the restore: $(wc -l < "$w/pac-gone")"
    if [ -s "$w/pac-apart" ]; then
      cut -f 2,3 "$w/pac-apart" | sed 's/\t/ needs /; s/^/a version apart (pacman): /' >>/var/log/breadstick-vm-restore.log
      echo "package database (pacman): a version apart from the system's (the next full upgrade levels them): $(cut -f 2 "$w/pac-apart" | sort -u | wc -l)"
    fi
  )
  r=$?
  set -e
  [ "$r" = 0 ] || echo "package database (pacman): not checked (exit $r)"
fi
rm -rf "$s" "$w"
sync
echo restored
