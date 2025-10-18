#!/bin/bash
set -e

echo "🚀 Установка CrypTar..."

# === Проверка наличия необходимых утилит ===
for pkg in tar gpg; do
    if ! command -v $pkg &>/dev/null; then
        echo "⚙️ Устанавливаем $pkg..."
        sudo apt-get install -y $pkg
    else
        echo "✅ $pkg уже установлен."
    fi
done

# === Определяем пользователя и путь установки ===
if [ "$EUID" -eq 0 ]; then
    INSTALL_DIR="/usr/local/bin"
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

# === Копируем основной скрипт ===
SCRIPT_SOURCE="$(dirname "$0")/crypTar.sh"
SCRIPT_TARGET="$INSTALL_DIR/crypTar"

echo "📦 Копируем $SCRIPT_SOURCE → $SCRIPT_TARGET"
cp "$SCRIPT_SOURCE" "$SCRIPT_TARGET"
chmod +x "$SCRIPT_TARGET"

# === Добавляем путь в PATH при необходимости ===
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    echo "📂 Добавляем $INSTALL_DIR в PATH..."
    echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> "$HOME/.bashrc"
    export PATH="$PATH:$INSTALL_DIR"
fi

# === Специальный случай для root ===
if [ "$EUID" -eq 0 ]; then
    if [ -d "/root/.local/bin" ] && [[ ":$PATH:" != *":/root/.local/bin:"* ]]; then
        echo "📂 Добавляем /root/.local/bin в PATH..."
        echo 'export PATH=$PATH:/root/.local/bin' >> /root/.bashrc
        export PATH=$PATH:/root/.local/bin
    fi
fi

# === Проверка наличия GPG-ключей ===
KEYS=$(gpg --list-keys --with-colons | grep '^pub' | awk -F: '{print $5 " <" $10 ">"}')

if [ -z "$KEYS" ]; then
    echo
    echo "🔐 GPG-ключи не найдены!"
    echo "Хотите создать новый ключ для шифрования архивов? (y/n)"
    read -r CREATE_KEY
    if [[ "$CREATE_KEY" =~ ^[Yy]$ ]]; then
        gpg --full-generate-key
        echo "✅ Ключ создан! Вы можете использовать его в crypTar."
    else
        echo "⚠️ Без ключей CrypTar работать не сможет."
    fi
else
    echo
    echo "🔑 Найдены следующие GPG-ключи:"
    echo "$KEYS"
fi

echo
echo "✅ Установка завершена!"
echo "Теперь можно использовать CrypTar так:"
echo "👉 crypTar /путь/к/папке_или_файлу"
