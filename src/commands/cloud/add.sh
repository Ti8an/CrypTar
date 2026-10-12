#!/usr/bin/env bash
[[ -n "${_CLOUD_ADD_LOADED:-}" ]] && return 0
_CLOUD_ADD_LOADED=1

_CLOUD_ADD_MAX_TRIES=5

# Fill conn[client_id] / conn[client_secret] for the provider. Sources, in
# order: environment (CRYPTAR_GDRIVE_CLIENT_ID/_SECRET,
# CRYPTAR_YADISK_CLIENT_ID/_SECRET), an existing connection of the same
# provider (on confirmation), interactive input (secret is hidden).
_cloud_add_client() {
    local cref="$1"
    local -n __cac="$1"
    local p="${__cac[provider]}" up id_var secret_var
    up="${p^^}"
    id_var="CRYPTAR_${up}_CLIENT_ID"
    secret_var="CRYPTAR_${up}_CLIENT_SECRET"

    if [[ -n "${!id_var:-}" && -n "${!secret_var:-}" ]]; then
        __cac[client_id]="${!id_var}"
        __cac[client_secret]="${!secret_var}"
        log_info "OAuth-клиент взят из переменных окружения $id_var / $secret_var"
        return 0
    fi

    # Collect candidates first: prompting inside a `while read` loop would
    # read the answer from the loop's input instead of the terminal.
    local tbl n prov _a _f
    local -a same=()
    tbl="$(cloud_cfg_table)" || tbl=""
    while IFS=$'\t' read -r n prov _a _f; do
        [[ -n "$n" && "$prov" == "$p" ]] && same+=("$n")
    done <<< "$tbl"
    for n in "${same[@]}"; do
        if ui_confirm "Использовать OAuth-клиент из подключения '$n'?"; then
            local -A __src=()
            cloud_cfg_load "$n" __src || return
            __cac[client_id]="${__src[client_id]:-}"
            __cac[client_secret]="${__src[client_secret]:-}"
            __src=()
            [[ -n "${__cac[client_id]}" && -n "${__cac[client_secret]}" ]] && return 0
            log_warn "В подключении '$n' нет данных OAuth-клиента"
        fi
        break
    done

    case "$p" in
        gdrive) log_info "Нужен OAuth-клиент Google типа «TVs and Limited Input devices» (см. README)." ;;
        yadisk) log_info "Нужно приложение Яндекс OAuth с правами cloud_api:disk.* (см. README)." ;;
    esac
    __cac[client_id]="$(_cloud_trim "$(ui_prompt "Client ID")")"
    __cac[client_secret]="$(_cloud_trim "$(ui_secret "Client secret")")"
    if [[ -z "${__cac[client_id]}" || -z "${__cac[client_secret]}" ]]; then
        log_err "Client ID и Client secret обязательны — подключение не создано."
        return $CLOUD_E_CONFIG
    fi
}

# Ask for and normalize the destination folder into conn[folder].
_cloud_add_folder() {
    local -n __caf="$1"
    local p="${__caf[provider]}" def raw norm try
    def="$(cloud_provider_call "$p" default_folder)"
    for (( try = 0; try < _CLOUD_ADD_MAX_TRIES; try++ )); do
        raw="$(ui_prompt "Папка назначения в облаке" "${__caf[folder]:-$def}")"
        if norm="$(cloud_provider_call "$p" normalize_folder "$raw")"; then
            __caf[folder]="$norm"
            return 0
        fi
        log_err "Некорректный путь папки: '$raw'"
    done
    return $CLOUD_E_CONFIG
}

# Fetch the account identifier. A permission error (token without the
# account-info right) is not fatal; anything else is.
_cloud_add_account() {
    local cref="$1" rc=0
    local -n __caa="$1"
    cloud_provider_call "${__caa[provider]}" account "$cref" || rc=$?
    if (( rc == CLOUD_E_PERM )); then
        log_warn "Идентификатор аккаунта недоступен (нет прав) — продолжаем"
        return 0
    fi
    return $rc
}

# crypTar --cloud add — interactive wizard. Never overwrites a connection.
cloud_add() {
    if (( $# > 0 )); then
        log_err "Использование: crypTar --cloud add"
        return 1
    fi
    cloud_require_deps || return

    log_info "Добавление облачного подключения"
    ui_separator

    # Step 1: provider
    local -a labels=() ids=()
    local p
    for p in "${CLOUD_PROVIDER_IDS[@]}"; do
        ids+=("$p"); labels+=("$(cloud_provider_label "$p")")
    done
    local sel provider=""
    sel="$(ui_select "Провайдер" "${labels[@]}")"
    for p in "${!labels[@]}"; do
        [[ "${labels[$p]}" == "$sel" ]] && provider="${ids[$p]}"
    done
    [[ -n "$provider" ]] || { log_err "Провайдер не выбран"; return 1; }

    # Step 2: unique name
    local name="" try
    for (( try = 0; try < _CLOUD_ADD_MAX_TRIES; try++ )); do
        name="$(_cloud_trim "$(ui_prompt "Имя подключения (например google-work)")")"
        if ! cloud_validate_name "$name"; then
            log_err "Недопустимое имя: 1–64 символа a-z A-Z 0-9 _ -, начинается с буквы/цифры, не только цифры"
            name=""; continue
        fi
        if cloud_cfg_exists "$name"; then
            log_err "Подключение '$name' уже существует — выберите другое имя"
            name=""; continue
        fi
        break
    done
    [[ -n "$name" ]] || { log_err "Имя не задано — отменено."; return 1; }

    local -A conn=([name]="$name" [provider]="$provider" [_unsaved]=1)
    local qname
    printf -v qname '%q' "$name"

    # Step 3: OAuth client, encryption key (checked before authorizing so the
    # result can actually be saved)
    _cloud_add_client conn || return
    cloud_ensure_encrypt_key || return

    # Step 4: authorization + access check
    local rc=0
    CLOUD_CTX_NAME="$name"
    cloud_provider_call "$provider" auth conn || rc=$?
    if (( rc != 0 )); then
        log_err "Авторизация не выполнена — подключение не сохранено."
        return $rc
    fi
    _cloud_add_account conn || { log_err "Не удалось проверить доступ к аккаунту — подключение не сохранено."; return $CLOUD_E_AUTH; }
    [[ -n "${conn[account]:-}" ]] && log_ok "Аккаунт: ${conn[account]}"

    # Step 5: destination folder (created if missing)
    _cloud_add_folder conn || return
    rc=0
    cloud_provider_call "$provider" ensure_folder conn || rc=$?
    if (( rc != 0 )); then
        log_err "Папка назначения недоступна — подключение не сохранено."
        return $rc
    fi

    # Step 6: save (duplicate check repeated under the config lock)
    conn[created]="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cloud_cfg_add conn || { rc=$?; conn=(); return $rc; }
    conn=()
    log_ok "Подключение '$name' ($(cloud_provider_label "$provider")) сохранено"
    log_info "Проверка: crypTar --cloud test $qname   Загрузка: crypTar --cloud send --to $qname <путь>"
    return 0
}

# crypTar --cloud reauth [name|index] — re-run authorization for an existing
# connection (expired/revoked token) without changing its name or settings.
cloud_reauth() {
    if (( $# > 1 )); then
        log_err "Использование: crypTar --cloud reauth [имя|номер]"
        return 1
    fi
    cloud_require_deps || return

    local name
    if [[ -n "${1:-}" ]]; then
        name="$(cloud_resolve "$1")" || return
    else
        name="$(cloud_pick 0 "Выберите подключение для повторной авторизации")" || { log_info "Отменено."; return 0; }
    fi

    local -A conn=()
    cloud_cfg_load "$name" conn || return
    local provider="${conn[provider]}" old_account="${conn[account]:-}" rc=0
    conn[_unsaved]=1
    conn[refresh_token]=""; conn[access_token]=""; conn[expires_at]=""
    CLOUD_CTX_NAME="$name"

    cloud_provider_call "$provider" auth conn || rc=$?
    if (( rc != 0 )); then
        conn=()
        log_err "Авторизация не выполнена — конфигурация не изменена."
        return $rc
    fi
    _cloud_add_account conn || { conn=(); return $CLOUD_E_AUTH; }

    if [[ -n "$old_account" && -n "${conn[account]:-}" && "$old_account" != "${conn[account]}" ]]; then
        if ! ui_confirm "Авторизован другой аккаунт (${conn[account]} вместо $old_account). Сохранить?"; then
            conn=()
            log_info "Отменено — конфигурация не изменена."
            return 0
        fi
        conn[folder_id]=""   # folder IDs belong to the previous account
    fi

    local -a pairs=()
    local k
    for k in refresh_token access_token expires_at account device_id folder_id; do
        [[ -n "${conn[$k]+x}" ]] && pairs+=("$k" "${conn[$k]}")
    done
    cloud_cfg_set "$name" "${pairs[@]}" || { rc=$?; conn=(); return $rc; }
    unset 'conn[_unsaved]'

    cloud_provider_call "$provider" ensure_folder conn || rc=$?
    conn=()
    if (( rc != 0 )); then
        log_warn "Авторизация сохранена, но папка назначения недоступна."
        return $rc
    fi
    log_ok "Подключение '$name' повторно авторизовано"
}
