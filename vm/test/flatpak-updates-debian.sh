( export DEBIAN_FRONTEND=noninteractive; apt-get update 2>&1 | tail -1; apt-get full-upgrade -y 2>&1; apt-get autoremove -y 2>&1 | tail -1
); bsl_r=$?; if [ $bsl_r -eq 0 ] && command -v flatpak >/dev/null 2>&1; then echo 'Updating Flatpak apps...'; flatpak update --system -y --noninteractive 2>&1 || bsl_r=$?; fi; exit $bsl_r
