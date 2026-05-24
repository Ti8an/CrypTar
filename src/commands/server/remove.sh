#!/usr/bin/env bash
[[ -n "${_SRV_REMOVE_LOADED:-}" ]] && return 0
_SRV_REMOVE_LOADED=1

srv_remove() {
    # [FIX 4] Use shared helper from dispatch.sh (always sourced first)
    local -a valid=()
    _srv_get_valid_names valid

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
