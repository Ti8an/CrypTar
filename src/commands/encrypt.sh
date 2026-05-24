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

cmd_encrypt() {
    if [ $# -eq 0 ]; then
        cmd_help
        exit 1
    fi

    local TARGET="$1"
    if [ ! -e "$TARGET" ]; then
        log_err "Ошибка: указанный путь не существует: $TARGET"
        exit 1
    fi

    local -a KEYS
    IFS=$'\n' read -r -d '' -a KEYS < <(cfg_list_gpg_keys && printf '\0')

    if [ ${#KEYS[@]} -eq 0 ]; then
        log_err "Ошибка: публичные GPG-ключи не найдены. Создайте ключи через install.sh и повторите."
        exit 1
    fi

    log_info "Найдены публичные ключи GPG:"
    for i in "${!KEYS[@]}"; do
        echo "[$i] ${KEYS[$i]}"
    done

    local KEY_INDEX
    read -r -p "Введите номер ключа для шифрования (0..$(( ${#KEYS[@]} - 1 ))): " KEY_INDEX
    if ! [[ "$KEY_INDEX" =~ ^[0-9]+$ ]] || [ "$KEY_INDEX" -lt 0 ] || [ "$KEY_INDEX" -ge "${#KEYS[@]}" ]; then
        log_err "Неверный выбор ключа."
        exit 1
    fi

    local SELECTED_KEY_ID SELECTED_KEY_UID
    SELECTED_KEY_ID="$(printf '%s\n' "${KEYS[$KEY_INDEX]}" | awk -F' : ' '{print $1}')"
    SELECTED_KEY_UID="$(printf '%s\n' "${KEYS[$KEY_INDEX]}" | awk -F' : ' '{print $2}')"

    local DATE_TAG ARCHIVE ENCRYPTED_FILE
    DATE_TAG="$(date +%d_%m_%Y_%H_%M_%S)"
    ARCHIVE="$(basename "$TARGET")_${DATE_TAG}.tar.gz"
    log_step "Архивируем $TARGET → $ARCHIVE"
    tar -czf "$ARCHIVE" -C "$(dirname "$TARGET")" "$(basename "$TARGET")"

    ENCRYPTED_FILE="${ARCHIVE}.gpg"
    log_step "Шифруем $ARCHIVE ключом: $SELECTED_KEY_UID"
    if gpg --yes --encrypt --recipient "$SELECTED_KEY_ID" "$ARCHIVE"; then
        rm -f "$ARCHIVE"
        log_ok "Готово: $ENCRYPTED_FILE (шифровано ключом: $SELECTED_KEY_UID)"
    else
        rm -f "$ARCHIVE"
        log_err "Ошибка при шифровании."
        exit 1
    fi
}
