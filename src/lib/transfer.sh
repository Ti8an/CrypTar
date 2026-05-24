#!/usr/bin/env bash
[[ -n "${_TRANSFER_LOADED:-}" ]] && return 0
_TRANSFER_LOADED=1

# ── Credential helpers ────────────────────────────────────────────────────────
# Duplicates the pattern from push_key.sh/_srv_load_creds to keep transfer.sh
# self-contained: it is sourced via lib/*.sh auto-loading, independently of the
# --server dispatch path that would make push_key.sh's version available.

_trn_load_creds() {
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
    _cfg_shred "$tmp"

    local _host="" _port="" _user="" _auth_type="" _key_path="" _password=""
    local line k v
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            host)      _host="$v"      ;;
            port)      _port="$v"      ;;
            user)      _user="$v"      ;;
            auth_type) _auth_type="$v" ;;
            key_path)  _key_path="$v"  ;;
            password)  _password="$v"  ;;
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
        declare -g "cfg_${name}_password=$_password"
        unset _password
    fi
}

_trn_unload_creds() {
    local name="$1"
    unset "cfg_${name}_host"      "cfg_${name}_port"     "cfg_${name}_user" \
          "cfg_${name}_auth_type" "cfg_${name}_key_path" "cfg_${name}_password"
}

# ── Transfer primitives ───────────────────────────────────────────────────────

# Returns 0 only when both local and remote sides have rsync in PATH.
trn_has_rsync() {
    local server="$1"
    command -v rsync &>/dev/null || return 1
    ssh_exec "$server" "command -v rsync" &>/dev/null
}

# Creates the remote directory (and any parents) via ssh_exec.
# $path is intentionally unquoted in the remote command so the remote shell
# expands a leading ~ to the remote user's home directory.
trn_mkdir_remote() {
    local server="$1" path="$2"
    ssh_exec "$server" "mkdir -p $path"
}

# Thin wrapper around scp_send (ssh.sh) — handles password auth transparently.
trn_via_scp() {
    local server="$1" local_file="$2" remote_path="$3"
    scp_send "$server" "$local_file" "${remote_path}/"
}

# rsync transfer, using the same ssh options as ssh_exec (port, key, timeouts).
# For password auth: SSHPASS + sshpass -e forwarded into rsync's -e string.
trn_via_rsync() {
    local id="$1" local_file="$2" remote_path="$3"
    local host_var="cfg_${id}_host" user_var="cfg_${id}_user"
    local auth_var="cfg_${id}_auth_type" pass_var="cfg_${id}_password"
    local host="${!host_var}" user="${!user_var}"
    local auth="${!auth_var:-key}"

    if [[ -z "$host" || -z "$user" ]]; then
        log_err "trn_via_rsync: host/user не заданы для сервера '$id'"
        return 1
    fi

    # ssh_build_opts() outputs the option array as a space-separated string;
    # suitable for embedding in rsync's -e "ssh ..." command string.
    local opts
    opts="$(ssh_build_opts "$id")"

    if [[ "$auth" == "password" ]]; then
        local pass="${!pass_var}"
        # sshpass -e reads the password from SSHPASS — never visible in ps aux.
        SSHPASS="$pass" rsync --progress -e "sshpass -e ssh $opts" \
            "$local_file" "${user}@${host}:${remote_path}/"
    else
        rsync --progress -e "ssh $opts" \
            "$local_file" "${user}@${host}:${remote_path}/"
    fi
}

# ── Orchestrator ──────────────────────────────────────────────────────────────

# Send a local file to a saved server.
# Loads credentials, creates the remote directory, picks rsync or scp,
# then unloads credentials regardless of outcome.
trn_send() {
    local server="$1" local_file="$2"

    _trn_load_creds "$server" || return 1
    trap "_trn_unload_creds '$server'; trap - EXIT INT TERM" EXIT INT TERM

    local remote_path
    remote_path="$(cfg_get "$server" remote_path)"
    remote_path="${remote_path:-~/backups}"

    log_step "[$server] Создаём удалённую директорию: $remote_path"
    if ! trn_mkdir_remote "$server" "$remote_path"; then
        log_err "[$server] Не удалось создать директорию на сервере"
        _trn_unload_creds "$server"
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

    _trn_unload_creds "$server"
    trap - EXIT INT TERM
    return $rc
}
