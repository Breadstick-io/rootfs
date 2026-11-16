dnf -q -y makecache >/dev/null 2>&1; o=$(dnf -q check-upgrade 2>/dev/null); r=$?; if [ $r = 0 ] || [ $r = 100 ]; then printf '%s\n' "$o" | grep -c '\.'; else (exit 1); fi
