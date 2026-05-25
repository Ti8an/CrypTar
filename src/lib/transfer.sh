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
    # [FIX HIGH] Shell-escape path for safe remote execution.
    # ~ at the start is intentionally left unescaped so the remote shell
    # expands it to the remote user's home directory.
    local qpath
    if [[ "$path" == "~"* ]]; then
        local suffix="${path:1}"
        local qsuffix
        printf -v qsuffix '%q' "$suffix"
        ssh_exec "$server" "mkdir -p ~${qsuffix}"
    else
        printf -v qpath '%q' "$path"
        ssh_exec "$server" "mkdir -p $qpath"
    fi
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

    local -a ssh_opts=(-p "$port" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
    [[ "$auth" == "key" ]] && ssh_opts+=(-i "$key")
    # [FIX LOW] printf '%q' each element so metacharacters in values (e.g. backslashes
    # or quotes in key paths) don't break rsync's -e command string.
    local opts_str
    printf -v opts_str '%q ' "${ssh_opts[@]}"
    opts_str="${opts_str% }"   # trim trailing space

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

    # [FIX MEDIUM] Local cleanup function avoids trap string interpolation which
    # breaks if $server contains a single quote. server is captured from the
    # enclosing scope; the trap fires while trn_send's stack frame is still active.
    _trn_cleanup() {
        _creds_unload "$server"
        trap - EXIT INT TERM
    }
    trap _trn_cleanup EXIT INT TERM

    # [FIX MEDIUM] ~/backups is intentionally left as a literal string here.
    # Tilde is NOT expanded inside ${var:-...} parameter expansion.
    # The remote shell will expand ~ when mkdir receives the path.
    local rp_var="cfg_${server}_remote_path"
    local remote_path="${!rp_var}"
    [[ -z "$remote_path" ]] && remote_path='~/backups'

    log_step "[$server] Создаём удалённую директорию: $remote_path"
    if ! trn_mkdir_remote "$server" "$remote_path"; then
        log_err "[$server] Не удалось создать директорию на сервере"
        _trn_cleanup
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

    _trn_cleanup
    return $rc
}
