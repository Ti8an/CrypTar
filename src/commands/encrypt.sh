#!/usr/bin/env bash
[[ -n "${_ENCRYPT_LOADED:-}" ]] && return 0
_ENCRYPT_LOADED=1

cmd_help() {
    local prog
    prog="$(basename "$0")"
    cat <<EOF
${prog} — архивирование и шифрование через GPG (только асимметрично).

Использование:
  ${prog} <путь_к_файлу_или_папке>   — архивировать и зашифровать
  ${prog} -d <файл.tar.gz.gpg>       — расшифровать и распаковать
  ${prog} -h | --help                — показать это сообщение

Примеры:
  ${prog} /home/user/Documents
  ${prog} -d Documents_20_10_2025_23_16_01.tar.gz.gpg

Примечания:
  * Скрипт использует только асимметричное шифрование (GPG public keys).
  * Если публичных ключей нет — CrypTar завершит работу.
EOF
}

# Archive a path to .tar.gz then GPG-encrypt it to .tar.gz.gpg.
# On success, sets the nameref $2 to the full path of the .gpg file and returns 0.
# The caller owns the file and its parent work_dir; caller must move or delete them.
# The intermediate .tar.gz is always removed (success or failure).
cmd_archive_and_encrypt() {
    local target="$1"
    local -n _gpg_out="$2"

    if [[ ! -e "$target" ]]; then
        log_err "Путь не существует: $target"
        return 1
    fi

    local -a KEYS=()
    IFS=$'\n' read -r -d '' -a KEYS < <(cfg_list_gpg_keys && printf '\0')

    if [[ ${#KEYS[@]} -eq 0 ]]; then
        log_err "Публичные GPG-ключи не найдены. Создайте ключи через install.sh и повторите."
        return 1
    fi

    local sel_gpg
    sel_gpg="$(ui_select "Выберите GPG-ключ для шифрования" "${KEYS[@]}")"
    local key_id="${sel_gpg%% : *}"
    local key_uid="${sel_gpg#* : }"

    # [FIX LOW] Use a temp working directory instead of $PWD so the function
    # works correctly on read-only or shared working directories, and intermediate
    # files are isolated from the user's directory.
    local work_dir
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cryptar_XXXXXX")"
    # Trap handles INT/TERM signals; explicit rm -rf on each failure path handles
    # normal returns (EXIT trap does not fire on function return, only on process exit).
    trap 'rm -rf "$work_dir"; trap - EXIT INT TERM' EXIT INT TERM

    local DATE_TAG ARCHIVE ENCRYPTED_FILE
    DATE_TAG="$(date +%d_%m_%Y_%H_%M_%S)"
    ARCHIVE="$work_dir/$(basename "$target")_${DATE_TAG}.tar.gz"
    ENCRYPTED_FILE="${ARCHIVE}.gpg"

    log_step "Архивируем $target → $(basename "$ARCHIVE")"
    if ! tar -czf "$ARCHIVE" -C "$(dirname "$target")" "$(basename "$target")"; then
        rm -rf "$work_dir"
        trap - EXIT INT TERM
        log_err "Ошибка при архивировании."
        return 1
    fi

    log_step "Шифруем $(basename "$ARCHIVE") ключом: $key_uid"
    # [FIX LOW] --output places the encrypted file inside work_dir explicitly,
    # avoiding reliance on GPG's default output-path behavior across versions.
    if gpg --yes --encrypt --recipient "$key_id" --output "$ENCRYPTED_FILE" "$ARCHIVE"; then
        rm -f "$ARCHIVE"
        trap - EXIT INT TERM   # disarm — caller takes ownership of work_dir
        _gpg_out="$ENCRYPTED_FILE"
        return 0
    else
        rm -rf "$work_dir"
        trap - EXIT INT TERM
        log_err "Ошибка при шифровании."
        return 1
    fi
}

cmd_encrypt() {
    if [[ $# -eq 0 ]]; then
        cmd_help
        exit 1
    fi

    local gpg_file
    cmd_archive_and_encrypt "$1" gpg_file || exit 1

    # [FIX LOW] Move the .gpg file from work_dir to the current directory so the
    # user finds it where they expect, then remove the now-empty work_dir.
    local dest="${gpg_file##*/}"
    if ! mv "$gpg_file" "./$dest"; then
        log_err "Не удалось переместить файл в текущую директорию."
        rm -rf "$(dirname "$gpg_file")"
        exit 1
    fi
    rmdir "$(dirname "$gpg_file")" 2>/dev/null || true
    log_ok "Готово: $dest"
}
