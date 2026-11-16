mkdir -p /run/sshd; /usr/sbin/sshd -D -e & p=$!; trap 'pkill -TERM -P $p 2>/dev/null; kill $p 2>/dev/null; exit 0' HUP TERM; wait $p
