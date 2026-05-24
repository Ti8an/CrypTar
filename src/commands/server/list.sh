#!/usr/bin/env bash
[[ -n "${_SRV_LIST_LOADED:-}" ]] && return 0
_SRV_LIST_LOADED=1

srv_list() {
    local -a names=()
    IFS=$'\n' read -r -d '' -a names < <(cfg_list_servers && printf '\0')

    # Filter blank entries produced when the config is empty
    local -a valid=()
    local n
    for n in "${names[@]}"; do
        [[ -n "$n" ]] && valid+=("$n")
    done

    if [[ ${#valid[@]} -eq 0 ]]; then
        log_info "Серверов не добавлено. Используйте: crypTar --server add"
        return 0
    fi

    # Column widths: index, name, user@host:port, auth, description
    local -r W="3 20 30 10 25"

    ui_separator
    # shellcheck disable=SC2086
    ui_table $W -- "#" "Имя" "Подключение" "Авторизация" "Описание"
    ui_separator

    local i=0 name host user port auth desc
    for name in "${valid[@]}"; do
        host="$(cfg_get "$name" host)"
        user="$(cfg_get "$name" user)"
        port="$(cfg_get "$name" port)"
        auth="$(cfg_get "$name" auth_type)"
        desc="$(cfg_get "$name" description)"
        # shellcheck disable=SC2086
        ui_table $W -- "$i" "$name" "${user}@${host}:${port}" "$auth" "${desc:--}"
        (( i++ ))
    done
    ui_separator
}
