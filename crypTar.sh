#!/bin/bash

# === CrypTar - архиватор с шифрованием через GPG ===

# Проверяем, передан ли аргумент
if [ -z "$1" ]; then
    echo "❌ Ошибка: не указана папка или файл для архивации."
    echo "👉 Использование: crypTar /путь/к/папке_или_файлу"
    exit 1
fi

TARGET="$1"

# Проверяем существование
if [ ! -e "$TARGET" ]; then
    echo "❌ Ошибка: указанный путь не существует: $TARGET"
    exit 1
fi

# Определяем имя архива
BASENAME=$(basename "$TARGET")
ARCHIVE="${BASENAME}_$(date +%Y%m%d_%H%M%S).tar.gz"
ENCRYPTED="${ARCHIVE}.gpg"

echo "📦 Архивируем: $TARGET → $ARCHIVE"
tar -czf "$ARCHIVE" -C "$(dirname "$TARGET")" "$BASENAME"

if [ $? -ne 0 ]; then
    echo "❌ Ошибка при архивации!"
    exit 1
fi

# Шифрование
echo "🔐 Шифруем архив..."
gpg --symmetric --cipher-algo AES256 "$ARCHIVE"

if [ $? -ne 0 ]; then
    echo "❌ Ошибка при шифровании!"
    rm -f "$ARCHIVE"
    exit 1
fi

# Удаляем оригинальный архив
rm -f "$ARCHIVE"

echo "✅ Готово! Результат: $ENCRYPTED"
