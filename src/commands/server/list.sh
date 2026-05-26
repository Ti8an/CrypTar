#!/usr/bin/env bash
[[ -n "${_SRV_LIST_LOADED:-}" ]] && return 0
_SRV_LIST_LOADED=1

srv_list() {
    # [FIX 4] Use shared helper from dispatch.sh (always sourced first)
    local -a valid=()
    _srv_get_valid_names valid

    if [[ ${#valid[@]} -eq 0 ]]; then
        log_info "Серверов не добавлено. Используйте: crypTar --server add"
        return 0
    fi

    # [FIX 2] Single decrypt + one AWK pass instead of 5×N cfg_get calls.
    # AWK emits one tab-separated line per server in valid[]: name host user port auth desc.
    # Servers not in valid[] are skipped; missing fields become empty strings.
    local tmp=""
    tmp="$(cfg_decrypt)" || return 1
    trap '_cfg_shred "$tmp"; trap - EXIT INT TERM' EXIT INT TERM

    local names_arg
    names_arg="${valid[*]}"   # space-separated list for AWK

    local -a rows=()
    while IFS=$'\t' read -r srv_name host user port auth desc; do
        rows+=("$srv_name"$'\t'"$host"$'\t'"$user"$'\t'"$port"$'\t'"$auth"$'\t'"$desc")
    done < <(awk -v names="$names_arg" '
        BEGIN {
            n = split(names, arr, " ")
            for (i = 1; i <= n; i++) want[arr[i]] = i
            cur = ""; order_max = 0
        }
        /^[[:space:]]*([#;]|$)/ { next }
        {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        }
        /^\[/ {
            if (cur in want)
                out[want[cur]] = cur"\t"f["host"]"\t"f["user"]"\t"f["port"]"\t"f["auth_type"]"\t"f["description"]
            gsub(/^\[|\]$/, "", line); cur = line
            for (k in f) delete f[k]
            next
        }
        cur in want && /=/ {
            eq = index(line, "=")
            k  = substr(line, 1, eq - 1)
            v  = substr(line, eq + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            f[k] = v
        }
        END {
            if (cur in want)
                out[want[cur]] = cur"\t"f["host"]"\t"f["user"]"\t"f["port"]"\t"f["auth_type"]"\t"f["description"]
            for (i = 1; i <= n; i++) if (i in out) print out[i]
        }
    ' "$tmp")

    _cfg_shred "$tmp"
    trap - EXIT INT TERM   # [FIX 2] disarm after plaintext is gone

    # Column widths: index, name, user@host:port, auth, description
    local -r W="3 20 30 10 25"

    ui_separator
    # shellcheck disable=SC2086
    ui_table $W -- "#" "Имя" "Подключение" "Авторизация" "Описание"
    ui_separator

    local i=0
    local srv_name host user port auth desc
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r srv_name host user port auth desc <<< "$row"
        # shellcheck disable=SC2086
        ui_table $W -- "$i" "$srv_name" "${user}@${host}:${port}" "$auth" "${desc:--}"
        (( i++ )) || true
    done
    ui_separator
}
