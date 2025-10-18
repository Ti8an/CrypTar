#!/bin/bash
set -e

# Проверка аргумента
if [ -z "$1" ]; then
    echo "❌ Ошибка: не задан путь для архивации."
    echo "Использование: crypTar /путь/к/папке_или_файлу"
    exit 1
fi

TARGET="$1"
ARCHIVE="$(basename "$TARGET")_$(date +%Y%m%d_%H%M%S).tar.gz"

# Создаём архив
tar -czf "$ARCHIVE" "$TARGET"
echo "📦 Архив $ARCHIVE создан."

# Получаем список публичных ключей
KEYS=$(gpg --list-keys --with-colons | grep '^pub' | awk -F: '{print $5 " <" $10 ">"}')

# Если ключей нет — ошибка (создавать ключ здесь **не нужно**)
if [ -z "$KEYS" ]; then
    echo "❌ Ошибка: публичные GPG-ключи не найдены. Создайте их через install.sh"
    rm -f "$ARCHIVE"
    exit 1
fi

# Выводим список ключей
echo "🔑 Найдены следующие ключи GPG:"
echo "$KEYS"

# Выбор ключа пользователем
echo
read -p "Введите email ключа, которым хотите зашифровать архив: " RECIPIENT

# Проверка наличия выбранного ключа
if ! echo "$KEYS" | grep -q "$RECIPIENT"; then
    echo "❌ Ошибка: ключ с таким email не найден."
    rm -f "$ARCHIVE"
    exit 1
fi

# Шифруем архив выбранным ключом
gpg --encrypt --recipient "$RECIPIENT" "$ARCHIVE"
rm -f "$ARCHIVE"

echo "✅ Архив зашифрован ключом $RECIPIENT."
