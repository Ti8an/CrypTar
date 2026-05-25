#!/usr/bin/env bash
[[ -n "${_SRV_PUSH_KEY_LOADED:-}" ]] && return 0
_SRV_PUSH_KEY_LOADED=1

# [FIX HIGH] _srv_load_creds / _srv_unload_creds removed — replaced by the shared
# _creds_load / _creds_unload defined in src/lib/creds.sh, which is auto-loaded
# by the main crypTar script.

srv_push_key() {
    local server="${1:-}"

    # Step 1: select server if not supplied as argument
    if [[ -z "$server" ]]; then
        local -a valid=()
        _srv_get_valid_names valid

        if [[ ${#valid[@]} -eq 0 ]]; then
            log_info "Серверов нет. Добавьте первый: crypTar --server add"
            return 0
        fi

        server="$(ui_select "Выберите сервер" "${valid[@]}")"
        # [FIX MEDIUM] Guard against ui_select returning empty (user cancelled).
        [[ -n "$server" ]] || { log_info "Отменено."; return 0; }
    fi

    # Step 2: select GPG key to push
    local -a gpg_keys=()
    IFS=$'\n' read -r -d '' -a gpg_keys < <(cfg_list_gpg_keys && printf '\0')

    if [[ ${#gpg_keys[@]} -eq 0 || -z "${gpg_keys[0]}" ]]; then
        log_err "Публичные GPG-ключи не найдены"
        return 1
    fi

    local sel_gpg
    sel_gpg="$(ui_select "Выберите GPG-ключ для отправки" "${gpg_keys[@]}")"
    # [FIX MEDIUM] Guard against ui_select returning empty (user cancelled).
    [[ -n "$sel_gpg" ]] || { log_info "Отменено."; return 0; }
    local key_id="${sel_gpg%% : *}"     # everything before " : "
    local key_uid="${sel_gpg#* : }"    # everything after  " : "

    # Step 3: load creds and push
    # [FIX HIGH] _creds_load replaces the removed _srv_load_creds. Single decrypt;
    # cfg_${server}_host/user are set as globals, read from them below.
    _creds_load "$server" || return 1

    # [FIX HIGH] Capture server into a local so the single-quoted trap string
    # expands $cleanup_server at fire-time; avoids the global function that is
    # overwritten on nested calls and breaks on names containing single quotes.
    local cleanup_server="$server"
    trap '_creds_unload "$cleanup_server"; trap - EXIT INT TERM' EXIT INT TERM

    local host_var="cfg_${server}_host"
    local user_var="cfg_${server}_user"
    local host="${!host_var}"
    local user="${!user_var}"

    log_step "Отправляем '$key_uid' → ${user}@${host}..."

    # gpg writes the armoured public key to stdout; ssh forwards it as stdin
    # for the remote `gpg --import`. sshpass (password auth) handles the SSH
    # handshake via a pty and does not consume the data pipe.
    if gpg --export --armor "$key_id" | ssh_exec "$server" "gpg --import"; then
        _creds_unload "$cleanup_server"; trap - EXIT INT TERM
        log_ok "Ключ '$key_uid' успешно импортирован на сервере '$server'"
    else
        _creds_unload "$cleanup_server"; trap - EXIT INT TERM
        log_err "Не удалось отправить ключ на сервер '$server'"
        return 1
    fi
}
