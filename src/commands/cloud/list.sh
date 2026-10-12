#!/usr/bin/env bash
[[ -n "${_CLOUD_LIST_LOADED:-}" ]] && return 0
_CLOUD_LIST_LOADED=1

# Short status label for a connection-check result code.
_cloud_status_label() {
    case "$1" in
        0)                   echo "OK" ;;
        "$CLOUD_E_AUTH")     echo "AUTH ERROR" ;;
        "$CLOUD_E_PERM")     echo "NO ACCESS" ;;
        "$CLOUD_E_NET")      echo "NETWORK ERROR" ;;
        "$CLOUD_E_RATE")     echo "RATE LIMITED" ;;
        "$CLOUD_E_QUOTA")    echo "QUOTA FULL" ;;
        "$CLOUD_E_CONFIG")   echo "CONFIG ERROR" ;;
        *)                   echo "ERROR" ;;
    esac
}

# crypTar --cloud list [--check]
# Without --check the status column says "configured" — nothing was verified.
cloud_list() {
    local check=0 arg
    for arg in "$@"; do
        case "$arg" in
            --check|-c) check=1 ;;
            *) log_err "Неизвестный аргумент: '$arg'. Использование: crypTar --cloud list [--check]"; return 1 ;;
        esac
    done

    local tbl
    tbl="$(cloud_cfg_table)" || return
    if [[ -z "$tbl" ]]; then
        log_info "Облачных подключений нет. Добавьте: crypTar --cloud add"
        return 0
    fi
    if (( check )); then
        cloud_require_deps || return
    fi

    local -r W="3 20 13 30 18 14"
    ui_separator
    # shellcheck disable=SC2086
    ui_table $W -- "ID" "Имя" "Провайдер" "Аккаунт" "Папка" "Статус"
    ui_separator

    local i=1 name provider account folder status rc
    local -A conn=()
    while IFS=$'\t' read -r name provider account folder; do
        [[ -n "$name" ]] || continue
        status="configured"
        if (( check )); then
            rc=0
            CLOUD_CTX_NAME="$name"
            if cloud_cfg_load "$name" conn 2>/dev/null; then
                cloud_provider_call "$provider" test conn </dev/null >/dev/null 2>&1 || rc=$?
            else
                rc=$CLOUD_E_CONFIG
            fi
            conn=()
            status="$(_cloud_status_label "$rc")"
        fi
        # shellcheck disable=SC2086
        ui_table $W -- "$i" "$name" "$(cloud_provider_label "$provider")" "${account:--}" "${folder:--}" "$status"
        i=$((i + 1))
    done <<< "$tbl"
    ui_separator
    if (( ! check )); then
        log_info "«configured» — настроено, связь не проверялась. Проверка: crypTar --cloud list --check"
    fi
    return 0
}
