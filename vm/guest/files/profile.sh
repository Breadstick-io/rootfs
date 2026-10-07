# Breadstick VM: the app's display, for shells opened in the VM (Terminal tabs, SSH).
[ -z "$DISPLAY" ] && export DISPLAY=:0
export NO_AT_BRIDGE=1
