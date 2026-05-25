#!/usr/bin/env bash
[[ -n "${_CREDS_LOADED:-}" ]] && return 0
_CREDS_LOADED=1

# Shared credential loader used by transfer.sh (trn_send) and push_key.sh
# (srv_push_key). Extracted from the duplicate _trn_load_creds / _srv_load_creds
# that previously lived in each file. AWK single-decrypt pattern preserved exactly.
#
# _creds_load populates cfg_${name}_* globals for ssh_exec / scp_send / rsync.
# Caller must register a trap to call _creds_unload on unexpected exit.

_creds_load() {
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

    local _host="" _port="" _user="" _auth_type="" _key_path="" _password="" _remote_path=""
    local line k v
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            host)        _host="$v"        ;;
            port)        _port="$v"        ;;
            user)        _user="$v"        ;;
            auth_type)   _auth_type="$v"   ;;
            key_path)    _key_path="$v"    ;;
            password)    _password="$v"    ;;
            remote_path) _remote_path="$v" ;;
        esac
    done <<< "$raw_fields"
    unset raw_fields

    declare -g "cfg_${name}_host=$_host"
    declare -g "cfg_${name}_port=$_port"
    declare -g "cfg_${name}_user=$_user"
    declare -g "cfg_${name}_auth_type=$_auth_type"
    declare -g "cfg_${name}_remote_path=$_remote_path"
    if [[ "$_auth_type" == "key" ]]; then
        declare -g "cfg_${name}_key_path=$_key_path"
    else
        # Password auth: global is cleared by _creds_unload after the ssh operation.
        declare -g "cfg_${name}_password=$_password"
        unset _password
    fi
}

_creds_unload() {
    local name="$1"
    unset "cfg_${name}_host"        "cfg_${name}_port"        "cfg_${name}_user" \
          "cfg_${name}_auth_type"   "cfg_${name}_key_path"    "cfg_${name}_password" \
          "cfg_${name}_remote_path"
}
