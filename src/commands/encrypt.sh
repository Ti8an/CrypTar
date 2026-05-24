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
# On success, sets the nameref $2 to the .gpg filename and returns 0.
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

    local DATE_TAG ARCHIVE ENCRYPTED_FILE
    DATE_TAG="$(date +%d_%m_%Y_%H_%M_%S)"
    ARCHIVE="$(basename "$target")_${DATE_TAG}.tar.gz"
    ENCRYPTED_FILE="${ARCHIVE}.gpg"

    log_step "Архивируем $target → $ARCHIVE"
    if ! tar -czf "$ARCHIVE" -C "$(dirname "$target")" "$(basename "$target")"; then
        rm -f "$ARCHIVE"
        log_err "Ошибка при архивировании."
        return 1
    fi

    log_step "Шифруем $ARCHIVE ключом: $key_uid"
    if gpg --yes --encrypt --recipient "$key_id" "$ARCHIVE"; then
        rm -f "$ARCHIVE"
        _gpg_out="$ENCRYPTED_FILE"
        return 0
    else
        rm -f "$ARCHIVE"
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
    log_ok "Готово: $gpg_file"
}
