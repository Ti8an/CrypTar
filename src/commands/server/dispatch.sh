#!/usr/bin/env bash
[[ -n "${_SRV_DISPATCH_LOADED:-}" ]] && return 0
_SRV_DISPATCH_LOADED=1

# [FIX 4] Shared helper — always sourced before any subcommand file.
# Uses nameref so the caller's array is populated directly (bash 4.3+).
# Local names are prefixed with _ to avoid colliding with the caller's locals.
_srv_get_valid_names() {
    local -n _out="$1"
    local -a _raw=()
    IFS=$'\n' read -r -d '' -a _raw < <(cfg_list_servers && printf '\0')
    local _n
    for _n in "${_raw[@]}"; do
        [[ -n "$_n" ]] && _out+=("$_n")
    done
}

# Entry point receives "$@" from crypTar where $1="--server", $2=subcommand, $3=optional arg.
srv_dispatch() {
    case "${2:-}" in
        list)
            source "$SRC_DIR/commands/server/list.sh"
            srv_list
            ;;
        add)
            source "$SRC_DIR/commands/server/add.sh"
            srv_add
            ;;
        remove)
            source "$SRC_DIR/commands/server/remove.sh"
            srv_remove
            ;;
        push-key)
            source "$SRC_DIR/commands/server/push_key.sh"
            srv_push_key "${3:-}"
            ;;
        set-key)
            source "$SRC_DIR/commands/server/set_key.sh"
            srv_set_key
            ;;
        *)
            log_err "Неизвестная подкоманда. Использование: crypTar --server list|add|remove|push-key|set-key"
            exit 1
            ;;
    esac
}
