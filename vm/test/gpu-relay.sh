exec 2>>/run/bsl-relay.log
r=/usr/lib/breadstick-vm/bsl-x11-relay
[ -x "$r" ] || r=$(systemctl show -P ExecStart bsl-x11-relay.service 2>/dev/null | sed -n 's/^{ path=\([^ ;]*\).*/\1/p')
[ -n "$r" ] && [ -x "$r" ] || exit 3
s=/run/breadstick-vm/relay/virgl.sock p=/run/bsl/virgl.sock
mkdir -p /run/breadstick-vm/relay /run/bsl
rm -f "$p"
"$r" 6104 "$s" & k=$!
trap 'kill $k 2>/dev/null; rm -f "$p"; exit 0' HUP TERM
i=0; while [ ! -S "$s" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
ln -sfn "$s" "$p"
wait $k; st=$?; rm -f "$p"; exit $st
