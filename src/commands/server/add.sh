#!/usr/bin/env bash
[[ -n "${_SRV_ADD_LOADED:-}" ]] && return 0
_SRV_ADD_LOADED=1

# ── Validation helpers (each testable in isolation) ───────────────────────────

srv_validate_name() {
    local name="$1"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]
}

srv_validate_key_path() {
    local path="$1"
    [[ -f "$path" && -r "$path" ]]
}

# ── Temporary credential globals for pre-save connection test ─────────────────
# ssh_exec reads cfg_<id>_* globals. These helpers set/clear them without
# touching the encrypted config. Requires bash 4.2+ for declare -g.

_srv_set_tmp_creds() {
    local name="$1" host="$2" port="$3" user="$4" auth_type="$5"
    local key_path="${6:-}" password="${7:-}"
    declare -g "cfg_${name}_host=$host"
    declare -g "cfg_${name}_port=$port"
    declare -g "cfg_${name}_user=$user"
    declare -g "cfg_${name}_auth_type=$auth_type"
    # Only set the auth-specific field that ssh_exec will actually read
    [[ "$auth_type" == "key"      && -n "$key_path" ]] && declare -g "cfg_${name}_key_path=$key_path"
    [[ "$auth_type" == "password" && -n "$password" ]] && declare -g "cfg_${name}_password=$password"
}

_srv_unset_tmp_creds() {
    local name="$1"
    unset "cfg_${name}_host"      "cfg_${name}_port"     "cfg_${name}_user" \
          "cfg_${name}_auth_type" "cfg_${name}_key_path" "cfg_${name}_password"
}

# ── Wizard ────────────────────────────────────────────────────────────────────

srv_add() {
    log_info "Добавление нового сервера"
    ui_separator

    # Step 1: server name — loop until valid and unique (or overwrite confirmed)
    local name
    while true; do
        name="$(ui_prompt "Имя сервера (буквы, цифры, _ -)")"
        if ! srv_validate_name "$name"; then
            log_err "Недопустимое имя — разрешены только: a-z A-Z 0-9 _ -"
            continue
        fi
        if cfg_server_exists "$name"; then
            if ui_confirm "Сервер '$name' уже существует. Перезаписать?"; then
                cfg_remove_server "$name" || return 1
            else
                continue   # ask for a different name
            fi
        fi
        break
    done

    # Step 2: connection details
    local host port user description
    host="$(ui_prompt "Хост / IP")"
    port="$(ui_prompt "SSH порт" "22")"
    user="$(ui_prompt "Имя пользователя")"
    description="$(ui_prompt "Описание (необязательно)")"

    # Step 3: auth type
    local auth_type
    auth_type="$(ui_select "Тип аутентификации" "password" "key")"

    local password="" key_path=""

    if [[ "$auth_type" == "password" ]]; then
        # Collect password twice and verify they match
        while true; do
            local p1 p2
            p1="$(ui_secret "Пароль")"
            p2="$(ui_secret "Повторите пароль")"
            if [[ "$p1" == "$p2" ]]; then
                password="$p1"
                unset p1 p2
                break
            fi
            log_err "Пароли не совпадают — попробуйте снова"
            unset p1 p2
        done
    else
        # Key path — loop until the file exists and is readable
        while true; do
            key_path="$(ui_prompt "Путь к приватному SSH-ключу")"
            srv_validate_key_path "$key_path" && break
            log_err "Файл не найден или недоступен: $key_path"
        done
    fi

    # Step 4: optional GPG key association
    local gpg_key_id=""
    local -a gpg_keys=()
    IFS=$'\n' read -r -d '' -a gpg_keys < <(cfg_list_gpg_keys && printf '\0')

    if [[ ${#gpg_keys[@]} -gt 0 && -n "${gpg_keys[0]}" ]]; then
        if ui_confirm "Связать GPG-ключ шифрования с этим сервером?"; then
            local sel_gpg
            sel_gpg="$(ui_select "Выберите GPG-ключ" "${gpg_keys[@]}")"
            gpg_key_id="${sel_gpg%% : *}"   # take KEY_ID from "KEY_ID : UID"
        fi
    fi

    # Step 5: connection test
    # Set globals so ssh_exec can find credentials without a config entry.
    # [FIX 1] Trap clears credential globals and password local on unexpected exit
    # (signal, error, or subshell exit) so secrets are never left in global scope.
    _srv_set_tmp_creds "$name" "$host" "$port" "$user" "$auth_type" "$key_path" "$password"
    trap "_srv_unset_tmp_creds '$name'; unset password; trap - EXIT INT TERM" EXIT INT TERM

    log_step "Проверяем подключение к ${user}@${host}:${port}..."
    local conn_ok=0
    ssh_test_conn "$name" && conn_ok=1

    _srv_unset_tmp_creds "$name"
    trap - EXIT INT TERM   # [FIX 1] disarm — normal path handled above

    if [[ "$conn_ok" -eq 0 ]]; then
        log_warn "Не удалось подключиться."
        if ! ui_confirm "Сохранить сервер несмотря на ошибку подключения?"; then
            log_info "Отменено."
            unset password
            return 0
        fi
    else
        log_ok "Подключение успешно"
    fi

    # Step 6: save — cfg_add_server also calls unset password internally;
    # we call it here too as belt-and-suspenders for the local variable.
    cfg_add_server "$name" "$host" "$port" "$user" "$auth_type" \
                   "$password" "$key_path" "$gpg_key_id" "$description"
    local rc=$?
    unset password
    [[ $rc -eq 0 ]] && log_ok "Сервер '$name' сохранён"
    return $rc
}
