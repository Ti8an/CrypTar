#!/usr/bin/env bash
[[ -n "${_SRV_REMOVE_LOADED:-}" ]] && return 0
_SRV_REMOVE_LOADED=1

srv_remove() {
    # [FIX 4] Use shared helper from dispatch.sh (always sourced first)
    local -a valid=()
    _srv_get_valid_names valid

    if [[ ${#valid[@]} -eq 0 ]]; then
        log_info "Серверов нет. Добавьте первый: crypTar --server add"
        return 0
    fi

    local name
    name="$(ui_select "Выберите сервер для удаления" "${valid[@]}")"

    # [FIX] Single decrypt + AWK instead of cfg_get for host (which triggered a full GPG
    # decrypt for one field). Also reads user and port so the prompt gives more context.
    local tmp
    tmp="$(cfg_decrypt)" || return 1
    trap '_cfg_shred "$tmp"; trap - EXIT INT TERM' EXIT INT TERM

    local host="" user="" port=""
    while IFS= read -r line; do
        k="${line%%=*}"
        v="${line#*=}"
        case "$k" in
            host) host="$v" ;;
            user) user="$v" ;;
            port) port="$v" ;;
        esac
    done < <(awk -v section="[$name]" '
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
    ' "$tmp")

    _cfg_shred "$tmp"
    trap - EXIT INT TERM   # [FIX] disarm — plaintext is gone

    if ui_confirm "Удалить сервер '$name' (${user}@${host}:${port})?"; then
        cfg_remove_server "$name" && log_ok "Сервер '$name' удалён"
    else
        log_info "Отменено."
    fi
}
