bsl_m=; if [ -r /usr/lib/breadstick/bsl-os.sh ] && . /usr/lib/breadstick/bsl-os.sh && command -v bsl_pkg_mark >/dev/null 2>&1 && command -v bsl_pkg_also >/dev/null 2>&1 && bsl_pkg_mark install; then bsl_m=1; fi
( [ -z "$bsl_m" ] || bsl_pkg_also $$
set -e
{ B=; grep -qs '^\[breadstick' /etc/yum.repos.d/*.repo /etc/distro.repos.d/*.repo /usr/share/dnf5/repos.d/*.repo && B='breadstick*.'; dnf -y makecache --refresh "--setopt=${B}skip_if_unavailable=True"; }
{ if [ -r /usr/lib/breadstick/bsl-os.sh ]; then n=$(. /usr/lib/breadstick/bsl-os.sh && bsl_pkg_names mpv audacity | tr '\n' ' ') || n='mpv audacity'; else n='mpv audacity'; fi; if [ -z "${n# }" ]; then echo '[BSL] This Linux instance has no package for this; nothing was installed.' >&2; (exit 1); else . /usr/lib/breadstick/bsl-os.sh && bsl_pkg_install mpv audacity; fi; }
fc-cache -f >/dev/null 2>&1 || true
echo 'Installed.'
); bsl_rc=$?; [ -z "$bsl_m" ] || bsl_pkg_unmark $bsl_rc; exit $bsl_rc
