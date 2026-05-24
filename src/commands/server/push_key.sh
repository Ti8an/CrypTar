#!/usr/bin/env bash
[[ -n "${_SRV_PUSH_KEY_LOADED:-}" ]] && return 0
_SRV_PUSH_KEY_LOADED=1

# Load cfg_* globals for a saved server so ssh_exec can use them.
# For password auth, the password global is set here and must be cleared
# with _srv_unload_creds as soon as the ssh operation completes.
#
# [FIX 3] Single cfg_decrypt + one AWK pass instead of 4-5 separate cfg_get calls.
_srv_load_creds() {
    local name="$1"

    local tmp
    tmp="$(cfg_decrypt)" || return 1

    local raw_fields
    raw_fields="$(awk -v section="[$name]" '
        /^[[:space:]]*([#;]|$)/ { next }
        {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        }
        /^\[/ { if (in_sec) exit; in_sec = (line == section); next }
        in_sec && /=/ {
            eq = index(line, "=")
            k  = substr(line, 1, eq - 1)
            v  = substr(line, eq + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print k"="v
        }
    ' "$tmp")"
    _cfg_shred "$tmp"   # [FIX 3] plaintext gone immediately after parse

    # Parse key=value lines from AWK output into individual variables
    local _host="" _port="" _user="" _auth_type="" _key_path="" _password=""
    local line k v
    while IFS= read -r line; do
        k="${line%%=*}"
        v="${line#*=}"
        case "$k" in
            host)        _host="$v"      ;;
            port)        _port="$v"      ;;
            user)        _user="$v"      ;;
            auth_type)   _auth_type="$v" ;;
            key_path)    _key_path="$v"  ;;
            password)    _password="$v"  ;;
        esac
    done <<< "$raw_fields"
    unset raw_fields

    declare -g "cfg_${name}_host=$_host"
    declare -g "cfg_${name}_port=$_port"
    declare -g "cfg_${name}_user=$_user"
    declare -g "cfg_${name}_auth_type=$_auth_type"

    if [[ "$_auth_type" == "key" ]]; then
        declare -g "cfg_${name}_key_path=$_key_path"
    else
        # Password auth: global is cleared by _srv_unload_creds after the ssh operation.
        declare -g "cfg_${name}_password=$_password"
        unset _password
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
        # [FIX 4] Use shared helper from dispatch.sh (always sourced first)
        local -a valid=()
        _srv_get_valid_names valid

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
    # [FIX 3] _srv_load_creds now does a single decrypt; cfg_${server}_host/user
    # are set as globals, so we read them from globals below instead of calling cfg_get again.
    _srv_load_creds "$server" || return 1

    # [FIX 1] Trap clears credential globals on unexpected exit (signal or error).
    trap "_srv_unload_creds '$server'; trap - EXIT INT TERM" EXIT INT TERM

    # [FIX 3] Read host/user from globals set by _srv_load_creds — no extra cfg_get calls.
    local host_var="cfg_${server}_host"
    local user_var="cfg_${server}_user"
    local host="${!host_var}"
    local user="${!user_var}"

    log_step "Отправляем '$key_uid' → ${user}@${host}..."

    # gpg writes the armoured public key to stdout; ssh forwards it as stdin
    # for the remote `gpg --import`. sshpass (password auth) handles the SSH
    # handshake via a pty and does not consume the data pipe.
    if gpg --export --armor "$key_id" | ssh_exec "$server" "gpg --import"; then
        _srv_unload_creds "$server"
        trap - EXIT INT TERM   # [FIX 1] disarm — success path
        log_ok "Ключ '$key_uid' успешно импортирован на сервере '$server'"
    else
        _srv_unload_creds "$server"
        trap - EXIT INT TERM   # [FIX 1] disarm — failure path
        log_err "Не удалось отправить ключ на сервер '$server'"
        return 1
    fi
}
