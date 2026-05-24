#!/usr/bin/env bash
[[ -n "${_SRV_REMOVE_LOADED:-}" ]] && return 0
_SRV_REMOVE_LOADED=1

srv_remove() {
    local -a names=()
    IFS=$'\n' read -r -d '' -a names < <(cfg_list_servers && printf '\0')

    local -a valid=()
    local n
    for n in "${names[@]}"; do
        [[ -n "$n" ]] && valid+=("$n")
    done

    if [[ ${#valid[@]} -eq 0 ]]; then
        log_info "Серверов нет. Добавьте первый: crypTar --server add"
        return 0
    fi

    local name
    name="$(ui_select "Выберите сервер для удаления" "${valid[@]}")"

    local host
    host="$(cfg_get "$name" host)"

    if ui_confirm "Удалить сервер '$name' (${host})?"; then
        cfg_remove_server "$name" && log_ok "Сервер '$name' удалён"
    else
        log_info "Отменено."
    fi
}
