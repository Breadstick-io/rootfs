bsl_n=$( { apt-get update >/dev/null 2>&1; apt list --upgradable 2>/dev/null | grep -c upgradable
} | tail -n 1 ); bsl_f=$(if command -v flatpak >/dev/null 2>&1; then flatpak remote-ls --system --updates --columns=ref 2>/dev/null | grep -c /; else echo 0; fi) || true; case "$bsl_n" in ''|*[!0-9]*) echo "$bsl_n" ;; *) case "$bsl_f" in ''|*[!0-9]*) bsl_f=0 ;; esac; echo $((bsl_n + bsl_f)) ;; esac
