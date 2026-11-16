m=/var/lib/breadstick/package-run
if [ -e "$m" ] || [ -e "$m.cut" ]; then
  echo 'BSL-RUN check'
  ( if [ -r /usr/lib/breadstick/bsl-os.sh ] && . /usr/lib/breadstick/bsl-os.sh && command -v bsl_pkg_interrupted >/dev/null 2>&1; then if bsl_pkg_interrupted; then bsl_pkg_repair; else echo '[BSL] No package run was cut off.'; fi; else echo '[BSL] This Linux instance cannot check for a cut-off package run.' >&2; exit 1; fi ) 2>&1; echo "BSL-RUN exit $?"
fi
[ ! -e "$m" ] || echo 'BSL-RUN marked'
[ ! -e "$m.cut" ] || echo 'BSL-RUN cut'
exit 0
