#!/usr/bin/env bash
[[ -n "${_CLOUD_REMOVE_LOADED:-}" ]] && return 0
_CLOUD_REMOVE_LOADED=1

# crypTar --cloud remove [name|index]
# Deletes only the local connection entry (and its tokens). Files and
# folders in the cloud are never touched.
cloud_remove() {
    if (( $# > 1 )); then
        log_err "Использование: crypTar --cloud remove [имя|номер]"
        return 1
    fi

    local -a names=()
    cloud_cfg_names names || return
    if [[ ${#names[@]} -eq 0 ]]; then
        log_info "Облачных подключений нет. Добавьте: crypTar --cloud add"
        return 0
    fi

    local name
    if [[ -n "${1:-}" ]]; then
        name="$(cloud_resolve "$1")" || return
    else
        name="$(cloud_pick 0 "Выберите подключение для удаления")" || { log_info "Отменено."; return 0; }
    fi

    local tbl provider="" account="" line
    tbl="$(cloud_cfg_table)" || return
    while IFS=$'\t' read -r line provider account _; do
        [[ "$line" == "$name" ]] && break
        provider=""; account=""
    done <<< "$tbl"

    local label
    label="$(cloud_provider_label "$provider")"
    if ! ui_confirm "Удалить подключение '$name' ($label${account:+, $account})? Файлы в облаке не будут затронуты"; then
        log_info "Отменено."
        return 0
    fi

    cloud_cfg_remove "$name" || return
    log_ok "Подключение '$name' удалено (локальная конфигурация и токены)"
    case "$provider" in
        gdrive) log_info "Чтобы отозвать доступ приложения: https://myaccount.google.com/permissions" ;;
        yadisk) log_info "Чтобы отозвать доступ приложения: Яндекс ID → Безопасность → доступы приложений" ;;
    esac
    return 0
}
