#!/usr/bin/env bash
[[ -n "${_SSH_LOADED:-}" ]] && return 0
_SSH_LOADED=1

# Internal shared helper — populates the caller's array via nameref.
# Args: <server_id> <array_nameref> [port_flag]
#   port_flag defaults to "-p" (ssh); pass "-P" for scp.
_ssh_build_opts_array() {
    local id="$1"
    local -n _opts="$2"   # nameref: writes directly into the caller's local array
    local port_flag="${3:--p}"
    local port_var="cfg_${id}_port"
    local key_var="cfg_${id}_key_path"
    local auth_var="cfg_${id}_auth_type"
    local port="${!port_var:-22}"
    local auth="${!auth_var:-key}"

    # accept-new: auto-accepts unknown hosts but rejects changed keys (MITM protection).
    # Safer than =no, which silently accepts any key including a replaced one.
    _opts=(
        "$port_flag" "$port"
        "-o" "StrictHostKeyChecking=accept-new"
        "-o" "ConnectTimeout=10"
    )

    if [[ "$auth" == "key" ]]; then
        local key="${!key_var}"
        # Array elements stay quoted — paths with spaces won't split
        _opts+=("-i" "$key")
    fi
}

# Public wrapper preserved for callers that consume the options as a plain string.
ssh_build_opts() {
    local id="$1"
    local -a opts=()
    _ssh_build_opts_array "$id" opts
    echo "${opts[*]}"
}

ssh_exec() {
    local id="$1"
    local cmd="$2"
    local host_var="cfg_${id}_host"
    local user_var="cfg_${id}_user"
    local auth_var="cfg_${id}_auth_type"
    local pass_var="cfg_${id}_password"
    local host="${!host_var}"
    local user="${!user_var}"
    local auth="${!auth_var:-key}"

    # Fail loudly rather than attempting a connection with empty credentials
    if [[ -z "$host" || -z "$user" ]]; then
        echo "ssh_exec: missing host or user for server '$id'" >&2
        return 1
    fi

    local -a opts=()
    _ssh_build_opts_array "$id" opts   # "-p" port flag (default)

    if [[ "$auth" == "password" ]]; then
        local pass="${!pass_var}"
        # SSHPASS + -e: password comes from env var, never appears in `ps aux`
        SSHPASS="$pass" sshpass -e ssh "${opts[@]}" "${user}@${host}" "$cmd"
    else
        ssh "${opts[@]}" "${user}@${host}" "$cmd"
    fi
}

ssh_test_conn() {
    local id="$1"
    ssh_exec "$id" "echo ok" &>/dev/null
}

scp_send() {
    local id="$1"
    local local_path="$2"
    local remote_path="$3"
    local host_var="cfg_${id}_host"
    local user_var="cfg_${id}_user"
    local auth_var="cfg_${id}_auth_type"
    local pass_var="cfg_${id}_password"
    local host="${!host_var}"
    local user="${!user_var}"
    local auth="${!auth_var:-key}"

    # Fail loudly rather than attempting a transfer with empty credentials
    if [[ -z "$host" || -z "$user" ]]; then
        echo "scp_send: missing host or user for server '$id'" >&2
        return 1
    fi

    local -a opts=()
    # scp uses uppercase -P for port; pass it explicitly to the shared helper
    _ssh_build_opts_array "$id" opts "-P"

    if [[ "$auth" == "password" ]]; then
        local pass="${!pass_var}"
        # SSHPASS + -e: password comes from env var, never appears in `ps aux`
        SSHPASS="$pass" sshpass -e scp "${opts[@]}" "$local_path" "${user}@${host}:${remote_path}"
    else
        scp "${opts[@]}" "$local_path" "${user}@${host}:${remote_path}"
    fi
}
