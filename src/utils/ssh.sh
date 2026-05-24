#!/usr/bin/env bash
[[ -n "${_SSH_LOADED:-}" ]] && return 0
_SSH_LOADED=1

# ssh_build_opts <server_id>
# Reads cfg_<server_id>_{host,port,user,auth_type,key_path} globals.
# Echoes an ssh options string suitable for eval or array expansion.
# auth_type: "password" → prepends sshpass -p <pass> (cfg_*_password must exist)
#            "key"      → adds -i <key_path>
ssh_build_opts() {
    local id="$1"
    local port_var="cfg_${id}_port"
    local key_var="cfg_${id}_key_path"
    local auth_var="cfg_${id}_auth_type"
    local port="${!port_var:-22}"
    local auth="${!auth_var:-key}"
    local opts="-p $port -o StrictHostKeyChecking=no -o ConnectTimeout=10"

    if [[ "$auth" == "key" ]]; then
        local key="${!key_var}"
        opts+=" -i $key"
    fi

    echo "$opts"
}

# ssh_exec <server_id> <command>
# Runs <command> on the remote host described by cfg_<server_id>_* vars.
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
    local opts
    opts="$(ssh_build_opts "$id")"

    if [[ "$auth" == "password" ]]; then
        local pass="${!pass_var}"
        # shellcheck disable=SC2086
        sshpass -p "$pass" ssh $opts "${user}@${host}" "$cmd"
    else
        # shellcheck disable=SC2086
        ssh $opts "${user}@${host}" "$cmd"
    fi
}

# ssh_test_conn <server_id>
# Returns 0 if connection succeeds, 1 otherwise.
ssh_test_conn() {
    local id="$1"
    ssh_exec "$id" "echo ok" &>/dev/null
}

# scp_send <server_id> <local_path> <remote_path>
scp_send() {
    local id="$1"
    local local_path="$2"
    local remote_path="$3"
    local host_var="cfg_${id}_host"
    local user_var="cfg_${id}_user"
    local port_var="cfg_${id}_port"
    local auth_var="cfg_${id}_auth_type"
    local pass_var="cfg_${id}_password"
    local key_var="cfg_${id}_key_path"
    local host="${!host_var}"
    local user="${!user_var}"
    local port="${!port_var:-22}"
    local auth="${!auth_var:-key}"
    local opts="-P $port -o StrictHostKeyChecking=no -o ConnectTimeout=10"

    if [[ "$auth" == "password" ]]; then
        local pass="${!pass_var}"
        # shellcheck disable=SC2086
        sshpass -p "$pass" scp $opts "$local_path" "${user}@${host}:${remote_path}"
    else
        local key="${!key_var}"
        # shellcheck disable=SC2086
        scp $opts -i "$key" "$local_path" "${user}@${host}:${remote_path}"
    fi
}
