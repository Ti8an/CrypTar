#!/usr/bin/env bash
[[ -n "${_SEND_LOADED:-}" ]] && return 0
_SEND_LOADED=1

# Send the gpg_file to every configured server.
# Continues on per-server failure and prints a result table at the end.
# Returns 0 only if every server succeeded.
# dispatch.sh (which defines _srv_get_valid_names) is sourced by cmd_send
# before this function is ever called.
cmd_send_all() {
    local gpg_file="$1"

    # [FIX MEDIUM] Replace inline server-filtering boilerplate with shared helper.
    local -a valid=()
    _srv_get_valid_names valid

    local -a ok=() fail=()
    local n
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

    # [FIX LOW] Guard source calls with existence checks.
    local _f
    _f="$SRC_DIR/commands/encrypt.sh"
    [[ -f "$_f" ]] || { log_err "Не найден файл: $_f"; exit 1; }
    source "$_f"

    # [FIX MEDIUM] dispatch.sh defines _srv_get_valid_names used below and in
    # cmd_send_all. It is not auto-loaded for the -s path, so source it here.
    # [FIX LOW] Existence guard applied.
    _f="$SRC_DIR/commands/server/dispatch.sh"
    [[ -f "$_f" ]] || { log_err "Не найден файл: $_f"; exit 1; }
    source "$_f"

    # Step 1: archive and encrypt
    log_info "Шаг 1: Архивирование и шифрование"
    local gpg_file
    cmd_archive_and_encrypt "$TARGET" gpg_file || exit 1
    log_ok "Зашифрованный файл: $(basename "$gpg_file")"

    # Step 2: load server list
    # [FIX MEDIUM] Replace inline server-filtering boilerplate with shared helper.
    local -a valid=()
    _srv_get_valid_names valid

    if [[ ${#valid[@]} -eq 0 ]]; then
        log_warn "Серверов не настроено."
        log_info "Добавьте сервер командой: crypTar --server add"
        if ui_confirm "Открыть мастер добавления сервера?"; then
            # dispatch.sh already sourced above
            # [FIX LOW] Existence guard for add.sh.
            _f="$SRC_DIR/commands/server/add.sh"
            [[ -f "$_f" ]] || { log_err "Не найден файл: $_f"; exit 1; }
            source "$_f"
            srv_add || { log_err "Добавление сервера не удалось."; exit 1; }
            # [FIX MEDIUM] Reload after wizard using shared helper.
            valid=()
            _srv_get_valid_names valid
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
    local work_dir
    work_dir="$(dirname "$gpg_file")"
    if [[ -f "$gpg_file" ]]; then
        if ui_confirm "Удалить локальную копию '$(basename "$gpg_file")'?"; then
            rm -rf "$work_dir"
            log_ok "Локальная копия удалена"
        else
            # Move to current directory so the file is accessible after /tmp cleanup.
            local dest="./${gpg_file##*/}"
            mv "$gpg_file" "$dest" 2>/dev/null && log_info "Файл сохранён: $dest"
            rm -rf "$work_dir" 2>/dev/null || true
        fi
    else
        rm -rf "$work_dir" 2>/dev/null || true
    fi

    exit $send_rc
}
