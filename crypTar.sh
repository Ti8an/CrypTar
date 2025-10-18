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

# Получаем список публичных ключей
mapfile -t KEYS < <(gpg --list-keys --with-colons | awk -F: '/^pub/{pub=$5} /^uid/{print pub " : " $10}' )

# Если ключей нет — ошибка и выходим
if [ ${#KEYS[@]} -eq 0 ]; then
    echo "❌ Ошибка: публичные GPG-ключи не найдены. Создайте их через install.sh"
    exit 1
fi

# Выводим список ключей с индексами
echo "🔑 Найдены следующие ключи GPG:"
for i in "${!KEYS[@]}"; do
    echo "[$i] ${KEYS[$i]}"
done

# Выбор ключа пользователем по номеру
echo
read -p "Введите номер ключа для шифрования: " KEY_INDEX

# Проверка валидности выбора
if ! [[ "$KEY_INDEX" =~ ^[0-9]+$ ]] || [ "$KEY_INDEX" -lt 0 ] || [ "$KEY_INDEX" -ge ${#KEYS[@]} ]; then
    echo "❌ Ошибка: выбран неверный номер ключа."
    exit 1
fi

SELECTED_KEY=$(echo "${KEYS[$KEY_INDEX]}" | awk -F ' : ' '{print $1}')

# Создаём архив
tar -czf "$ARCHIVE" "$TARGET"
echo "📦 Архив $ARCHIVE создан."

# Шифруем архив выбранным ключом
gpg --encrypt --recipient "$SELECTED_KEY" "$ARCHIVE"
rm -f "$ARCHIVE"

echo "✅ Архив зашифрован ключом: ${KEYS[$KEY_INDEX]}"
