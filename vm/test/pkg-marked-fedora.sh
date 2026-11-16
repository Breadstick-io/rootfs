bsl_m=; if [ -r /usr/lib/breadstick/bsl-os.sh ] && . /usr/lib/breadstick/bsl-os.sh && command -v bsl_pkg_mark >/dev/null 2>&1 && command -v bsl_pkg_also >/dev/null 2>&1 && bsl_pkg_mark upgrade; then bsl_m=1; fi
( [ -z "$bsl_m" ] || bsl_pkg_also $$
sleep 4243
); bsl_rc=$?; [ -z "$bsl_m" ] || bsl_pkg_unmark $bsl_rc; exit $bsl_rc
