#!/usr/bin/env bash
[[ -n "${_SRV_DISPATCH_LOADED:-}" ]] && return 0
_SRV_DISPATCH_LOADED=1

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
        *)
            log_err "Неизвестная подкоманда. Использование: crypTar --server list|add|remove|push-key"
            exit 1
            ;;
    esac
}
