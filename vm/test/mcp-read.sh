p='~/r12/mcp.txt'; case "$p" in '~') p=$HOME;; '~/'*) p=$HOME/${p#\~/};; esac
[ -f "$p" ] || { echo "$p is not a regular file"; exit 2; }
echo "$(realpath -- "$p")"; stat -L -c %s -- "$p"; head -c 4096 -- "$p" | base64 -w0
