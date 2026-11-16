if [ -x /nix/var/nix/profiles/system/sw/bin/bsl-nix ]; then /nix/var/nix/profiles/system/sw/bin/bsl-nix check; else echo '[BSL] This Nix system has no bsl-nix; nothing was changed.' >&2; (exit 1); fi
