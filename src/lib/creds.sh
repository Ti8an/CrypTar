#!/usr/bin/env bash
[[ -n "${_CREDS_LOADED:-}" ]] && return 0
_CREDS_LOADED=1

# Shared credential loader used by transfer.sh (trn_send) and push_key.sh
# (srv_push_key). Extracted from the duplicate _trn_load_creds / _srv_load_creds
# that previously lived in each file. AWK single-decrypt pattern preserved exactly.
#
# _creds_load populates cfg_${name}_* globals for ssh_exec / scp_send / rsync.
# Caller must register a trap to call _creds_unload on unexpected exit.

# [FIX HIGH] Validates that $name is a legal Bash identifier for use in
# cfg_${name}_* variable names. Stricter than srv_validate_name which permits
# hyphens — hyphens are illegal in Bash variable names.
_validate_cfg_name() {
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

# NOT reentrant — NOT concurrency-safe.
# cfg_${name}_* globals are shared across the process. Parallel calls to
# _creds_load or _creds_unload for the same server name will corrupt each
# other's state. This is acceptable for a single-user interactive CLI.
# Do not use in background jobs or subshells that share the parent's globals.
_creds_load() {
    local name="$1"
    # [FIX HIGH] Reject names that would produce invalid Bash identifiers.
    _validate_cfg_name "$name" || { log_err "_creds_load: invalid config name: '$name'"; return 1; }

    local tmp
    tmp="$(cfg_decrypt)" || return 1
    # [FIX MEDIUM] RETURN trap ensures _cfg_shred runs on every exit path,
    # including set -e abort or signal delivery during the AWK call.
    # Single-quoted so $tmp expands at fire-time (when the local is still live).
    trap '_cfg_shred "$tmp"; trap - RETURN' RETURN

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
    # (explicit _cfg_shred removed — the RETURN trap above covers all paths)

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

    # [FIX HIGH] Use declare -g (no value) + printf -v instead of declare -g "var=$value".
    # declare -g "var=$value" is parsed by Bash assignment semantics and is fragile
    # when values contain newlines, leading dashes, or shell metacharacters.
    # printf -v assigns without any parsing ambiguity.
    declare -g "cfg_${name}_host";        printf -v "cfg_${name}_host"        '%s' "$_host"
    declare -g "cfg_${name}_port";        printf -v "cfg_${name}_port"        '%s' "$_port"
    declare -g "cfg_${name}_user";        printf -v "cfg_${name}_user"        '%s' "$_user"
    declare -g "cfg_${name}_auth_type";   printf -v "cfg_${name}_auth_type"   '%s' "$_auth_type"
    declare -g "cfg_${name}_remote_path"; printf -v "cfg_${name}_remote_path" '%s' "$_remote_path"
    if [[ "$_auth_type" == "key" ]]; then
        declare -g "cfg_${name}_key_path"; printf -v "cfg_${name}_key_path" '%s' "$_key_path"
    else
        # Password auth: global is cleared by _creds_unload after the ssh operation.
        declare -g "cfg_${name}_password"; printf -v "cfg_${name}_password" '%s' "$_password"
        unset _password
    fi
}

# NOT reentrant — NOT concurrency-safe.
# cfg_${name}_* globals are shared across the process. Parallel calls to
# _creds_load or _creds_unload for the same server name will corrupt each
# other's state. This is acceptable for a single-user interactive CLI.
# Do not use in background jobs or subshells that share the parent's globals.
_creds_unload() {
    local name="$1"
    # [FIX HIGH] Same identifier guard as _creds_load — printf -v requires a
    # valid Bash identifier; an invalid name would silently corrupt state.
    _validate_cfg_name "$name" || { log_err "_creds_unload: invalid config name: '$name'"; return 1; }
    # [FIX LOW] Overwrite before unset: operational hygiene only.
    # Bash does not guarantee memory zeroing; the value may persist in heap.
    printf -v "cfg_${name}_password" '%s' ''
    unset "cfg_${name}_host"        "cfg_${name}_port"        "cfg_${name}_user" \
          "cfg_${name}_auth_type"   "cfg_${name}_key_path"    "cfg_${name}_password" \
          "cfg_${name}_remote_path"
}
