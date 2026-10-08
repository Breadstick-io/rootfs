# Breadstick VM: the app's display, for shells opened in the VM (Terminal tabs, SSH).
[ -z "$DISPLAY" ] && export DISPLAY=:0
export NO_AT_BRIDGE=1
# Mesa would try kopper (zink) on the app's display and hang with no Vulkan driver (VmCommands.kt).
export LIBGL_KOPPER_DISABLE=1
