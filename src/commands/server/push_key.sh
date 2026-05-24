#!/usr/bin/env bash
[[ -n "${_SRV_PUSH_KEY_LOADED:-}" ]] && return 0
_SRV_PUSH_KEY_LOADED=1

# Load cfg_* globals for a saved server so ssh_exec can use them.
# For password auth, the password global is set here and must be cleared
# with _srv_unload_creds as soon as the ssh operation completes.
_srv_load_creds() {
    local name="$1"
    declare -g "cfg_${name}_host=$(cfg_get "$name" host)"
    declare -g "cfg_${name}_port=$(cfg_get "$name" port)"
    declare -g "cfg_${name}_user=$(cfg_get "$name" user)"
    declare -g "cfg_${name}_auth_type=$(cfg_get "$name" auth_type)"

    local auth_type
    auth_type="$(cfg_get "$name" auth_type)"
    if [[ "$auth_type" == "key" ]]; then
        declare -g "cfg_${name}_key_path=$(cfg_get "$name" key_path)"
    else
        # Password auth: read from config, set global, unset local immediately.
        # Global is cleared by _srv_unload_creds after the ssh operation.
        local _pass
        _pass="$(cfg_get "$name" password)"
        declare -g "cfg_${name}_password=$_pass"
        unset _pass
    fi
}

_srv_unload_creds() {
    local name="$1"
    unset "cfg_${name}_host"      "cfg_${name}_port"     "cfg_${name}_user" \
          "cfg_${name}_auth_type" "cfg_${name}_key_path" "cfg_${name}_password"
}

srv_push_key() {
    local server="${1:-}"

    # Step 1: select server if not supplied as argument
    if [[ -z "$server" ]]; then
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

        server="$(ui_select "Выберите сервер" "${valid[@]}")"
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
    local key_id="${sel_gpg%% : *}"     # everything before " : "
    local key_uid="${sel_gpg#* : }"    # everything after  " : "

    # Step 3: load creds and push
    # Subshells inherit all shell variables, so the cfg_* globals set here
    # are visible to ssh_exec even when it runs on the right side of a pipe.
    _srv_load_creds "$server"

    local host user
    host="$(cfg_get "$server" host)"
    user="$(cfg_get "$server" user)"

    log_step "Отправляем '$key_uid' → ${user}@${host}..."

    # gpg writes the armoured public key to stdout; ssh forwards it as stdin
    # for the remote `gpg --import`. sshpass (password auth) handles the SSH
    # handshake via a pty and does not consume the data pipe.
    if gpg --export --armor "$key_id" | ssh_exec "$server" "gpg --import"; then
        _srv_unload_creds "$server"
        log_ok "Ключ '$key_uid' успешно импортирован на сервере '$server'"
    else
        _srv_unload_creds "$server"
        log_err "Не удалось отправить ключ на сервер '$server'"
        return 1
    fi
}
