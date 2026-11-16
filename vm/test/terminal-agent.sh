#!/bin/sh
# A VM Terminal tab's runtime dir and bus (plan 5.14 V9) with Debian's breadstick-terminal.sh as 3.x ships it and the
# VM's own wrapper (vm/guest/files/terminal.sh, after files/profile.sh in /etc/profile.d/breadstick-vm.sh): the tab
# starts on the agent's values (the app's seed, Android VmCommands.TAB_SEED), takes a desktop session's from
# /run/bsl/session while it runs, gets the agent's back after Stop, takes the next session's again, and keeps a value
# the user set. $? and $_ reach the user's prompt unchanged. And with no agent values (every proot tab) the wrapper
# changes nothing: each step's environment is the same as with breadstick-terminal.sh alone.
#
# With ORACLE (default: packages 3c73426's breadstick-terminal.sh, round 9's V9 change, read with git from the packages
# checkout when it has that commit) every step's environment is also compared with that file alone: the wrapper does
# what round 9's change did, outside Debian's package.
#
#   vm/test/terminal-agent.sh
#   PKGROOT=<packages checkout>   default the packages checkout beside this rootfs checkout
# Runs in debian:trixie (--network none, container bsl-terminal-agent-<pid>, removed after). Each line "ok" or "FAIL".
set -eu
here=$(cd "$(dirname "$0")" && pwd)
guest=$(cd "$here/../guest" && pwd)
if [ -z "${PKGROOT:-}" ]; then
  common=$(cd "$here" && cd "$(git rev-parse --git-common-dir)" && pwd)
  PKGROOT="$(dirname "$(dirname "$common")")/packages"
fi
term="$PKGROOT/breadstick-theme/src/etc/profile.d/breadstick-terminal.sh"
[ -f "$term" ] || { echo "terminal-agent: no $term (set PKGROOT)" >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/bsl-termagent.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp "$term" "$work/breadstick-terminal.sh"
cat "$guest/files/profile.sh" "$guest/files/terminal.sh" > "$work/breadstick-vm.sh"
cp "$guest/files/profile.sh" "$work/profile-only.sh"   # the VM's profile without the wrapper, for the comparisons
oracle=
if git -C "$PKGROOT" cat-file -e "${ORACLE:-3c73426}:breadstick-theme/src/etc/profile.d/breadstick-terminal.sh" 2>/dev/null; then
  git -C "$PKGROOT" show "${ORACLE:-3c73426}:breadstick-theme/src/etc/profile.d/breadstick-terminal.sh" > "$work/v9.sh"
  oracle=1
fi

cat > "$work/steps.sh" <<'BSL_TERMAGENT_STEPS_x4'
# steps.sh MODE SEED: one bash, the profile files of MODE sourced as a login shell would, then the prompts.
#   MODE: wrap (Debian's file, then the VM's), plain (Debian's alone), v9 (round 9's file alone)
#   SEED: 1 = the app's seed (agent values handed over), 0 = none (a proot tab)
mode=$1 seed=$2
export BREADSTICK_TERMINAL=1 USER=tester
export XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
if [ "$seed" = 1 ]; then
  export __bsl_session_vars="XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS" \
    __bsl_v_XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" __bsl_v_DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
    __bsl_agent_XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" __bsl_agent_DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
fi
load() {
  case $mode in
    wrap) . /t/breadstick-terminal.sh; . /t/breadstick-vm.sh ;;
    plain) . /t/breadstick-terminal.sh; . /t/profile-only.sh ;;
    v9) . /t/v9.sh; . /t/profile-only.sh ;;
  esac
}
if [ "${3:-}" = interactive ]; then
  # A real interactive bash (PROMPT_COMMAND and the DEBUG trap as a tab runs them): what the user's command lines see.
  load
  return 0 2>/dev/null || exit 0
fi
load
show() {  # the variables a tab's programs see, and the hook's own record
  echo "[$1] XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR-<unset>} DBUS=${DBUS_SESSION_BUS_ADDRESS-<unset>} DISPLAY=${DISPLAY-<unset>} NO_AT_BRIDGE=${NO_AT_BRIDGE-<unset>} vars=[$(echo ${__bsl_session_vars:-})]"
}
session() { mkdir -p /run/bsl; printf 'BSL_SESSION_USER=tester\nXDG_RUNTIME_DIR=/tmp/runtime-tester\nDBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/runtime-tester/bus\nDISPLAY=:0\n' > /run/bsl/session; }
stop() { rm -f /run/bsl/session; }
stop
__bsl_session_env; show "no session"
session; __bsl_session_env; show "a session runs"
stop; __bsl_session_env; show "after Stop"
__bsl_session_env; show "a second prompt"
session; __bsl_session_env; show "the next session"
stop; __bsl_session_env; show "after the second Stop"
session; __bsl_session_env; export XDG_RUNTIME_DIR=/home/tester/mine
stop; __bsl_session_env; show "the user's own value, after Stop"
BSL_TERMAGENT_STEPS_x4
cat > "$work/lines" <<'BSL_TERMAGENT_LINES_x4'
false
echo "[exit status] $?"
: the-last-word
echo "[last argument] $_"
echo "[interactive] XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR-<unset>} DBUS=${DBUS_SESSION_BUS_ADDRESS-<unset>}"
BSL_TERMAGENT_LINES_x4

name="bsl-terminal-agent-$$"
docker run --rm --name "$name" --platform linux/arm64 --network none -v "$work:/t:ro" debian:trixie sh -c '
  for m in wrap plain v9; do
    [ "$m" = v9 ] && [ ! -f /t/v9.sh ] && continue
    for s in 1 0; do
      bash /t/steps.sh $m $s > /tmp/$m.$s 2>&1
      # The rc file takes the mode and seed from the environment (bash --rcfile passes no arguments).
      printf "set -- %s %s interactive\n. /t/steps.sh %s %s interactive\n" $m $s $m $s > /tmp/rc.$m.$s
      bash --rcfile /tmp/rc.$m.$s -i < /t/lines 2>/dev/null | grep "^\[" >> /tmp/$m.$s
      echo "== $m $s"; cat /tmp/$m.$s
    done
  done' > "$work/out" 2>&1 || { echo "FAIL the container did not run"; cat "$work/out"; exit 1; }

part() { awk -v h="== $1 $2" '$0 == h { p = 1; next } /^== / { p = 0 } p' "$work/out"; }
fails=0
check() {  # check LABEL MODE SEED STEP EXPECTED-LINE
  got=$(part "$2" "$3" | grep -F "[$4]" || true)
  if [ "$got" = "[$4] $5" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "     want: [$4] $5"; echo "     got:  $got"; fails=$((fails + 1)); fi
}
A="XDG_RUNTIME_DIR=/run/user/1000 DBUS=unix:path=/run/user/1000/bus"
S="XDG_RUNTIME_DIR=/tmp/runtime-tester DBUS=unix:path=/tmp/runtime-tester/bus DISPLAY=:0 NO_AT_BRIDGE=1"
V="DISPLAY=:0 NO_AT_BRIDGE=1"   # files/profile.sh exports both before any prompt: the user's, to the hook
check "VM tab, no session: the agent's runtime dir and bus" wrap 1 "no session" \
  "$A $V vars=[XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS]"
check "VM tab while a session runs: the session's" wrap 1 "a session runs" \
  "$S vars=[XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS]"
check "VM tab after Stop: the agent's back" wrap 1 "after Stop" \
  "$A $V vars=[XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS]"
check "VM tab, a second prompt after Stop: still the agent's" wrap 1 "a second prompt" \
  "$A $V vars=[XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS]"
check "VM tab, the next session: taken again" wrap 1 "the next session" \
  "$S vars=[XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS]"
check "VM tab after the second Stop: the agent's back" wrap 1 "after the second Stop" \
  "$A $V vars=[XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS]"
check "VM tab: a runtime dir the user set stays theirs after Stop" wrap 1 "the user's own value, after Stop" \
  "XDG_RUNTIME_DIR=/home/tester/mine DBUS=unix:path=/run/user/1000/bus $V vars=[DBUS_SESSION_BUS_ADDRESS]"
check "VM tab: the user's exit status reaches the prompt" wrap 1 "exit status" "1"
check "VM tab: the user's last argument reaches the prompt" wrap 1 "last argument" "the-last-word"
check "VM tab, interactive with no session: the agent's runtime dir and bus" wrap 1 interactive "$A"
if [ "$(part wrap 0)" = "$(part plain 0)" ] && [ -n "$(part plain 0)" ]; then
  echo "ok   a tab with no agent values (proot): the wrapper changes nothing ($(part plain 0 | wc -l) steps)"
else
  echo "FAIL a tab with no agent values: the wrapper changed something"; diff "$work/out" /dev/null >/dev/null 2>&1 || true
  part plain 0 > "$work/p0"; part wrap 0 > "$work/w0"; diff "$work/p0" "$work/w0" | sed 's/^/     /'; fails=$((fails + 1))
fi
if [ "$(part plain 1 | grep -F '[after Stop]')" != "$(part wrap 1 | grep -F '[after Stop]')" ]; then
  echo "ok   without the wrapper the seed's values are taken back after Stop (what it is for)"
else
  echo "FAIL Debian's file alone already gives the agent's back: the test proves nothing"; fails=$((fails + 1))
fi
if [ -n "$oracle" ]; then
  for s in 1 0; do
    if [ "$(part wrap $s)" = "$(part v9 $s)" ]; then
      echo "ok   seed $s: every step as round 9's breadstick-terminal.sh (${ORACLE:-3c73426}) did it"
    else
      echo "FAIL seed $s: differs from round 9's breadstick-terminal.sh"; part v9 $s > "$work/v"; part wrap $s > "$work/w"
      diff "$work/v" "$work/w" | sed 's/^/     /'; fails=$((fails + 1))
    fi
  done
else
  echo "skip round 9's file is not in $PKGROOT (no oracle)"
fi
[ "$fails" = 0 ] && echo "terminal-agent: PASS" || echo "terminal-agent: $fails FAIL"
[ "$fails" = 0 ]
