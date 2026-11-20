bsl_m=; if [ -r /usr/lib/breadstick/bsl-os.sh ] && . /usr/lib/breadstick/bsl-os.sh && command -v bsl_pkg_mark >/dev/null 2>&1 && command -v bsl_pkg_also >/dev/null 2>&1 && bsl_pkg_mark install; then bsl_m=1; fi
( [ -z "$bsl_m" ] || bsl_pkg_also $$
set -e
e=$(sed -n '1{s/[^a-z].*//;p;}' /run/bsl/engine 2>/dev/null) || e=
case "$e" in vm|proot) ;; *) e=proot; if [ -d /run/systemd/system ] && [ -S /run/systemd/private ] && [ "$(cat /proc/1/comm 2>/dev/null)" = systemd ]; then e=vm; fi ;; esac
if [ "$e" != vm ]; then echo 'Flatpak needs the virtual machine engine. Nothing was installed.'; exit 3; fi
echo '[1/3] Installing Flatpak...'
{ B=; grep -qs '^\[breadstick' /etc/yum.repos.d/*.repo /etc/distro.repos.d/*.repo /usr/share/dnf5/repos.d/*.repo && B='breadstick*.'; dnf -y makecache --refresh "--setopt=${B}skip_if_unavailable=True"; }
{ if [ -r /usr/lib/breadstick/bsl-os.sh ]; then n=$(. /usr/lib/breadstick/bsl-os.sh && bsl_pkg_names flatpak xdg-desktop-portal xdg-desktop-portal-gtk polkit | tr '\n' ' ') || n='flatpak xdg-desktop-portal xdg-desktop-portal-gtk polkit'; else n='flatpak xdg-desktop-portal xdg-desktop-portal-gtk polkit'; fi; if [ -z "${n# }" ]; then echo '[BSL] This Linux instance has no package for this; nothing was installed.' >&2; (exit 1); else . /usr/lib/breadstick/bsl-os.sh && bsl_pkg_install flatpak xdg-desktop-portal xdg-desktop-portal-gtk polkit; fi; }
systemctl disable --now flatpak-add-fedora-repos.service >/dev/null 2>&1 || true
for r in fedora fedora-testing; do flatpak remote-delete --system --force "$r" >/dev/null 2>&1 || true; done
echo '[2/3] Adding Flathub...'
flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
echo '[3/3] Adding Flatpak apps to the Apps page...'
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-breadstick-flatpak.rules <<'BSL_FLATPAK_1'
// Breadstick: written by Get apps > Flatpak.
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.Flatpak.") == 0 && action.id != "org.freedesktop.Flatpak.override-parental-controls" &&
        (subject.isInGroup("sudo") || subject.isInGroup("wheel"))) {
        return polkit.Result.YES;
    }
    return polkit.Result.NOT_HANDLED;
});
BSL_FLATPAK_1
chmod 644 /etc/polkit-1/rules.d/49-breadstick-flatpak.rules
mkdir -p /usr/local/lib/breadstick
cat > /usr/local/lib/breadstick/flatpak-apps <<'BSL_FLATPAK_2'
#!/bin/sh
# Breadstick: Flatpak apps in the Apps page and the desktop menu. Written by Get apps > Flatpak.
mark='X-Breadstick-Flatpak=1'
if [ "$(id -u)" = 0 ]; then
    src=/var/lib/flatpak/exports/share
    dst=/usr/local/share/applications
else
    src=${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/exports/share
    dst=${XDG_DATA_HOME:-$HOME/.local/share}/applications
fi
[ -d "$src/applications" ] || [ -d "$dst" ] || exit 0
mkdir -p "$dst" || exit 1
for t in "$dst"/*.desktop; do
    [ -f "$t" ] && [ ! -h "$t" ] || continue
    grep -qx "$mark" "$t" || continue
    [ -f "$src/applications/${t##*/}" ] || rm -f "$t"
done
for s in "$src"/applications/*.desktop; do
    [ -f "$s" ] || continue
    t=$dst/${s##*/}
    if [ -e "$t" ] || [ -h "$t" ]; then
        [ -f "$t" ] && [ ! -h "$t" ] && grep -qx "$mark" "$t" || continue
    fi
    icon=$(sed -n 's/^Icon=//p' "$s" | head -n 1)
    path=
    case "$icon" in
        ''|/*|*/*) ;;
        *)
            for c in scalable/apps/"$icon".svg 512x512/apps/"$icon".png 256x256/apps/"$icon".png \
                128x128/apps/"$icon".png 96x96/apps/"$icon".png 64x64/apps/"$icon".png 48x48/apps/"$icon".png; do
                [ -f "$src/icons/hicolor/$c" ] && { path=$src/icons/hicolor/$c; break; }
            done ;;
    esac
    awk -v icon="$path" -v mark="$mark" '
        /^\[/ { main = ($0 ~ /^\[Desktop Entry\][ \t\r]*$/); print; if (main && !done) { print mark; done = 1 }; next }
        main && icon != "" && /^Icon=/ { print "Icon=" icon; next }
        $0 == mark { next }
        { print }
    ' "$s" > "$t.bsl-new" || { rm -f "$t.bsl-new"; continue; }
    if [ -f "$t" ] && cmp -s "$t.bsl-new" "$t"; then rm -f "$t.bsl-new"; else chmod 644 "$t.bsl-new"; mv -f "$t.bsl-new" "$t"; fi
done
exit 0
BSL_FLATPAK_2
chmod 755 /usr/local/lib/breadstick/flatpak-apps
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/bsl-flatpak-apps.path <<'BSL_FLATPAK_3'
[Unit]
Description=Breadstick: Flatpak apps for the Apps page

[Path]
PathChanged=/var/lib/flatpak/exports/share/applications

[Install]
WantedBy=multi-user.target
BSL_FLATPAK_3
chmod 644 /etc/systemd/system/bsl-flatpak-apps.path
mkdir -p /etc/systemd/system
cat > /etc/systemd/system/bsl-flatpak-apps.service <<'BSL_FLATPAK_4'
[Unit]
Description=Breadstick: Flatpak apps for the Apps page

[Service]
Type=oneshot
ExecStart=/usr/local/lib/breadstick/flatpak-apps
BSL_FLATPAK_4
chmod 644 /etc/systemd/system/bsl-flatpak-apps.service
mkdir -p /etc/systemd/user
cat > /etc/systemd/user/bsl-flatpak-apps.path <<'BSL_FLATPAK_5'
[Unit]
Description=Breadstick: Flatpak apps for the Apps page

[Path]
PathChanged=%h/.local/share/flatpak/exports/share/applications

[Install]
WantedBy=default.target
BSL_FLATPAK_5
chmod 644 /etc/systemd/user/bsl-flatpak-apps.path
mkdir -p /etc/systemd/user
cat > /etc/systemd/user/bsl-flatpak-apps.service <<'BSL_FLATPAK_6'
[Unit]
Description=Breadstick: Flatpak apps for the Apps page

[Service]
Type=oneshot
ExecStart=/usr/local/lib/breadstick/flatpak-apps
BSL_FLATPAK_6
chmod 644 /etc/systemd/user/bsl-flatpak-apps.service
systemctl daemon-reload
systemctl enable --now bsl-flatpak-apps.path >/dev/null 2>&1
systemctl --global enable bsl-flatpak-apps.path >/dev/null 2>&1 || true
for d in /run/user/*; do [ -S "$d/bus" ] || continue; u=$(id -un "${d##*/}" 2>/dev/null) || continue; [ "$u" != root ] || continue
  systemctl --user -M "$u@" daemon-reload >/dev/null 2>&1 && systemctl --user -M "$u@" start bsl-flatpak-apps.path >/dev/null 2>&1 || true
done
/usr/local/lib/breadstick/flatpak-apps
echo 'Done.'
); bsl_rc=$?; [ -z "$bsl_m" ] || bsl_pkg_unmark $bsl_rc; exit $bsl_rc
