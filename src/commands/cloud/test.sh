#!/usr/bin/env bash
[[ -n "${_CLOUD_TEST_LOADED:-}" ]] && return 0
_CLOUD_TEST_LOADED=1

# crypTar --cloud test [name|index|--all]
# Exit: 0 all OK; for a single connection — its CLOUD_E_* code;
# for several — 3 if some failed, 1 if all failed.
cloud_test() {
    if (( $# > 1 )); then
        log_err "Использование: crypTar --cloud test [имя|номер|--all]"
        return 1
    fi
    cloud_require_deps || return

    local -a targets=()
    local n
    case "${1:-}" in
        --all|all)
            cloud_cfg_names targets || return
            if [[ ${#targets[@]} -eq 0 ]]; then
                log_info "Облачных подключений нет. Добавьте: crypTar --cloud add"
                return 0
            fi
            ;;
        "")
            local -a names=()
            cloud_cfg_names names || return
            if [[ ${#names[@]} -eq 0 ]]; then
                log_info "Облачных подключений нет. Добавьте: crypTar --cloud add"
                return 0
            fi
            local picked
            picked="$(cloud_pick 1 "Какие подключения проверить")" || { log_info "Отменено."; return 0; }
            while IFS= read -r n; do
                [[ -n "$n" ]] && targets+=("$n")
            done <<< "$picked"
            ;;
        *)
            n="$(cloud_resolve "$1")" || return
            targets=("$n")
            ;;
    esac

    local -A conn=()
    local rc ok=0 fail=0 last_rc=0
    local -a summary=()
    for n in "${targets[@]}"; do
        rc=0
        CLOUD_CTX_NAME="$n"
        ui_separator
        if cloud_cfg_load "$n" conn; then
            log_step "[$n] Проверка $(cloud_provider_label "${conn[provider]}")..."
            cloud_provider_call "${conn[provider]}" test conn || rc=$?
        else
            rc=$CLOUD_E_CONFIG
        fi
        conn=()
        if (( rc == 0 )); then
            ok=$((ok + 1)); summary+=("$(printf '  %-24s OK' "$n")")
        else
            fail=$((fail + 1)); last_rc=$rc
            summary+=("$(printf '  %-24s ОШИБКА: %s' "$n" "$(cloud_error_text "$rc")")")
        fi
    done
    CLOUD_CTX_NAME=""
    ui_separator
    log_info "📊 Результаты проверки:"
    printf '%s\n' "${summary[@]}"

    if (( fail == 0 )); then return 0; fi
    if (( ${#targets[@]} == 1 )); then return "$last_rc"; fi
    if (( ok > 0 )); then return $CLOUD_EXIT_PARTIAL; fi
    return 1
}
