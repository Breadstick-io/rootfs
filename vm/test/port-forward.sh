exec bash -c 'exec 2>/dev/null 4<&0; { exec 3<>/dev/tcp/127.0.0.1/2222; } || exit 7; cat <&4 >&3 & c=$!; cat <&3; kill $c; exit 0'
