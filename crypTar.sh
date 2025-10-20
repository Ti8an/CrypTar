#!/bin/bash
set -euo pipefail

PROG_NAME="$(basename "$0")"

show_help() {
    cat <<EOF
${PROG_NAME} — архивирование и шифрование через GPG (только асимметрично).

Использование:
  ${PROG_NAME} <путь_к_файлу_или_папке>   — архивировать и зашифровать (выбор ключа)
  ${PROG_NAME} -d <файл.tar.gz.gpg>       — расшифровать и распаковать
  ${PROG_NAME} -h | --help                — показать это сообщение

Примеры:
  ${PROG_NAME} /home/user/Documents
  ${PROG_NAME} -d Documents_20251019_022919.tar.gz.gpg

Примечания:
  * Скрипт использует только асимметричное шифрование (GPG public keys).
  * Если публичных ключей нет — скрипт завершится с ошибкой (ключи нужно создать заранее через install.sh).
EOF
}

# Параметры: поддержка -h/--help и -d <file>
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
        # Режим расшифровки
        if [ -z "${2-}" ]; then
            echo "❌ Укажите файл для расшифровки: ${PROG_NAME} -d <file.gpg>"
            exit 1
        fi
        ENC_FILE="$2"
        if [ ! -f "$ENC_FILE" ]; then
            echo "❌ Файл не найден: $ENC_FILE"
            exit 1
        fi

        echo "🔓 Проверяем возможность расшифровки $ENC_FILE..."

        # Получаем keyid всех получателей в файле
        keyids=$(gpg --list-packets "$ENC_FILE" 2>/dev/null | awk -F'=' '/keyid:/ {gsub(/ /,"",$2); print $2}')

        if [ -z "$keyids" ]; then
            echo "❌ Не удалось определить recipient keyid из файла."
            exit 1
        fi

        # Получаем локальные секретные ключи
        mapfile -t mysec < <(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec/ {print $5}')

        have_any=0
        for kid in $keyids; do
            for sk in "${mysec[@]}"; do
                if [[ "${sk^^}" == *"${kid^^}"* ]]; then
                    echo "✅ Найден секретный ключ для keyid $kid (локальный: $sk)"
                    have_any=1
                fi
            done
        done

        if [ "$have_any" -eq 0 ]; then
            echo "❌ У вас нет секретного ключа, соответствующего recipient key(s) файла. Расшифровка невозможна."
            exit 2
        fi

        echo "🔓 Расшифровываем $ENC_FILE..."
        TMP_TAR="$(mktemp --tmpdir "${PROG_NAME}.XXXXXX.tar.gz")"
        if ! gpg -d "$ENC_FILE" > "$TMP_TAR"; then
            rm -f "$TMP_TAR"
            echo "❌ Ошибка при расшифровке."
            exit 1
        fi
        echo "📦 Распаковываем..."
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

# Режим шифрования: аргумент — путь к файлу или папке
TARGET="$1"

if [ ! -e "$TARGET" ]; then
    echo "❌ Ошибка: указанный путь не существует: $TARGET"
    exit 1
fi

# Проверяем наличие публичных ключей
# Построим список: pubkeyid : uid (email или описание)
IFS=$'\n' read -r -d '' -a KEYS < <(gpg --list-keys --with-colons 2>/dev/null | awk -F: '
    /^pub/ { key=$5 }
    /^uid/ { uid=$10; print key " : " uid }
' && printf '\0')

if [ ${#KEYS[@]} -eq 0 ]; then
    echo "❌ Ошибка: публичные GPG-ключи не найдены. Создайте ключи (например, через install.sh) и повторите."
    exit 1
fi

# Выводим нумерованный список ключей
echo "🔑 Найдены публичные ключи GPG:"
for i in "${!KEYS[@]}"; do
    echo "[$i] ${KEYS[$i]}"
done

# Запрос выбора по порядковому номеру
echo
read -r -p "Введите номер ключа для шифрования (0..$(( ${#KEYS[@]} - 1 ))): " KEY_INDEX

# Валидация ввода
if ! [[ "$KEY_INDEX" =~ ^[0-9]+$ ]]; then
    echo "❌ Ошибка: введите целое неотрицательное число."
    exit 1
fi
if [ "$KEY_INDEX" -lt 0 ] || [ "$KEY_INDEX" -ge "${#KEYS[@]}" ]; then
    echo "❌ Ошибка: номер вне диапазона."
    exit 1
fi

# Получаем идентификатор ключа (первое поле до ' : ')
SELECTED_KEY_ID="$(printf '%s\n' "${KEYS[$KEY_INDEX]}" | awk -F' : ' '{print $1}')"
SELECTED_KEY_UID="$(printf '%s\n' "${KEYS[$KEY_INDEX]}" | awk -F' : ' '{print $2}')"

# Формируем имя архива и создаём его (создаём только если ключ выбран)
ARCHIVE="$(basename "$TARGET")_$(date +%Y%m%d_%H%M%S).tar.gz"
echo "📦 Архивируем $TARGET → $ARCHIVE"
if ! tar -czf "$ARCHIVE" -C "$(dirname "$TARGET")" "$(basename "$TARGET")"; then
    echo "❌ Ошибка при архивации."
    rm -f "$ARCHIVE"
    exit 1
fi

# Шифруем архив выбранным публичным ключом
echo "🔐 Шифруем $ARCHIVE ключом: $SELECTED_KEY_UID (id: $SELECTED_KEY_ID)"
if ! gpg --yes --encrypt --recipient "$SELECTED_KEY_ID" "$ARCHIVE"; then
    echo "❌ Ошибка при шифровании."
    rm -f "$ARCHIVE"
    exit 1
fi

# Удаляем исходный арх и выводим имя зашифрованного файла
rm -f "$ARCHIVE"
ENCRYPTED_FILE="${ARCHIVE}.gpg"
echo "✅ Готово: $ENCRYPTED_FILE (шифровано ключом: $SELECTED_KEY_UID)"
exit 0
