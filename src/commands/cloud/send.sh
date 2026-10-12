#!/usr/bin/env bash
[[ -n "${_CLOUD_SEND_LOADED:-}" ]] && return 0
_CLOUD_SEND_LOADED=1

# Input classification for `--cloud send <path>`:
#   * regular file named *.gpg whose header is an OpenPGP encrypted message
#     → uploaded as-is (never re-encrypted);
#   * regular file named *.gpg WITHOUT such a header → rejected (ambiguous);
#   * any other regular file or directory → archived + encrypted with the
#     same code path as `crypTar <path>` / `crypTar -s <path>`, then uploaded.

_cloud_send_usage() {
    log_err "Использование: crypTar --cloud send [--to имя[,имя...]] <файл.tar.gz.gpg | файл | каталог>"
}

# Keep or delete the artifact produced by archive+encrypt, following the
# `crypTar -s` convention. The archive is only offered for deletion when
# every upload succeeded; otherwise it is always kept in the current dir.
_cloud_send_retain() {
    local gpg_file="$1" rc="$2" work_dir dest
    work_dir="$(dirname -- "$gpg_file")"
    [[ -f "$gpg_file" ]] || { rm -rf -- "$work_dir" 2>/dev/null || true; return 0; }

    if (( rc == 0 )) && ui_confirm "Удалить локальную копию '$(basename -- "$gpg_file")'?"; then
        rm -rf -- "$work_dir"
        log_ok "Локальная копия удалена"
        return 0
    fi
    dest="./${gpg_file##*/}"
    if mv -- "$gpg_file" "$dest" 2>/dev/null; then
        rmdir -- "$work_dir" 2>/dev/null || true
        log_info "Файл сохранён: $dest"
    else
        log_warn "Не удалось переместить архив — он оставлен здесь: $gpg_file"
    fi
    (( rc == 0 )) || log_info "Локальный архив сохранён, т.к. не все загрузки завершились успешно"
    return 0
}

cloud_send() {
    local -a to_raw=() parts=()
    local input="" t
    while (( $# )); do
        case "$1" in
            --to)
                [[ -n "${2:-}" ]] || { log_err "--to требует список имён подключений"; _cloud_send_usage; return 1; }
                IFS=',' read -r -a parts <<< "$2"; to_raw+=("${parts[@]}"); shift 2 ;;
            --to=*)
                [[ -n "${1#--to=}" ]] || { log_err "--to требует список имён подключений"; _cloud_send_usage; return 1; }
                IFS=',' read -r -a parts <<< "${1#--to=}"; to_raw+=("${parts[@]}"); shift ;;
            --)
                shift
                (( $# == 1 )) && [[ -z "$input" ]] || { _cloud_send_usage; return 1; }
                input="$1"; shift ;;
            -*)
                log_err "Неизвестный параметр: '$1'"; _cloud_send_usage; return 1 ;;
            *)
                [[ -z "$input" ]] || { log_err "Укажите ровно один путь"; _cloud_send_usage; return 1; }
                input="$1"; shift ;;
        esac
    done
    [[ -n "$input" ]] || { _cloud_send_usage; return 1; }

    # ── Validate the input before any network or crypto work ──────────────────
    if [[ ! -e "$input" ]]; then
        log_err "Путь не существует: $input"; return 1
    fi
    if [[ ! -r "$input" ]]; then
        log_err "Нет прав на чтение: $input"; return 1
    fi
    local mode
    if [[ -f "$input" && "$input" == *.gpg ]]; then
        if ! cloud_is_encrypted_archive "$input"; then
            log_err "Файл '$input' имеет расширение .gpg, но не является зашифрованным OpenPGP-сообщением."
            log_info "Переименуйте файл, если его нужно архивировать и зашифровать."
            return 1
        fi
        mode="upload"
    elif [[ -f "$input" || -d "$input" ]]; then
        mode="encrypt"
    else
        log_err "Неподдерживаемый тип файла (не обычный файл и не каталог): $input"; return 1
    fi

    cloud_require_deps || return

    # ── Resolve destinations (all names checked before anything starts) ───────
    local -a all=() dests=() unknown=()
    cloud_cfg_names all || return
    if [[ ${#all[@]} -eq 0 ]]; then
        log_err "Облачные подключения не настроены. Добавьте: crypTar --cloud add"
        return 1
    fi
    if [[ ${#to_raw[@]} -gt 0 ]]; then
        local -A seen=()
        local found n
        for t in "${to_raw[@]}"; do
            t="$(_cloud_trim "$t")"
            [[ -n "$t" ]] || continue
            found=""
            for n in "${all[@]}"; do
                [[ "$n" == "$t" ]] && { found="$n"; break; }
            done
            if [[ -z "$found" ]]; then
                unknown+=("$t")
            elif [[ -z "${seen[$found]:-}" ]]; then
                seen[$found]=1; dests+=("$found")
            fi
        done
        if [[ ${#unknown[@]} -gt 0 ]]; then
            log_err "Неизвестные подключения: ${unknown[*]} — загрузка не начата."
            log_info "Доступные: ${all[*]}"
            return 1
        fi
        [[ ${#dests[@]} -gt 0 ]] || { log_err "Список --to пуст"; return 1; }
    else
        local picked
        picked="$(cloud_pick 1 "Куда загрузить")" || { log_info "Отправка отменена."; return 0; }
        while IFS= read -r t; do
            [[ -n "$t" ]] && dests+=("$t")
        done <<< "$picked"
    fi

    # ── Upload ────────────────────────────────────────────────────────────────
    local rc=0
    if [[ "$mode" == upload ]]; then
        log_info "Загружаем существующий зашифрованный архив: $input"
        cloud_upload_many "$input" "${dests[@]}" || rc=$?
        return $rc
    fi

    local _f="$SRC_DIR/commands/encrypt.sh"
    [[ -f "$_f" ]] || { log_err "Не найден файл: $_f"; return 1; }
    source "$_f"

    log_info "Шаг 1: Архивирование и шифрование"
    local gpg_file=""
    cmd_archive_and_encrypt "$input" gpg_file || return 1
    log_ok "Зашифрованный файл: $(basename -- "$gpg_file")"

    # On Ctrl-C during the upload, keep the encrypted archive (moved to the
    # current directory) instead of leaving it in a temp dir.
    local qgpg
    printf -v qgpg '%q' "$gpg_file"
    trap "trap - EXIT INT TERM; mv -- $qgpg ./ 2>/dev/null && echo 'Архив сохранён: ./${gpg_file##*/}' >&2; exit 130" INT TERM

    log_info "Шаг 2: Загрузка в облако"
    cloud_upload_many "$gpg_file" "${dests[@]}" || rc=$?
    trap - INT TERM

    _cloud_send_retain "$gpg_file" "$rc"
    return $rc
}
