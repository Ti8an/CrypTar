#!/usr/bin/env bash

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
        echo "❌ Ошибка: указанный путь не существует: $TARGET"
        exit 1
    fi

    local -a KEYS
    IFS=$'\n' read -r -d '' -a KEYS < <(gpg --list-keys --with-colons 2>/dev/null | awk -F: '
        /^pub/ { key=$5 }
        /^uid/ { uid=$10; print key " : " uid }
    ' && printf '\0')

    if [ ${#KEYS[@]} -eq 0 ]; then
        echo "❌ Ошибка: публичные GPG-ключи не найдены. Создайте ключи через install.sh и повторите."
        exit 1
    fi

    echo "🔑 Найдены публичные ключи GPG:"
    for i in "${!KEYS[@]}"; do
        echo "[$i] ${KEYS[$i]}"
    done

    local KEY_INDEX
    read -r -p "Введите номер ключа для шифрования (0..$(( ${#KEYS[@]} - 1 ))): " KEY_INDEX
    if ! [[ "$KEY_INDEX" =~ ^[0-9]+$ ]] || [ "$KEY_INDEX" -lt 0 ] || [ "$KEY_INDEX" -ge "${#KEYS[@]}" ]; then
        echo "❌ Неверный выбор ключа."
        exit 1
    fi

    local SELECTED_KEY_ID SELECTED_KEY_UID
    SELECTED_KEY_ID="$(printf '%s\n' "${KEYS[$KEY_INDEX]}" | awk -F' : ' '{print $1}')"
    SELECTED_KEY_UID="$(printf '%s\n' "${KEYS[$KEY_INDEX]}" | awk -F' : ' '{print $2}')"

    local DATE_TAG ARCHIVE ENCRYPTED_FILE
    DATE_TAG="$(date +%d_%m_%Y_%H_%M_%S)"
    ARCHIVE="$(basename "$TARGET")_${DATE_TAG}.tar.gz"
    echo "📦 Архивируем $TARGET → $ARCHIVE"
    tar -czf "$ARCHIVE" -C "$(dirname "$TARGET")" "$(basename "$TARGET")"

    ENCRYPTED_FILE="${ARCHIVE}.gpg"
    echo "🔐 Шифруем $ARCHIVE ключом: $SELECTED_KEY_UID"
    if gpg --yes --encrypt --recipient "$SELECTED_KEY_ID" "$ARCHIVE"; then
        rm -f "$ARCHIVE"
        echo "✅ Готово: $ENCRYPTED_FILE (шифровано ключом: $SELECTED_KEY_UID)"
    else
        rm -f "$ARCHIVE"
        echo "❌ Ошибка при шифровании."
        exit 1
    fi
}
