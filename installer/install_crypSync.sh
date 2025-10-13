#!/usr/bin/env bash
set -e

SRC_SCRIPT="./crypsync/main.py"
DEST_DIR="$HOME/.local/bin"
DEST_SCRIPT="$DEST_DIR/crypSync"
CONFIG_FILE="$HOME/.crypSync_config.json"

# Проверка зависимостей
for prog in python3 gpg rclone tar gzip; do
    if ! command -v $prog &>/dev/null; then
        echo "❌ Не найден $prog"
    fi
done

# Копируем скрипт
mkdir -p "$DEST_DIR"
cp "$SRC_SCRIPT" "$DEST_SCRIPT"
chmod +x "$DEST_SCRIPT"

# Создаём конфиг
if [ ! -f "$CONFIG_FILE" ]; then
    read -p "Введите папку для хранения зашифрованных архивов: " folder_to_store
    read -p "Введите API-токен Яндекс.Диска: " token
    cat > "$CONFIG_FILE" <<EOL
{
    "folder_to_store": "$folder_to_store",
    "yandex_api_token": "$token"
}
EOL
    chmod 600 "$CONFIG_FILE"
    echo "✅ Конфигурация сохранена в $CONFIG_FILE"
fi

echo "✅ CrypSync установлен! Используйте команду: crypSync /путь/к/папке"
