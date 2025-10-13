#!/usr/bin/env bash
set -e

# Пути
PROJECT_DIR="$(pwd)"
VENV_DIR="$PROJECT_DIR/venv"
SRC_SCRIPT="$PROJECT_DIR/crypsync/main.py"
DEST_DIR="$HOME/.local/bin"
DEST_SCRIPT="$DEST_DIR/crypSync"
CONFIG_FILE="$HOME/.crypSync_config.json"

# Проверка зависимостей
for prog in python3 gpg rclone tar gzip; do
    if ! command -v $prog &>/dev/null; then
        echo "❌ Не найден $prog"
        echo "Пожалуйста, установите его через apt"
        exit 1
    fi
done

# Создаём виртуальное окружение
if [ ! -d "$VENV_DIR" ]; then
    echo "Создаём виртуальное окружение..."
    python3 -m venv "$VENV_DIR"
fi

# Активируем venv и обновляем pip
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install -r "$PROJECT_DIR/requirements.txt"

# Копируем CLI
mkdir -p "$DEST_DIR"
cp "$SRC_SCRIPT" "$DEST_SCRIPT"
chmod +x "$DEST_SCRIPT"

# Создаём конфиг, если не существует
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

# Финальное сообщение
echo "✅ CrypSync успешно установлен!"
echo "CLI доступен командой: crypSync /путь/к/папке"
echo "Для работы внутри виртуального окружения:"
echo "  source $VENV_DIR/bin/activate"
echo "  python $SRC_SCRIPT /путь/к/папке"
