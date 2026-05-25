#!/usr/bin/env bash
[[ -n "${_TRANSFER_LOADED:-}" ]] && return 0
_TRANSFER_LOADED=1

# [FIX HIGH] _trn_load_creds / _trn_unload_creds removed — replaced by the shared
# _creds_load / _creds_unload defined in src/lib/creds.sh, which is auto-loaded
# by the main crypTar script alongside this file.

trn_has_rsync() {
    local server="$1"
    command -v rsync &>/dev/null || return 1
    ssh_exec "$server" "command -v rsync" &>/dev/null
}

trn_mkdir_remote() {
    local server="$1" path="$2"
    # $path is intentionally unquoted in the remote command so the remote shell
    # expands a leading ~ to the remote user's home directory.
    # [FIX MEDIUM] Double-quote $path in the remote command to prevent word
    # splitting when $path contains spaces.
    ssh_exec "$server" "mkdir -p \"$path\""
}

trn_via_scp() {
    local server="$1" local_file="$2" remote_path="$3"
    scp_send "$server" "$local_file" "${remote_path}/"
}

trn_via_rsync() {
    local id="$1" local_file="$2" remote_path="$3"
    local host_var="cfg_${id}_host"  user_var="cfg_${id}_user"
    local auth_var="cfg_${id}_auth_type" pass_var="cfg_${id}_password"
    local port_var="cfg_${id}_port"  key_var="cfg_${id}_key_path"
    local host="${!host_var}" user="${!user_var}"
    local auth="${!auth_var:-key}"
    local port="${!port_var:-22}" key="${!key_var}"

    if [[ -z "$host" || -z "$user" ]]; then
        log_err "trn_via_rsync: host/user не заданы для сервера '$id'"
        return 1
    fi

    # [FIX MEDIUM] Build ssh options as a proper array so a key path containing
    # spaces is handled correctly; collapse to a string only for rsync's -e flag,
    # which requires a single command string (not an array).
    local -a ssh_opts=(-p "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
    [[ "$auth" == "key" ]] && ssh_opts+=(-i "$key")
    local opts_str="${ssh_opts[*]}"

    if [[ "$auth" == "password" ]]; then
        local pass="${!pass_var}"
        # SSHPASS + -e: password comes from env var, never appears in `ps aux`.
        SSHPASS="$pass" rsync --progress -e "sshpass -e ssh $opts_str" \
            "$local_file" "${user}@${host}:${remote_path}/"
    else
        rsync --progress -e "ssh $opts_str" \
            "$local_file" "${user}@${host}:${remote_path}/"
    fi
}

trn_send() {
    local server="$1" local_file="$2"

    # [FIX HIGH] _creds_load replaces the removed _trn_load_creds.
    _creds_load "$server" || return 1
    trap "_creds_unload '$server'; trap - EXIT INT TERM" EXIT INT TERM

    # [FIX HIGH] remote_path is now populated by _creds_load — no extra cfg_get decrypt.
    # The ${:-~/backups} default expands ~ at assignment time, yielding an absolute path.
    local rp_var="cfg_${server}_remote_path"
    local remote_path="${!rp_var:-~/backups}"

    log_step "[$server] Создаём удалённую директорию: $remote_path"
    if ! trn_mkdir_remote "$server" "$remote_path"; then
        log_err "[$server] Не удалось создать директорию на сервере"
        _creds_unload "$server"
        trap - EXIT INT TERM
        return 1
    fi

    local rc=0
    if trn_has_rsync "$server"; then
        log_step "[$server] Отправляем через rsync: $(basename "$local_file")"
        trn_via_rsync "$server" "$local_file" "$remote_path" || rc=$?
    else
        log_step "[$server] Отправляем через scp: $(basename "$local_file")"
        trn_via_scp "$server" "$local_file" "$remote_path" || rc=$?
    fi

    _creds_unload "$server"
    trap - EXIT INT TERM
    return $rc
}
