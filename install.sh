#!/bin/bash
set -e

echo "🚀 Установка CrypTar..."

# Проверка наличия необходимых утилит
for pkg in tar gpg; do
    if ! command -v $pkg &>/dev/null; then
        echo "⚙️ Устанавливаем $pkg..."
        sudo apt-get install -y $pkg
    else
        echo "✅ $pkg уже установлен."
    fi
done

# Путь установки
INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"

# Копируем основной скрипт
cp "$(dirname "$0")/crypTar.sh" "$INSTALL_DIR/crypTar"
chmod +x "$INSTALL_DIR/crypTar"

# Проверяем PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "📂 Добавляем $INSTALL_DIR в PATH..."
    echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> "$HOME/.bashrc"
    source "$HOME/.bashrc"
fi

echo
echo "✅ Установка завершена!"
echo "Теперь можно использовать CrypTar так:"
echo "👉 crypTar /путь/к/папке_или_файлу"
echo
