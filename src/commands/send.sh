#!/usr/bin/env bash
[[ -n "${_SEND_LOADED:-}" ]] && return 0
_SEND_LOADED=1

# Send the gpg_file to every configured server.
# Continues on per-server failure and prints a result table at the end.
# Returns 0 only if every server succeeded.
cmd_send_all() {
    local gpg_file="$1"

    local -a servers=()
    IFS=$'\n' read -r -d '' -a servers < <(cfg_list_servers && printf '\0')
    local -a valid=()
    local n
    for n in "${servers[@]}"; do
        [[ -n "$n" ]] && valid+=("$n")
    done

    local -a ok=() fail=()
    for n in "${valid[@]}"; do
        if trn_send "$n" "$gpg_file"; then
            ok+=("$n")
        else
            fail+=("$n")
        fi
    done

    echo ""
    log_info "📊 Результаты отправки:"
    for n in "${ok[@]}";   do printf "  %-24s ✅ OK\n"     "$n"; done
    for n in "${fail[@]}"; do printf "  %-24s ❌ Ошибка\n" "$n"; done

    [[ ${#fail[@]} -eq 0 ]]
}

cmd_send() {
    # $1 is "-s"; the path to archive is $2
    local TARGET="${2:-}"
    if [[ -z "$TARGET" ]]; then
        log_err "Укажите путь к файлу или папке: crypTar -s <путь>"
        exit 1
    fi
    if [[ ! -e "$TARGET" ]]; then
        log_err "Путь не существует: $TARGET"
        exit 1
    fi

    # encrypt.sh is sourced lazily — source it here so cmd_archive_and_encrypt
    # is available. The guard in encrypt.sh makes repeated sourcing a no-op.
    source "$SRC_DIR/commands/encrypt.sh"

    # Step 1: archive and encrypt
    log_info "Шаг 1: Архивирование и шифрование"
    local gpg_file
    cmd_archive_and_encrypt "$TARGET" gpg_file || exit 1
    log_ok "Зашифрованный файл: $gpg_file"

    # Step 2: load server list
    local -a servers=()
    IFS=$'\n' read -r -d '' -a servers < <(cfg_list_servers && printf '\0')
    local -a valid=()
    local n
    for n in "${servers[@]}"; do
        [[ -n "$n" ]] && valid+=("$n")
    done

    if [[ ${#valid[@]} -eq 0 ]]; then
        log_warn "Серверов не настроено."
        log_info "Добавьте сервер командой: crypTar --server add"
        if ui_confirm "Открыть мастер добавления сервера?"; then
            source "$SRC_DIR/commands/server/dispatch.sh"
            source "$SRC_DIR/commands/server/add.sh"
            srv_add || { log_err "Добавление сервера не удалось."; exit 1; }
            # Reload after wizard
            servers=(); valid=()
            IFS=$'\n' read -r -d '' -a servers < <(cfg_list_servers && printf '\0')
            for n in "${servers[@]}"; do [[ -n "$n" ]] && valid+=("$n"); done
            if [[ ${#valid[@]} -eq 0 ]]; then
                log_err "Сервер не добавлен — отправка отменена."
                exit 1
            fi
        else
            log_info "Отправка отменена."
            exit 0
        fi
    fi

    # Step 3: server selection — individual server or all
    local -a choices=("${valid[@]}" "allServers")
    local selection
    selection="$(ui_select "Выберите сервер для отправки" "${choices[@]}")"

    # Step 4: transfer
    local send_rc=0
    if [[ "$selection" == "allServers" ]]; then
        cmd_send_all "$gpg_file" || send_rc=$?
    else
        trn_send "$selection" "$gpg_file" || send_rc=$?
        if [[ $send_rc -eq 0 ]]; then
            log_ok "Файл отправлен на сервер '$selection'"
        else
            log_err "Не удалось отправить файл на сервер '$selection'"
        fi
    fi

    # Step 5: prompt to delete the local .gpg copy (always — user decides)
    if [[ -f "$gpg_file" ]]; then
        if ui_confirm "Удалить локальную копию '$gpg_file'?"; then
            rm -f "$gpg_file"
            log_ok "Локальная копия удалена"
        fi
    fi

    exit $send_rc
}
