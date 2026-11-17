p='~/r12/mcp.txt'; case "$p" in '~') p=$HOME;; '~/'*) p=$HOME/${p#\~/};; esac
mkdir -p -- "$(dirname -- "$p")" || exit 2
cat > "$p" || exit 2
realpath -- "$p"
