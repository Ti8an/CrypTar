#!/bin/bash

# === CrypTar - архиватор с шифрованием через GPG ===

show_help() {
    echo
    echo "🧱 CrypTar — архиватор с шифрованием через GPG"
    echo
    echo "Использование:"
    echo "  crypTar <путь_к_файлу_или_папке>    - архивировать и зашифровать"
    echo "  crypTar -d <файл.gpg>                - расшифровать и распаковать"
    echo
    echo "Примеры:"
    echo "  crypTar /home/user/Documents"
    echo "  crypTar -d Documents_20251015_153012.tar.gz.gpg"
    echo
}

# === Проверка аргументов ===
if [ $# -eq 0 ]; then
    show_help
    exit 1
fi

# === Режим расшифровки ===
if [ "$1" == "-d" ]; then
    if [ -z "$2" ]; then
        echo "❌ Укажите файл для расшифровки!"
        echo "👉 crypTar -d file.tar.gz.gpg"
        exit 1
    fi

    ENCRYPTED_FILE="$2"

    if [ ! -f "$ENCRYPTED_FILE" ]; then
        echo "❌ Файл не найден: $ENCRYPTED_FILE"
        exit 1
    fi

    echo "🔓 Расшифровываем $ENCRYPTED_FILE..."
    DECRYPTED_FILE="${ENCRYPTED_FILE%.gpg}"

    gpg -d "$ENCRYPTED_FILE" > "$DECRYPTED_FILE"
    if [ $? -ne 0 ]; then
        echo "❌ Ошибка при расшифровке!"
        rm -f "$DECRYPTED_FILE"
        exit 1
    fi

    echo "📦 Распаковываем архив..."
    tar -xzf "$DECRYPTED_FILE"
    if [ $? -ne 0 ]; then
        echo "❌ Ошибка при распаковке архива!"
        exit 1
    fi

    rm -f "$DECRYPTED_FILE"
    echo "✅ Успешно расшифровано и распаковано!"
    exit 0
fi

# === Режим шифрования ===
TARGET="$1"

if [ ! -e "$TARGET" ]; then
    echo "❌ Ошибка: указанный путь не существует: $TARGET"
    exit 1
fi

BASENAME=$(basename "$TARGET")
ARCHIVE="${BASENAME}_$(date +%Y%m%d_%H%M%S).tar.gz"
ENCRYPTED="${ARCHIVE}.gpg"

echo "📦 Архивируем: $TARGET → $ARCHIVE"
tar -czf "$ARCHIVE" -C "$(dirname "$TARGET")" "$BASENAME"
if [ $? -ne 0 ]; then
    echo "❌ Ошибка при архивации!"
    exit 1
fi

echo "🔐 Шифруем архив (введите пароль GPG)..."
gpg --symmetric --cipher-algo AES256 "$ARCHIVE"
if [ $? -ne 0 ]; then
    echo "❌ Ошибка при шифровании!"
    rm -f "$ARCHIVE"
    exit 1
fi

rm -f "$ARCHIVE"
echo "✅ Готово! Создан файл: $ENCRYPTED"
