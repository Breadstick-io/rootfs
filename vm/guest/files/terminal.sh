# Breadstick VM: a Terminal tab gets the agent's runtime dir and bus back after a desktop session stops (plan 5.14 V9).
#
# breadstick-terminal.sh (breadstick-theme, the same file every Debian system has) gives a tab the lines of
# /run/bsl/session before each prompt and takes back, after Stop, what it set and the session no longer gives: unset.
# A VM tab starts on the agent's runtime dir and bus (systemd's, for the user), which the app hands over to that hook as
# its own (Android VmCommands.TAB_SEED: __bsl_session_vars, __bsl_v_<name>), with the agent's values beside them as
# __bsl_agent_<name>, so a session's are taken while it runs. This wraps the hook so that a name it takes back is given
# the agent's value again and kept as the hook's (the next session's are taken again), not unset.
#
# Only VM images have it: vm/guest/install.sh puts it after files/profile.sh in /etc/profile.d/breadstick-vm.sh, which
# sorts after breadstick-terminal.sh; breadstick-vm.nix adds it to NixOS's interactiveShellInit after the Breadstick
# module's (/etc/bashrc). So the bytes Debian's packages ship are what 3.x has (round 10, Debian unchanged). The app's
# seed looks for __bsl_agent_ in those files to know the tab gets its values back. Nothing else sets __bsl_agent_;
# without it, or without breadstick-terminal.sh's hook, this does nothing. Plain POSIX sh outside the bash branch, as
# every login shell reads profile.d; builtins only once a prompt runs.
if [ "${BREADSTICK_TERMINAL:-}" = 1 ] && [ -n "${BASH_VERSION:-}" ]; then
    if declare -F __bsl_session_env >/dev/null && declare -F __bsl_session_ret >/dev/null &&
            ! declare -F __bsl_vm_session_env_base >/dev/null; then
        # The hook as breadstick-terminal.sh defined it, under another name (its body unchanged).
        __bsl_vm_f=$(declare -f __bsl_session_env)
        eval "__bsl_vm_session_env_base${__bsl_vm_f#__bsl_session_env}"
        unset __bsl_vm_f
        __bsl_session_env() {
            # $? and $_ are the user's command's, handed on to the hook and given back after it (as the hook does).
            local rc=$? arg=$_ name cur last isset agent back
            back=
            # What the hook will take back if this prompt's lines do not set it again: a name it set last time that
            # still holds what it set, with an agent value to give back.
            for name in ${__bsl_session_vars:-}; do
                case "$name" in ""|*[!A-Za-z0-9_]*) continue ;; esac
                eval "cur=\${$name-} last=\${__bsl_v_$name-} isset=\${$name+x} agent=\${__bsl_agent_$name-}"
                [ -n "$isset" ] && [ "$cur" = "$last" ] && [ -n "$agent" ] && back="$back $name"
            done
            __bsl_session_ret "$rc" "$arg"
            __bsl_vm_session_env_base
            for name in $back; do
                # Set again by this prompt's lines (a session runs): the session's, as the hook left it.
                case " ${__bsl_session_vars:-} " in *" $name "*) continue ;; esac
                eval "agent=\${__bsl_agent_$name}"
                export "$name=$agent"
                eval "__bsl_v_$name=\$agent"
                __bsl_session_vars="${__bsl_session_vars:+$__bsl_session_vars }$name"
            done
            __bsl_session_ret "$rc" "$arg"
        }
    fi
fi
