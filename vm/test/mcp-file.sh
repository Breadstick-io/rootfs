set -e; umask 077; u='tester'; f=/run/bsl/mcp; mkdir -p /run/bsl; cat > "$f.tmp"; chown "$u": "$f.tmp"; mv -f "$f.tmp" "$f"
