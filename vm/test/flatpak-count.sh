if command -v flatpak >/dev/null 2>&1; then flatpak remote-ls --system --updates --columns=ref 2>/dev/null | grep -c /; else echo 0; fi
