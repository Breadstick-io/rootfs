( bsl_m=; if [ -r /usr/lib/breadstick/bsl-os.sh ] && . /usr/lib/breadstick/bsl-os.sh && command -v bsl_pkg_mark >/dev/null 2>&1 && command -v bsl_pkg_also >/dev/null 2>&1 && bsl_pkg_mark upgrade; then bsl_m=1; fi
( [ -z "$bsl_m" ] || bsl_pkg_also $$
{ ! command -v bsl_pkg_mend >/dev/null 2>&1 || bsl_pkg_mend; } 2>&1 && pacman -Sy --needed --noconfirm archlinux-keyring && pacman -Su --noconfirm 2>&1 && pacman -S --needed --noconfirm breadstick-desktop 2>&1 && { pacman -S --needed --noconfirm breadstick-print >/dev/null 2>&1 || true; } && { ! command -v bsl_pkg_langfill >/dev/null 2>&1 || ! command -v bsl_region_locales >/dev/null 2>&1 || bsl_pkg_langfill $(bsl_region_locales) 2>&1 || true; }
); bsl_rc=$?; [ -z "$bsl_m" ] || bsl_pkg_unmark $bsl_rc; exit $bsl_rc
); bsl_r=$?; if [ $bsl_r -eq 0 ] && command -v flatpak >/dev/null 2>&1; then echo 'Updating Flatpak apps...'; flatpak update --system -y --noninteractive 2>&1 || bsl_r=$?; fi; exit $bsl_r
