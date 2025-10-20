#!/bin/bash
set -euo pipefail

PROG_NAME="$(basename "$0")"

show_help() {
    cat <<EOF
${PROG_NAME} — архивирование и шифрование через GPG (только асимметрично).

Использование:
  ${PROG_NAME} <путь_к_файлу_или_папке>   — архивировать и зашифровать
  ${PROG_NAME} -d <файл.tar.gz.gpg>       — расшифровать и распаковать
  ${PROG_NAME} -h | --help                — показать это сообщение

Примеры:
  ${PROG_NAME} /home/user/Documents
  ${PROG_NAME} -d Documents_20_10_2025_23_16_01.tar.gz.gpg

Примечания:
  * Скрипт использует только асимметричное шифрование (GPG public keys).
  * Если публичных ключей нет — CrypTar завершит работу.
EOF
}

# --- Обработка аргументов ---
if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    -d)
        # === Расшифровка и распаковка ===
        if [ -z "${2-}" ]; then
            echo "❌ Укажите файл для расшифровки: ${PROG_NAME} -d <file.gpg>"
            exit 1
        fi
        ENC_FILE="$2"
        if [ ! -f "$ENC_FILE" ]; then
            echo "❌ Файл не найден: $ENC_FILE"
            exit 1
        fi

        echo "🔓 Расшифровываем и распаковываем $ENC_FILE..."
        TMP_TAR="$(mktemp --tmpdir "${PROG_NAME}.XXXXXX.tar.gz")"

        # Даем GPG самому выбрать секретный ключ
        if ! gpg -d "$ENC_FILE" > "$TMP_TAR"; then
            rm -f "$TMP_TAR"
            echo "❌ Ошибка при расшифровке. Проверьте наличие приватного ключа."
            exit 1
        fi

        echo "📦 Распаковываем архив..."
        if ! tar -xzf "$TMP_TAR"; then
            rm -f "$TMP_TAR"
            echo "❌ Ошибка при распаковке архива."
            exit 1
        fi

        rm -f "$TMP_TAR"
        echo "✅ Успешно расшифровано и распаковано."
        exit 0
        ;;
esac

# --- Шифрование ---
TARGET="$1"
if [ ! -e "$TARGET" ]; then
    echo "❌ Ошибка: указанный путь не существует: $TARGET"
    exit 1
fi

# Проверяем наличие публичных ключей
IFS=$'\n' read -r -d '' -a KEYS < <(gpg --list-keys --with-colons 2>/dev/null | awk -F: '
    /^pub/ { key=$5 }
    /^uid/ { uid=$10; print key " : " uid }
' && printf '\0')

if [ ${#KEYS[@]} -eq 0 ]; then
    echo "❌ Ошибка: публичные GPG-ключи не найдены. Создайте ключи через install.sh и повторите."
    exit 1
fi

# Выводим нумерованный список ключей
echo "🔑 Найдены публичные ключи GPG:"
for i in "${!KEYS[@]}"; do
    echo "[$i] ${KEYS[$i]}"
done

read -r -p "Введите номер ключа для шифрования (0..$(( ${#KEYS[@]} - 1 ))): " KEY_INDEX
if ! [[ "$KEY_INDEX" =~ ^[0-9]+$ ]] || [ "$KEY_INDEX" -lt 0 ] || [ "$KEY_INDEX" -ge "${#KEYS[@]}" ]; then
    echo "❌ Неверный выбор ключа."
    exit 1
fi

SELECTED_KEY_ID="$(printf '%s\n' "${KEYS[$KEY_INDEX]}" | awk -F' : ' '{print $1}')"
SELECTED_KEY_UID="$(printf '%s\n' "${KEYS[$KEY_INDEX]}" | awk -F' : ' '{print $2}')"

# --- Создаём архив с датой ---
DATE_TAG="$(date +%d_%m_%Y_%H_%M_%S)"
ARCHIVE="$(basename "$TARGET")_${DATE_TAG}.tar.gz"
echo "📦 Архивируем $TARGET → $ARCHIVE"
tar -czf "$ARCHIVE" -C "$(dirname "$TARGET")" "$(basename "$TARGET")"

# --- Шифруем ---
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

exit 0
